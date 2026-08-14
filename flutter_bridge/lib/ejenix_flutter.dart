// Copyright (c) Ejenix authors. MIT license.

/// The Flutter framework bridge for Ejenix.
///
/// An interpreted patch cannot touch the host except through the
/// [HostRegistry] allow-list (`spec/host-api.md`). This library registers the
/// Flutter widgets, constants, and helpers an ordinary screen needs as host
/// capabilities, so an interpreted `build()` can construct a **real** widget
/// tree, and provides [InterpretedView] to render it.
///
/// Widget constructors receive their arguments as a `{parameterName: value}`
/// map (the host-call convention the compiler emits), so each binding reads
/// `args['child']`, `args['style']`, etc. Interpreted closures passed as
/// callbacks are re-entered on the same interpreter — including callbacks that
/// take arguments (`onChanged: (v) => …`) and builders that must return a
/// widget (`itemBuilder: (context, i) => …`).
///
/// Host objects the bridge hands back to guest code — a [TextEditingController]
/// or an [AsyncSnapshot] — get their own kind via
/// [HostRegistry.addKindResolver], so the patch can read `controller.text` or
/// `snapshot.hasData` through the same allow-list.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';

export 'package:ejenix_bytecode/bytecode.dart' show Module;
// An app handling a patch failure needs the type it is classifying.
export 'package:ejenix_interpreter/interpreter.dart'
    show
        InterpreterException,
        MissingHostCapabilityException,
        StepLimitExceededException;
export 'ejenix_patch_view.dart';
export 'patchable.dart';

/// Default instruction budget for one interpreted call.
///
/// Chosen to be unreachable by real UI code and still bound a runaway loop.
/// A complex interpreted `build()` costs on the order of 10^4–10^5
/// instructions, so this leaves roughly two orders of magnitude of headroom;
/// an `itemBuilder` is charged per row, and each row is a separate call with
/// its own budget.
///
/// The trade-off is deliberate. Too low silently breaks legitimate heavy
/// patches across a whole fleet — the worse outage. Too high lengthens the
/// stall before a hanging patch is caught. This errs high: the goal is to turn
/// "frozen forever, unrecoverable" into "one slow frame, then rolled back",
/// not to police patch performance.
const int kDefaultPatchStepLimit = 5000000;

/// Wires host bindings back to the live view: the interpreter to re-enter for
/// callbacks, and the rebuild trigger for `setState`.
///
/// Both fields are populated *after* the interpreter is constructed — the
/// bindings capture this object and read it lazily, which breaks the cycle
/// (the registry is needed to build the interpreter, and the bindings need the
/// interpreter to call back into it). A host app that wants to add its own
/// capabilities can build a registry with [flutterHostRegistry] and extend it.
class BridgeContext {
  /// The interpreter to re-enter when guest code is called back.
  Interpreter? interp;

  /// Asks the hosting element to rebuild, after a `setState` mutation.
  VoidCallback? requestRebuild;

  // The marshalling an app needs to register its *own* capabilities. Without
  // these, a `HostExtension` could not accept a callback or a builder from a
  // patch — which is most of the point. See `example/patchable_app/`.

  /// The `{parameterName: value}` map a host constructor call carries:
  /// `final m = ctx.args(a);` then read `m['label']`.
  Map<Object?, Object?> args(List<Object?> a) => _m(a);

  /// Marshals guest code into a zero-argument callback (`onPressed: () => …`).
  VoidCallback? callback(Object? v) => _voidCallback(v, this);

  /// Marshals guest code into a one-argument callback (`onChanged: (v) => …`).
  ValueChanged<T>? callbackWith<T>(Object? v) => _onChanged<T>(v, this);

  /// Marshals guest code into a [WidgetBuilder] (`builder: (context) => …`).
  WidgetBuilder widgetBuilder(Object? v, {String what = 'builder'}) =>
      _widgetBuilder(v, this, what);

  /// Marshals guest code into an [IndexedWidgetBuilder]
  /// (`itemBuilder: (context, i) => …`).
  IndexedWidgetBuilder indexedBuilder(
    Object? v, {
    String what = 'itemBuilder',
  }) => _indexedBuilder(v, this, what);

  /// Validates a widget a patch produced, surfacing a wrong type as a visible
  /// error rather than a crash.
  Widget asWidget(Object? v, {String what = 'value'}) => _asWidget(v, what);
}

/// Builds a [HostRegistry] with the standard `dart:core` allow-list plus the
/// Flutter widget/constant/helper/`setState` bindings. [ctx] supplies the
/// interpreter used for callbacks and the rebuild trigger.
HostRegistry flutterHostRegistry(BridgeContext ctx) {
  final r = HostRegistry.standard();
  _registerLayout(r);
  _registerEffects(r);
  _registerScrolling(r, ctx);
  _registerStructure2(r, ctx);
  _registerDisplay(r);
  _registerInput(r, ctx);
  _registerStructure(r, ctx);
  _registerNavigation(r, ctx);
  _registerAnimation(r);
  _registerAsync(r, ctx);
  _registerHostObjects(r);
  _registerHelpers(r);
  _registerConstants(r);
  // `setState(() { …mutations… })`: run the mutation closure, then ask the
  // hosting element to rebuild — the interpreted state object is unchanged
  // across rebuilds, so the next `build(state)` observes the mutation.
  r.registerGlobal('setState', (_, a) {
    final fn = a.isEmpty ? null : a[0];
    if (fn is InterpClosure) ctx.interp!.invokeClosure(fn, const []);
    ctx.requestRebuild?.call();
    return null;
  });
  return r;
}

// --- Argument marshalling ----------------------------------------------------

/// The `{parameterName: value}` map a host constructor call carries.
Map<Object?, Object?> _m(List<Object?> a) =>
    a.isEmpty ? const {} : a[0] as Map<Object?, Object?>;

double? _d(Object? v) => (v as num?)?.toDouble();

List<Widget> _children(Object? v) =>
    v == null ? const <Widget>[] : (v as List).cast<Widget>();

/// Validates a builder's result. A patch is untrusted input: a builder that
/// returns the wrong type must surface as a visible error, never a crash.
Widget _asWidget(Object? v, String what) => v is Widget
    ? v
    : ErrorWidget(
        'interpreted $what returned ${v.runtimeType}, expected a Widget',
      );

/// Marshals an interpreted closure into a zero-argument callback (`onPressed`,
/// `onTap`).
VoidCallback? _voidCallback(Object? v, BridgeContext ctx) {
  if (v == null) return null;
  if (v is InterpClosure) return () => ctx.interp!.invokeClosure(v, const []);
  if (v is Function) return () => v();
  return null;
}

/// Marshals an interpreted closure into a one-argument callback (`onChanged`),
/// re-entering the VM with the new value.
ValueChanged<T>? _onChanged<T>(Object? v, BridgeContext ctx) {
  if (v == null) return null;
  if (v is InterpClosure) return (T x) => ctx.interp!.invokeClosure(v, [x]);
  if (v is Function) return (T x) => v(x);
  return null;
}

/// A zero-argument call into guest code that **keeps its result** — unlike
/// [_voidCallback], which discards it. `RefreshIndicator.onRefresh` must await
/// the Future a patch's `async` function returns, or the spinner never stops.
Object? Function()? _call0(Object? v, BridgeContext ctx) {
  if (v is InterpClosure) return () => ctx.interp!.invokeClosure(v, const []);
  if (v is Function) return () => v() as Object?;
  return null;
}

/// A one-argument call into guest code. See [_call2] for why both shapes are
/// accepted.
Object? Function(Object?)? _call1(Object? v, BridgeContext ctx) {
  if (v is InterpClosure) return (a) => ctx.interp!.invokeClosure(v, [a]);
  if (v is Function) return (a) => v(a) as Object?;
  return null;
}

/// Marshals guest code into a [WidgetBuilder] (`builder: (context) => …`), as
/// `showDialog` takes.
WidgetBuilder _widgetBuilder(Object? v, BridgeContext ctx, String what) {
  final call = _call1(v, ctx);
  if (call == null) return (_) => _missing(v, what);
  return (context) => _asWidget(call(context), what);
}

/// A two-argument call into guest code, whichever way the callable reached us.
///
/// The interpreter adapts an interpreted closure into a plain Dart function when
/// it is passed to a host call, so that is the usual arrival shape; a closure
/// reaching the bridge by another route is still an [InterpClosure]. Accept both
/// rather than depending on which marshalling path ran.
Object? Function(Object?, Object?)? _call2(Object? v, BridgeContext ctx) {
  if (v is InterpClosure) {
    return (a, b) => ctx.interp!.invokeClosure(v, [a, b]);
  }
  if (v is Function) return (a, b) => v(a, b) as Object?;
  return null;
}

/// Marshals guest code into an [IndexedWidgetBuilder]
/// (`itemBuilder: (context, i) => …`). A missing or non-callable builder renders
/// as a visible error rather than an empty box, so a mistake is never silent.
IndexedWidgetBuilder _indexedBuilder(
  Object? v,
  BridgeContext ctx,
  String what,
) {
  final call = _call2(v, ctx);
  if (call == null) return (_, _) => _missing(v, what);
  return (context, index) => _asWidget(call(context, index), what);
}

/// Marshals guest code into an [AsyncWidgetBuilder]
/// (`builder: (context, snapshot) => …`).
AsyncWidgetBuilder<Object?> _snapshotBuilder(
  Object? v,
  BridgeContext ctx,
  String what,
) {
  final call = _call2(v, ctx);
  if (call == null) return (_, _) => _missing(v, what);
  return (context, snapshot) => _asWidget(call(context, snapshot), what);
}

Widget _missing(Object? v, String what) =>
    ErrorWidget('$what expected a function, got ${v.runtimeType}');

// --- Layout ------------------------------------------------------------------

void _registerLayout(HostRegistry r) {
  r
    ..registerGlobal('SizedBox', (_, a) {
      final m = _m(a);
      return SizedBox(
        width: _d(m['width']),
        height: _d(m['height']),
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('Container', (_, a) {
      final m = _m(a);
      return Container(
        width: _d(m['width']),
        height: _d(m['height']),
        color: m['color'] as Color?,
        alignment: m['alignment'] as AlignmentGeometry?,
        padding: m['padding'] as EdgeInsetsGeometry?,
        margin: m['margin'] as EdgeInsetsGeometry?,
        decoration: m['decoration'] as Decoration?,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal(
      'Center',
      (_, a) => Center(child: _m(a)['child'] as Widget?),
    )
    ..registerGlobal('Padding', (_, a) {
      final m = _m(a);
      return Padding(
        padding: m['padding'] as EdgeInsetsGeometry? ?? EdgeInsets.zero,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('Column', (_, a) {
      final m = _m(a);
      return Column(
        mainAxisAlignment:
            m['mainAxisAlignment'] as MainAxisAlignment? ??
            MainAxisAlignment.start,
        crossAxisAlignment:
            m['crossAxisAlignment'] as CrossAxisAlignment? ??
            CrossAxisAlignment.center,
        mainAxisSize: m['mainAxisSize'] as MainAxisSize? ?? MainAxisSize.max,
        children: _children(m['children']),
      );
    })
    ..registerGlobal('Row', (_, a) {
      final m = _m(a);
      return Row(
        mainAxisAlignment:
            m['mainAxisAlignment'] as MainAxisAlignment? ??
            MainAxisAlignment.start,
        crossAxisAlignment:
            m['crossAxisAlignment'] as CrossAxisAlignment? ??
            CrossAxisAlignment.center,
        mainAxisSize: m['mainAxisSize'] as MainAxisSize? ?? MainAxisSize.max,
        children: _children(m['children']),
      );
    })
    ..registerGlobal('Expanded', (_, a) {
      final m = _m(a);
      return Expanded(
        flex: m['flex'] as int? ?? 1,
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    })
    ..registerGlobal('Flexible', (_, a) {
      final m = _m(a);
      return Flexible(
        flex: m['flex'] as int? ?? 1,
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    })
    ..registerGlobal('Stack', (_, a) {
      final m = _m(a);
      return Stack(
        alignment:
            m['alignment'] as AlignmentGeometry? ??
            AlignmentDirectional.topStart,
        fit: m['fit'] as StackFit? ?? StackFit.loose,
        children: _children(m['children']),
      );
    })
    ..registerGlobal('Positioned', (_, a) {
      final m = _m(a);
      return Positioned(
        left: _d(m['left']),
        top: _d(m['top']),
        right: _d(m['right']),
        bottom: _d(m['bottom']),
        width: _d(m['width']),
        height: _d(m['height']),
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    })
    ..registerGlobal('Wrap', (_, a) {
      final m = _m(a);
      return Wrap(
        spacing: _d(m['spacing']) ?? 0,
        runSpacing: _d(m['runSpacing']) ?? 0,
        alignment: m['alignment'] as WrapAlignment? ?? WrapAlignment.start,
        children: _children(m['children']),
      );
    })
    ..registerGlobal('Align', (_, a) {
      final m = _m(a);
      return Align(
        alignment: m['alignment'] as AlignmentGeometry? ?? Alignment.center,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('AspectRatio', (_, a) {
      final m = _m(a);
      return AspectRatio(
        aspectRatio: _d(m['aspectRatio']) ?? 1.0,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('SafeArea', (_, a) {
      final m = _m(a);
      return SafeArea(
        top: m['top'] as bool? ?? true,
        bottom: m['bottom'] as bool? ?? true,
        left: m['left'] as bool? ?? true,
        right: m['right'] as bool? ?? true,
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    })
    ..registerGlobal('SingleChildScrollView', (_, a) {
      final m = _m(a);
      return SingleChildScrollView(
        padding: m['padding'] as EdgeInsetsGeometry?,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal(
      'ListView',
      (_, a) => ListView(
        padding: _m(a)['padding'] as EdgeInsetsGeometry?,
        children: _children(_m(a)['children']),
      ),
    )
    ..registerGlobal('Spacer', (_, _) => const Spacer());
}

// --- Display -----------------------------------------------------------------

void _registerDisplay(HostRegistry r) {
  r
    ..registerGlobal('Text', (_, a) {
      final m = _m(a);
      return Text(
        m['data'] as String? ?? '',
        style: m['style'] as TextStyle?,
        textAlign: m['textAlign'] as TextAlign?,
        overflow: m['overflow'] as TextOverflow?,
        maxLines: m['maxLines'] as int?,
      );
    })
    ..registerGlobal('Icon', (_, a) {
      final m = _m(a);
      return Icon(
        m['icon'] as IconData?,
        size: _d(m['size']),
        color: m['color'] as Color?,
      );
    })
    ..registerGlobal('Image.network', (_, a) {
      final m = _m(a);
      return Image.network(
        m['src'] as String? ?? '',
        width: _d(m['width']),
        height: _d(m['height']),
        fit: m['fit'] as BoxFit?,
      );
    })
    ..registerGlobal('Image.asset', (_, a) {
      final m = _m(a);
      return Image.asset(
        m['name'] as String? ?? '',
        width: _d(m['width']),
        height: _d(m['height']),
        fit: m['fit'] as BoxFit?,
      );
    })
    ..registerGlobal('CircleAvatar', (_, a) {
      final m = _m(a);
      return CircleAvatar(
        radius: _d(m['radius']),
        backgroundColor: m['backgroundColor'] as Color?,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('Chip', (_, a) {
      final m = _m(a);
      return Chip(
        label: m['label'] as Widget? ?? const SizedBox.shrink(),
        avatar: m['avatar'] as Widget?,
        backgroundColor: m['backgroundColor'] as Color?,
      );
    })
    ..registerGlobal('Card', (_, a) {
      final m = _m(a);
      return Card(
        color: m['color'] as Color?,
        elevation: _d(m['elevation']),
        margin: m['margin'] as EdgeInsetsGeometry?,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('Divider', (_, a) {
      final m = _m(a);
      return Divider(
        height: _d(m['height']),
        thickness: _d(m['thickness']),
        color: m['color'] as Color?,
      );
    })
    ..registerGlobal('Opacity', (_, a) {
      final m = _m(a);
      return Opacity(
        opacity: _d(m['opacity']) ?? 1.0,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal(
      'CircularProgressIndicator',
      (_, a) => CircularProgressIndicator(
        value: _d(_m(a)['value']),
        color: _m(a)['color'] as Color?,
      ),
    )
    ..registerGlobal(
      'LinearProgressIndicator',
      (_, a) => LinearProgressIndicator(
        value: _d(_m(a)['value']),
        color: _m(a)['color'] as Color?,
      ),
    )
    ..registerGlobal('Tooltip', (_, a) {
      final m = _m(a);
      return Tooltip(
        message: m['message'] as String? ?? '',
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('Placeholder', (_, _) => const Placeholder());
}

// --- Input and buttons -------------------------------------------------------

void _registerInput(HostRegistry r, BridgeContext ctx) {
  r
    ..registerGlobal('ElevatedButton', (_, a) {
      final m = _m(a);
      return ElevatedButton(
        onPressed: _voidCallback(m['onPressed'], ctx),
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    })
    ..registerGlobal('TextButton', (_, a) {
      final m = _m(a);
      return TextButton(
        onPressed: _voidCallback(m['onPressed'], ctx),
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    })
    ..registerGlobal('OutlinedButton', (_, a) {
      final m = _m(a);
      return OutlinedButton(
        onPressed: _voidCallback(m['onPressed'], ctx),
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    })
    ..registerGlobal('IconButton', (_, a) {
      final m = _m(a);
      return IconButton(
        onPressed: _voidCallback(m['onPressed'], ctx),
        icon: m['icon'] as Widget? ?? const SizedBox.shrink(),
        tooltip: m['tooltip'] as String?,
        color: m['color'] as Color?,
      );
    })
    ..registerGlobal('FloatingActionButton', (_, a) {
      final m = _m(a);
      return FloatingActionButton(
        onPressed: _voidCallback(m['onPressed'], ctx),
        tooltip: m['tooltip'] as String?,
        backgroundColor: m['backgroundColor'] as Color?,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('GestureDetector', (_, a) {
      final m = _m(a);
      return GestureDetector(
        onTap: _voidCallback(m['onTap'], ctx),
        onLongPress: _voidCallback(m['onLongPress'], ctx),
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('InkWell', (_, a) {
      final m = _m(a);
      return InkWell(
        onTap: _voidCallback(m['onTap'], ctx),
        onLongPress: _voidCallback(m['onLongPress'], ctx),
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('TextField', (_, a) {
      final m = _m(a);
      return TextField(
        controller: m['controller'] as TextEditingController?,
        onChanged: _onChanged<String>(m['onChanged'], ctx),
        onSubmitted: _onChanged<String>(m['onSubmitted'], ctx),
        obscureText: m['obscureText'] as bool? ?? false,
        decoration:
            m['decoration'] as InputDecoration? ?? const InputDecoration(),
      );
    })
    ..registerGlobal('Checkbox', (_, a) {
      final m = _m(a);
      return Checkbox(
        value: m['value'] as bool? ?? false,
        onChanged: _onChanged<bool?>(m['onChanged'], ctx),
      );
    })
    ..registerGlobal('Switch', (_, a) {
      final m = _m(a);
      return Switch(
        value: m['value'] as bool? ?? false,
        onChanged: _onChanged<bool>(m['onChanged'], ctx),
      );
    })
    ..registerGlobal('Slider', (_, a) {
      final m = _m(a);
      return Slider(
        value: _d(m['value']) ?? 0,
        min: _d(m['min']) ?? 0,
        max: _d(m['max']) ?? 1,
        divisions: m['divisions'] as int?,
        label: m['label'] as String?,
        onChanged: _onChanged<double>(m['onChanged'], ctx),
      );
    });
}

// --- Structure (app shell, lists, dialogs) -----------------------------------

void _registerStructure(HostRegistry r, BridgeContext ctx) {
  r
    ..registerGlobal('Scaffold', (_, a) {
      final m = _m(a);
      return Scaffold(
        appBar: m['appBar'] as PreferredSizeWidget?,
        body: m['body'] as Widget?,
        floatingActionButton: m['floatingActionButton'] as Widget?,
        drawer: m['drawer'] as Widget?,
        bottomNavigationBar: m['bottomNavigationBar'] as Widget?,
        backgroundColor: m['backgroundColor'] as Color?,
      );
    })
    ..registerGlobal('AppBar', (_, a) {
      final m = _m(a);
      return AppBar(
        title: m['title'] as Widget?,
        centerTitle: m['centerTitle'] as bool?,
        backgroundColor: m['backgroundColor'] as Color?,
        leading: m['leading'] as Widget?,
        elevation: _d(m['elevation']),
        actions: m['actions'] == null ? null : _children(m['actions']),
        // A TabBar lives here. It is a PreferredSizeWidget, so anything else a
        // patch passes is simply ignored rather than crashing the app bar.
        bottom: m['bottom'] as PreferredSizeWidget?,
      );
    })
    ..registerGlobal(
      'Drawer',
      (_, a) => Drawer(child: _m(a)['child'] as Widget?),
    )
    ..registerGlobal('Material', (_, a) {
      final m = _m(a);
      return Material(
        color: m['color'] as Color?,
        elevation: _d(m['elevation']) ?? 0,
        child: m['child'] as Widget?,
      );
    })
    // `ListView.builder(itemCount:, itemBuilder: (context, i) => …)` — the
    // builder re-enters the VM per visible row, so a long list stays lazy.
    ..registerGlobal('ListView.builder', (_, a) {
      final m = _m(a);
      return ListView.builder(
        itemCount: m['itemCount'] as int?,
        padding: m['padding'] as EdgeInsetsGeometry?,
        itemBuilder: _indexedBuilder(m['itemBuilder'], ctx, 'itemBuilder'),
      );
    })
    ..registerGlobal('ListTile', (_, a) {
      final m = _m(a);
      return ListTile(
        leading: m['leading'] as Widget?,
        title: m['title'] as Widget?,
        subtitle: m['subtitle'] as Widget?,
        trailing: m['trailing'] as Widget?,
        onTap: _voidCallback(m['onTap'], ctx),
      );
    })
    ..registerGlobal('BottomNavigationBar', (_, a) {
      final m = _m(a);
      return BottomNavigationBar(
        currentIndex: m['currentIndex'] as int? ?? 0,
        onTap: _onChanged<int>(m['onTap'], ctx),
        items: (m['items'] as List? ?? const [])
            .cast<BottomNavigationBarItem>(),
      );
    })
    ..registerGlobal('BottomNavigationBarItem', (_, a) {
      final m = _m(a);
      return BottomNavigationBarItem(
        icon: m['icon'] as Widget? ?? const SizedBox.shrink(),
        label: m['label'] as String?,
      );
    })
    ..registerGlobal('AlertDialog', (_, a) {
      final m = _m(a);
      return AlertDialog(
        title: m['title'] as Widget?,
        content: m['content'] as Widget?,
        actions: m['actions'] == null ? null : _children(m['actions']),
      );
    });
}

// --- Clipping and transforms -------------------------------------------------

/// Only the two transforms a patch can express safely. A general `Matrix4` is
/// not exposed: nobody hand-writes one, and it is a footgun across the boundary.
void _registerEffects(HostRegistry r) {
  r
    ..registerGlobal('ClipRRect', (_, a) {
      final m = _m(a);
      return ClipRRect(
        borderRadius:
            m['borderRadius'] as BorderRadiusGeometry? ?? BorderRadius.zero,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('Transform.rotate', (_, a) {
      final m = _m(a);
      return Transform.rotate(
        angle: _d(m['angle']) ?? 0.0,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('Transform.scale', (_, a) {
      final m = _m(a);
      return Transform.scale(
        scale: _d(m['scale']) ?? 1.0,
        child: m['child'] as Widget?,
      );
    });
}

// --- Scrolling and paging ----------------------------------------------------

void _registerScrolling(HostRegistry r, BridgeContext ctx) {
  r
    ..registerGlobal('GridView.builder', (_, a) {
      final m = _m(a);
      return GridView.builder(
        itemCount: m['itemCount'] as int?,
        padding: m['padding'] as EdgeInsetsGeometry?,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: m['crossAxisCount'] as int? ?? 2,
          mainAxisSpacing: _d(m['mainAxisSpacing']) ?? 0.0,
          crossAxisSpacing: _d(m['crossAxisSpacing']) ?? 0.0,
          childAspectRatio: _d(m['childAspectRatio']) ?? 1.0,
        ),
        itemBuilder: _indexedBuilder(
          m['itemBuilder'],
          ctx,
          'GridView.builder.itemBuilder',
        ),
      );
    })
    ..registerGlobal('PageView', (_, a) {
      final m = _m(a);
      return PageView(
        onPageChanged: _onChanged<int>(m['onPageChanged'], ctx),
        children: _children(m['children']),
      );
    })
    // `onRefresh` must return a Future the indicator can await — a patch's async
    // function does exactly that.
    ..registerGlobal('RefreshIndicator', (_, a) {
      final m = _m(a);
      final onRefresh = m['onRefresh'];
      return RefreshIndicator(
        onRefresh: () async {
          final call = _call0(onRefresh, ctx);
          final result = call?.call();
          if (result is Future) await result;
        },
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    });
}

// --- Structure: drawers, tabs, forms, and inputs ------------------------------

void _registerStructure2(HostRegistry r, BridgeContext ctx) {
  r
    ..registerGlobal('TabBar', (_, a) {
      final m = _m(a);
      return TabBar(tabs: _children(m['tabs']));
    })
    ..registerGlobal('Tab', (_, a) {
      final m = _m(a);
      return Tab(text: m['text'] as String?, icon: m['icon'] as Widget?);
    })
    ..registerGlobal('TabBarView', (_, a) {
      final m = _m(a);
      return TabBarView(children: _children(m['children']));
    })
    // `DefaultTabController` is what makes TabBar usable without a patch owning
    // a TickerProvider — the same reason only implicit animations are bridged.
    ..registerGlobal('DefaultTabController', (_, a) {
      final m = _m(a);
      return DefaultTabController(
        length: m['length'] as int? ?? 0,
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    })
    ..registerGlobal('Form', (_, a) {
      final m = _m(a);
      return Form(child: m['child'] as Widget? ?? const SizedBox.shrink());
    })
    // Flutter 3.32 deprecated `Radio.groupValue`/`onChanged` in favour of a
    // `RadioGroup` ancestor holding the selection. Bridge the *current* API, not
    // the deprecated one — a patch SDK that teaches people a dead pattern ages
    // badly, and this surface is meant to outlive a few Flutter releases.
    ..registerGlobal('RadioGroup', (_, a) {
      final m = _m(a);
      return RadioGroup<Object?>(
        groupValue: m['groupValue'],
        onChanged: _onChanged<Object?>(m['onChanged'], ctx) ?? (_) {},
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    })
    ..registerGlobal('Radio', (_, a) {
      final m = _m(a);
      return Radio<Object?>(value: m['value']);
    })
    ..registerGlobal('DropdownButton', (_, a) {
      final m = _m(a);
      return DropdownButton<Object?>(
        value: m['value'],
        hint: m['hint'] as Widget?,
        isExpanded: m['isExpanded'] as bool? ?? false,
        items: [
          for (final item in (m['items'] as List? ?? const []))
            item as DropdownMenuItem<Object?>,
        ],
        onChanged: _onChanged<Object?>(m['onChanged'], ctx),
      );
    })
    ..registerGlobal('DropdownMenuItem', (_, a) {
      final m = _m(a);
      return DropdownMenuItem<Object?>(
        value: m['value'],
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    });
}

// --- Navigation and feedback -------------------------------------------------

/// Navigation is deliberately **route-name only**: a patch may travel to routes
/// the app already declared, never construct an arbitrary destination. The app
/// keeps ownership of its route table, so a patch cannot navigate somewhere the
/// shipped binary never intended to go.
void _registerNavigation(HostRegistry r, BridgeContext ctx) {
  BuildContext ctxOf(Map<Object?, Object?> m) => m['context'] as BuildContext;

  r
    ..registerGlobal('Navigator.pop', (_, a) {
      final m = _m(a);
      Navigator.of(ctxOf(m)).pop(m['result']);
      return null;
    })
    ..registerGlobal('Navigator.pushNamed', (_, a) {
      final m = _m(a);
      return Navigator.of(
        ctxOf(m),
      ).pushNamed(m['routeName'] as String, arguments: m['arguments']);
    })
    ..registerGlobal(
      'Navigator.canPop',
      (_, a) => Navigator.of(ctxOf(_m(a))).canPop(),
    )
    ..registerGlobal('showDialog', (_, a) {
      final m = _m(a);
      return showDialog<Object?>(
        context: ctxOf(m),
        barrierDismissible: m['barrierDismissible'] as bool? ?? true,
        builder: _widgetBuilder(m['builder'], ctx, 'showDialog.builder'),
      );
    })
    ..registerGlobal('ScaffoldMessenger.showSnackBar', (_, a) {
      final m = _m(a);
      ScaffoldMessenger.of(ctxOf(m)).showSnackBar(m['snackBar'] as SnackBar);
      return null;
    })
    ..registerGlobal('SnackBar', (_, a) {
      final m = _m(a);
      return SnackBar(
        content: m['content'] as Widget? ?? const SizedBox.shrink(),
        duration: m['duration'] as Duration? ?? const Duration(seconds: 4),
        backgroundColor: m['backgroundColor'] as Color?,
      );
    });
}

// --- Implicit animations -----------------------------------------------------

/// Only *implicit* animations are bridged. Explicit ones (`AnimationController`)
/// need a `TickerProvider` bound to the host element's lifecycle, which a patch
/// cannot own; implicit animations need nothing but a duration, so they cross
/// the boundary cleanly.
void _registerAnimation(HostRegistry r) {
  r
    ..registerGlobal('AnimatedContainer', (_, a) {
      final m = _m(a);
      return AnimatedContainer(
        duration: m['duration'] as Duration? ?? Duration.zero,
        curve: m['curve'] as Curve? ?? Curves.linear,
        width: _d(m['width']),
        height: _d(m['height']),
        color: m['color'] as Color?,
        alignment: m['alignment'] as AlignmentGeometry?,
        padding: m['padding'] as EdgeInsetsGeometry?,
        margin: m['margin'] as EdgeInsetsGeometry?,
        decoration: m['decoration'] as Decoration?,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('AnimatedOpacity', (_, a) {
      final m = _m(a);
      return AnimatedOpacity(
        duration: m['duration'] as Duration? ?? Duration.zero,
        curve: m['curve'] as Curve? ?? Curves.linear,
        opacity: _d(m['opacity']) ?? 1.0,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('AnimatedSwitcher', (_, a) {
      final m = _m(a);
      return AnimatedSwitcher(
        duration: m['duration'] as Duration? ?? Duration.zero,
        child: m['child'] as Widget?,
      );
    })
    ..registerGlobal('Hero', (_, a) {
      final m = _m(a);
      return Hero(
        tag: m['tag'] ?? '',
        child: m['child'] as Widget? ?? const SizedBox.shrink(),
      );
    });
}

// --- Async builders ----------------------------------------------------------

void _registerAsync(HostRegistry r, BridgeContext ctx) {
  r
    ..registerGlobal('FutureBuilder', (_, a) {
      final m = _m(a);
      return FutureBuilder<Object?>(
        future: m['future'] as Future<Object?>?,
        initialData: m['initialData'],
        builder: _snapshotBuilder(m['builder'], ctx, 'FutureBuilder.builder'),
      );
    })
    ..registerGlobal('StreamBuilder', (_, a) {
      final m = _m(a);
      return StreamBuilder<Object?>(
        stream: m['stream'] as Stream<Object?>?,
        initialData: m['initialData'],
        builder: _snapshotBuilder(m['builder'], ctx, 'StreamBuilder.builder'),
      );
    });
}

// --- Host objects the patch holds and reads ----------------------------------

/// Gives the mutable/queryable objects the bridge hands to guest code a kind of
/// their own, so `controller.text` and `snapshot.hasData` resolve through the
/// allow-list. Matching is by runtime type (`is`), which survives `--obfuscate`.
void _registerHostObjects(HostRegistry r) {
  r
    ..addKindResolver(
      (o) => switch (o) {
        TextEditingController() => 'TextEditingController',
        AsyncSnapshot() => 'AsyncSnapshot',
        MaterialColor() => 'MaterialColor',
        _ => null,
      },
    )
    // A patch creates the controller once in `createState()` and holds it, so
    // the field survives rebuilds.
    ..registerGlobal(
      'TextEditingController',
      (_, a) => TextEditingController(text: _m(a)['text'] as String? ?? ''),
    )
    ..register(
      'TextEditingController',
      'text',
      (recv, _) => (recv as TextEditingController).text,
    )
    ..register('TextEditingController', 'clear', (recv, _) {
      (recv as TextEditingController).clear();
      return null;
    });

  final snapshot = <String, Object? Function(AsyncSnapshot<Object?>)>{
    'hasData': (s) => s.hasData,
    'data': (s) => s.data,
    'hasError': (s) => s.hasError,
    'error': (s) => s.error,
    'connectionState': (s) => s.connectionState,
  };
  snapshot.forEach((selector, get) {
    r.register(
      'AsyncSnapshot',
      selector,
      (recv, _) => get(recv as AsyncSnapshot<Object?>),
    );
  });

  // `Colors.blue.shade700` — a MaterialColor is a swatch, not a plain Color.
  for (final shade in [50, 100, 200, 300, 400, 500, 600, 700, 800, 900]) {
    r.register(
      'MaterialColor',
      'shade$shade',
      (recv, _) => (recv as MaterialColor)[shade],
    );
  }
}

// --- Helpers (value types the widgets take) ----------------------------------

void _registerHelpers(HostRegistry r) {
  r
    ..registerGlobal(
      'EdgeInsets.all',
      (_, a) => EdgeInsets.all(_d(_m(a)['value']) ?? 0),
    )
    ..registerGlobal('EdgeInsets.symmetric', (_, a) {
      final m = _m(a);
      return EdgeInsets.symmetric(
        horizontal: _d(m['horizontal']) ?? 0,
        vertical: _d(m['vertical']) ?? 0,
      );
    })
    ..registerGlobal('EdgeInsets.only', (_, a) {
      final m = _m(a);
      return EdgeInsets.only(
        left: _d(m['left']) ?? 0,
        top: _d(m['top']) ?? 0,
        right: _d(m['right']) ?? 0,
        bottom: _d(m['bottom']) ?? 0,
      );
    })
    ..registerGlobal('EdgeInsets.fromLTRB', (_, a) {
      final m = _m(a);
      return EdgeInsets.fromLTRB(
        _d(m['left']) ?? 0,
        _d(m['top']) ?? 0,
        _d(m['right']) ?? 0,
        _d(m['bottom']) ?? 0,
      );
    })
    ..registerGlobal('Color', (_, a) => Color(_m(a)['value'] as int))
    ..registerGlobal('TextStyle', (_, a) {
      final m = _m(a);
      return TextStyle(
        fontSize: _d(m['fontSize']),
        color: m['color'] as Color?,
        fontWeight: m['fontWeight'] as FontWeight?,
        fontStyle: m['fontStyle'] as FontStyle?,
        letterSpacing: _d(m['letterSpacing']),
        height: _d(m['height']),
      );
    })
    ..registerGlobal(
      'BorderRadius.circular',
      (_, a) => BorderRadius.circular(_d(_m(a)['radius']) ?? 0),
    )
    ..registerGlobal('BoxDecoration', (_, a) {
      final m = _m(a);
      return BoxDecoration(
        color: m['color'] as Color?,
        borderRadius: m['borderRadius'] as BorderRadiusGeometry?,
        shape: m['shape'] as BoxShape? ?? BoxShape.rectangle,
      );
    })
    ..registerGlobal('InputDecoration', (_, a) {
      final m = _m(a);
      return InputDecoration(
        labelText: m['labelText'] as String?,
        hintText: m['hintText'] as String?,
        errorText: m['errorText'] as String?,
        border: m['border'] as InputBorder?,
      );
    })
    ..registerGlobal(
      'OutlineInputBorder',
      (_, _) => const OutlineInputBorder(),
    );
}

// --- Constants ---------------------------------------------------------------

void _registerConstants(HostRegistry r) {
  void c(String name, Object? value) => r.registerGlobal(name, (_, _) => value);

  for (final e in <String, Color>{
    'red': Colors.red,
    'green': Colors.green,
    'blue': Colors.blue,
    'black': Colors.black,
    'white': Colors.white,
    'orange': Colors.orange,
    'purple': Colors.purple,
    'yellow': Colors.yellow,
    'teal': Colors.teal,
    'pink': Colors.pink,
    'amber': Colors.amber,
    'indigo': Colors.indigo,
    'cyan': Colors.cyan,
    'brown': Colors.brown,
    'grey': Colors.grey,
    'transparent': Colors.transparent,
  }.entries) {
    c('Colors.${e.key}', e.value);
  }

  c('MainAxisAlignment.start', MainAxisAlignment.start);
  c('MainAxisAlignment.center', MainAxisAlignment.center);
  c('MainAxisAlignment.end', MainAxisAlignment.end);
  c('MainAxisAlignment.spaceBetween', MainAxisAlignment.spaceBetween);
  c('MainAxisAlignment.spaceAround', MainAxisAlignment.spaceAround);
  c('MainAxisAlignment.spaceEvenly', MainAxisAlignment.spaceEvenly);

  c('CrossAxisAlignment.start', CrossAxisAlignment.start);
  c('CrossAxisAlignment.center', CrossAxisAlignment.center);
  c('CrossAxisAlignment.end', CrossAxisAlignment.end);
  c('CrossAxisAlignment.stretch', CrossAxisAlignment.stretch);

  c('MainAxisSize.min', MainAxisSize.min);
  c('MainAxisSize.max', MainAxisSize.max);

  c('FontWeight.normal', FontWeight.normal);
  c('FontWeight.bold', FontWeight.bold);
  c('FontWeight.w300', FontWeight.w300);
  c('FontWeight.w500', FontWeight.w500);
  c('FontWeight.w600', FontWeight.w600);

  c('FontStyle.normal', FontStyle.normal);
  c('FontStyle.italic', FontStyle.italic);

  c('TextAlign.left', TextAlign.left);
  c('TextAlign.center', TextAlign.center);
  c('TextAlign.right', TextAlign.right);

  c('TextOverflow.clip', TextOverflow.clip);
  c('TextOverflow.ellipsis', TextOverflow.ellipsis);
  c('TextOverflow.fade', TextOverflow.fade);

  c('BoxFit.cover', BoxFit.cover);
  c('BoxFit.contain', BoxFit.contain);
  c('BoxFit.fill', BoxFit.fill);
  c('BoxFit.fitWidth', BoxFit.fitWidth);
  c('BoxFit.fitHeight', BoxFit.fitHeight);

  c('BoxShape.rectangle', BoxShape.rectangle);
  c('BoxShape.circle', BoxShape.circle);

  c('StackFit.loose', StackFit.loose);
  c('StackFit.expand', StackFit.expand);
  c('WrapAlignment.start', WrapAlignment.start);
  c('WrapAlignment.center', WrapAlignment.center);
  c('WrapAlignment.spaceBetween', WrapAlignment.spaceBetween);

  c('Curves.linear', Curves.linear);
  c('Curves.easeIn', Curves.easeIn);
  c('Curves.easeOut', Curves.easeOut);
  c('Curves.easeInOut', Curves.easeInOut);
  c('Curves.fastOutSlowIn', Curves.fastOutSlowIn);
  c('Curves.bounceOut', Curves.bounceOut);

  c('ConnectionState.none', ConnectionState.none);
  c('ConnectionState.waiting', ConnectionState.waiting);
  c('ConnectionState.active', ConnectionState.active);
  c('ConnectionState.done', ConnectionState.done);

  c('EdgeInsets.zero', EdgeInsets.zero);

  c('Alignment.center', Alignment.center);
  c('Alignment.topLeft', Alignment.topLeft);
  c('Alignment.topCenter', Alignment.topCenter);
  c('Alignment.topRight', Alignment.topRight);
  c('Alignment.centerLeft', Alignment.centerLeft);
  c('Alignment.centerRight', Alignment.centerRight);
  c('Alignment.bottomLeft', Alignment.bottomLeft);
  c('Alignment.bottomCenter', Alignment.bottomCenter);
  c('Alignment.bottomRight', Alignment.bottomRight);

  for (final e in <String, IconData>{
    'add': Icons.add,
    'remove': Icons.remove,
    'star': Icons.star,
    'home': Icons.home,
    'favorite': Icons.favorite,
    'settings': Icons.settings,
    'search': Icons.search,
    'menu': Icons.menu,
    'close': Icons.close,
    'check': Icons.check,
    'edit': Icons.edit,
    'delete': Icons.delete,
    'person': Icons.person,
    'arrow_back': Icons.arrow_back,
    'arrow_forward': Icons.arrow_forward,
    'refresh': Icons.refresh,
    'share': Icons.share,
    'info': Icons.info,
    'warning': Icons.warning,
    'error': Icons.error,
    'shopping_cart': Icons.shopping_cart,
    'notifications': Icons.notifications,
  }.entries) {
    c('Icons.${e.key}', e.value);
  }
}

/// Grants a patch capabilities the app owns — its design-system widgets, its
/// router, its API client, its state — on top of the built-in Flutter bridge.
///
/// This is the seam that makes the sandbox *usable*. The bridge can never
/// enumerate all of Flutter, let alone your app's own widgets and services, and
/// it must not try: the allow-list is the security boundary. Instead the app
/// decides exactly what a patch may reach:
///
/// ```dart
/// InterpretedView(
///   module: module,
///   extend: (registry, ctx) {
///     registry
///       ..registerGlobal('PrimaryButton', (_, a) => PrimaryButton(...))
///       ..registerGlobal('api.loadTodos', (_, _) => api.loadTodos());
///   },
/// )
/// ```
///
/// Declare the same names in an app-side patch-SDK file so patches type-check
/// against them (see `example/patchable_app/`). [ctx] is supplied so a
/// capability can call back into the VM ([BridgeContext.interp]) or request a
/// rebuild ([BridgeContext.requestRebuild]).
typedef HostExtension = void Function(HostRegistry registry, BridgeContext ctx);

/// Renders an interpreted patch as a real Flutter widget tree. It constructs the
/// interpreter once, then calls the patch's [functionName] (default `build`) on
/// each Flutter build, so the patch can produce different trees over time. The
/// interpreted function must return a [Widget].
class InterpretedView extends StatefulWidget {
  const InterpretedView({
    super.key,
    required this.module,
    this.functionName = 'build',
    this.createStateName = 'createState',
    this.extend,
    this.errorBuilder,
    this.stepLimit = kDefaultPatchStepLimit,
  });

  /// What to show when the patch cannot run.
  ///
  /// A patch is untrusted input that arrived after the binary shipped, so it
  /// must not be able to take the screen down. Two things can go wrong, and
  /// both land here rather than in Flutter's red error screen:
  ///
  /// * the patch needs a capability this build does not register — caught
  ///   before it runs, see [missingHostGlobals];
  /// * the patch throws while building.
  ///
  /// [EjenixPatchView] wires its `fallbackBuilder` in here, so a bad patch
  /// shows the native screen the app shipped with. Left null, the error is
  /// rendered visibly — never swallowed.
  final Widget Function(BuildContext context, Object error)? errorBuilder;

  /// Instruction budget for a single interpreted call, or null for none.
  ///
  /// This is the only guard against a patch that *hangs* rather than throws.
  /// Without it an accidental `while (true)` in a patch spins the UI thread
  /// forever: the app stops responding, nothing crashes, so the crash-loop
  /// rollback never fires and the same patch runs again on the next launch.
  /// The device is stuck until the user deletes the app, and no server-side
  /// rollback can reach it.
  ///
  /// Defaults to [kDefaultPatchStepLimit], far above any real `build()`. Raise
  /// it if a legitimate patch does heavy work in one call; set null only if you
  /// fully control the patches and accept that a loop cannot be recovered from.
  final int? stepLimit;

  /// The compiled patch module (from `ejenix_compiler` or a decoded bundle).
  final Module module;

  /// Registers the app's own capabilities, after the built-in Flutter bridge —
  /// so an app may also override a default binding. See [HostExtension].
  final HostExtension? extend;

  /// The name of the interpreted function that returns the widget tree. It may
  /// take, in order, the [BuildContext] and the state object; the bridge passes
  /// them based on its parameter count:
  ///
  /// * `build()` — stateless.
  /// * `build(state)` — receives the persistent state (see [createStateName]),
  ///   or the [BuildContext] if there is no state function.
  /// * `build(context, state)` — receives both.
  final String functionName;

  /// The name of the interpreted function that creates the persistent state
  /// object once, if present. Its result is passed to every [functionName]
  /// call, so an interpreted `setState` mutation survives across rebuilds.
  final String createStateName;

  @override
  State<InterpretedView> createState() => _InterpretedViewState();
}

class _InterpretedViewState extends State<InterpretedView> {
  late Interpreter _interpreter;
  late FunctionProto _build;
  final BridgeContext _ctx = BridgeContext();
  Object? _state;

  /// Non-null when the patch cannot run; rendered via [InterpretedView.errorBuilder].
  Object? _error;

  @override
  void initState() {
    super.initState();
    _ctx.requestRebuild = () {
      if (mounted) setState(() {});
    };
    _load();
  }

  /// Rebuilds the interpreter when a **new patch** arrives.
  ///
  /// This is what makes an over-the-air update actually arrive: `ejenix watch` (or the loader)
  /// hands down fresh bytecode, and the screen becomes the new patch without the
  /// app restarting. Patch-local state is intentionally *not* carried over — the
  /// new patch may have a different state shape, and silently reusing the old
  /// object would be a type error waiting to happen on a user's device.
  @override
  void didUpdateWidget(InterpretedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.module, oldWidget.module)) _load();
  }

  void _load() {
    _error = null;
    try {
      // The app's capabilities are registered last, so an app can also override
      // a default binding (e.g. swap `ElevatedButton` for its own themed one).
      final registry = flutterHostRegistry(_ctx);
      widget.extend?.call(registry, _ctx);

      // Deliberately NOT pre-scanning the module for unsatisfied capabilities.
      //
      // A static scan sees every function; only `build` and `createState` ever
      // run. A patch whose helper references a capability behind a branch that
      // is never taken renders perfectly today — refusing it here would turn
      // "works" into "rolled back", fleet-wide, which is a far worse failure
      // than the one this containment fixes. The same scan would also throw on
      // a module using an opcode this build predates, in every function
      // including dead ones.
      //
      // So the check is left where it is exact: the interpreter raises
      // MissingHostCapabilityException at the instruction that actually needs
      // the capability, and the catch below turns that into a fallback. Zero
      // false positives by construction. `requiredHostGlobals` remains for
      // tooling, where over-reporting is harmless.
      _interpreter = Interpreter(
        widget.module,
        hostRegistry: registry,
        stepLimit: widget.stepLimit,
      );
      _ctx.interp = _interpreter;
      _build = widget.module.functions.firstWhere(
        (f) => f.name == widget.functionName,
      );
      final createState = widget.module.functions
          .where((f) => f.name == widget.createStateName)
          .firstOrNull;
      _state = createState == null
          ? null
          : _interpreter.callFunction(createState, const []);
    } on Object catch (e) {
      // A patch that throws while initialising must not take the app with it.
      _error = e;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loadError = _error;
    if (loadError != null) return _renderError(context, loadError);

    // Pass, in order, the arguments the interpreted build declares: state
    // (preferred when present) and/or the BuildContext.
    final List<Object?> args = switch (_build.paramCount) {
      0 => const [],
      1 => [_state ?? context],
      _ => [context, _state],
    };
    try {
      final result = _interpreter.callFunction(_build, args);
      if (result is! Widget) {
        // Previously this became an ErrorWidget in place: visible, but invisible
        // to the host. errorBuilder never ran, _patchFailed was never set, and
        // the patch was marked HEALTHY — so the crash-loop counter reset and a
        // patch that renders nothing usable was pinned as good. Route it like
        // any other failure.
        throw PatchOutputException(widget.functionName, result);
      }
      return result;
    } on Object catch (e) {
      // Anything the patch throws mid-render lands here. Without this the
      // exception escapes into Flutter's error path and the user gets a red
      // screen — from a patch the app was supposed to be able to survive.
      return _renderError(context, e);
    }
  }

  Widget _renderError(BuildContext context, Object error) {
    final builder = widget.errorBuilder;
    if (builder != null) return builder(context, error);
    return ErrorWidget('Ejenix patch could not run: $error');
  }
}

/// The patch's entry point returned something that is not a widget.
///
/// Permanent by nature: a `build()` that returns an `int` will return an `int`
/// on every rebuild, so retrying cannot help and the patch should be replaced
/// rather than shown.
class PatchOutputException implements Exception {
  PatchOutputException(this.functionName, this.value);

  /// The interpreted entry point that returned the wrong type.
  final String functionName;

  /// What it returned instead of a widget.
  final Object? value;

  @override
  String toString() =>
      'patch $functionName() returned ${value.runtimeType}, expected a Widget';
}

/// Whether [error] means this build can never run the patch, however often it
/// retries — as opposed to a fault that might not recur.
///
/// Only a missing capability qualifies. It is a deployment fact: the capability
/// was added to the app after this binary shipped. Everything else (a null from
/// a service that was not ready, a transient callback failure) may well succeed
/// on the next build, and discarding a working patch over one is worse than
/// showing the fallback for a frame.
bool isUnrunnableOnThisBuild(Object error) =>
    error is MissingHostCapabilityException ||
    error is PatchOutputException ||
    // Deterministic: the budget counts instructions, not time, so a patch that
    // overruns it does so identically on every device for the same input.
    // Retrying re-enters the same loop, so recovery means rolling back.
    error is StepLimitExceededException;

/// The complete capability surface a build ships, as JSON for
/// `ejenix verify --capabilities`.
///
/// This has to be produced by the app, and only by the app. The CLI cannot: it
/// has no Flutter dependency (the SDK pins an older `meta` than the analyzer
/// needs), so it can enumerate the pure-Dart core and nothing else. A manifest
/// missing `Text` and `Column` would reject essentially every real patch —
/// worse than having no gate at all.
///
/// Pass the same [extend] the app gives [EjenixPatchView] or [InterpretedView],
/// so the manifest describes what this build can actually run:
///
/// ```dart
/// // tool/dump_capabilities.dart — run in CI, before publishing
/// void main() => print(capabilityManifest(appCapabilities(repo)));
/// ```
///
/// ```sh
/// dart run tool/dump_capabilities.dart > build/capabilities.json
/// ejenix verify home.bundle --key release.key.pub \
///   --capabilities build/capabilities.json     # exits 65 if unrunnable
/// ```
///
/// A capability registered conditionally (behind a feature flag, an A/B bucket)
/// will only appear if it is registered when this runs — build the manifest the
/// way the shipped app builds its registry.
String capabilityManifest(
  HostExtension? extend, {
  List<HostExtension?> variants = const [],
}) {
  // Union every variant, because a capability registered behind a feature flag
  // or an A/B bucket exists on some installs and not others. A manifest built
  // from one variant would reject a patch that is perfectly runnable for the
  // cohort it targets — the false-positive direction, which breaks working
  // patches rather than catching broken ones.
  //
  // The union is deliberately permissive: it answers "could any shipped build
  // run this?", not "will every build". Pair it with `--min-sdk` when a
  // capability is genuinely not everywhere.
  final globals = <String>{};
  final methods = <String>{};
  for (final e in [extend, ...variants]) {
    final ctx = BridgeContext();
    final r = flutterHostRegistry(ctx);
    e?.call(r, ctx);
    globals.addAll(r.globalNames);
    methods.addAll(r.methodNames);
  }

  return const JsonEncoder.withIndent('  ').convert({
    'note':
        'Capabilities this build registers. Generated by capabilityManifest(). '
        'Check a patch with `ejenix verify <bundle> --capabilities <this file>`.',
    'variants': 1 + variants.length,
    'globals': globals.toList()..sort(),
    'methods': methods.toList()..sort(),
  });
}
