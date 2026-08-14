// Copyright (c) Ejenix authors. MIT license.

/// Compiles the bridge's test patches from **real Dart source** into encoded
/// modules under `test/fixtures/`, which the Flutter widget tests decode and
/// render.
///
/// This exists because `flutter_bridge` cannot depend on `ejenix_compiler`: the
/// Flutter SDK pins an older `meta` than `analyzer` requires, so the two cannot
/// share a package (see `pubspec.yaml`). Without this step the widget tests
/// would have to hand-assemble bytecode, which would prove the *interpreter*
/// works but not that a patch a developer actually writes compiles and renders.
///
/// Run from the repo root, where the pure-Dart workspace resolves the compiler:
///
/// ```
/// dart run tool/gen_bridge_fixtures.dart          # regenerate
/// dart run tool/gen_bridge_fixtures.dart --check  # CI: assert no drift
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_compiler/compiler.dart';

/// The metadata stamped into each fixture. Fixed, so output stays deterministic.
const _metadata = BundleMetadata(
  targetAppId: 'com.example.bridge_fixtures',
  targetFlutterVersion: '3.44.0',
  minSdk: '1.0.0',
);

/// Each fixture is a patch a developer could plausibly write, named by the
/// bridge capability it exercises.
const _patches = <String, String>{
  // A patch that reaches an *app* capability, not just the bridge's built-ins.
  // This is the shape that broke in production: the patch compiles fine against
  // the regenerated SDK, and whether it runs depends entirely on whether the
  // binary on the device registers `App.blogs`. Rendered with and without that
  // registration, it is the real bug and its own control.
  'app_capability': '''
external String appBlogsTitle();

Widget build() {
  return Column(
    children: [
      Text('Blogs'),
      Text(appBlogsTitle()),
    ],
  );
}
''',

  // A plain stateless tree: nested layout, styling, and a list of children.
  'hello': '''
Widget build() {
  return Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text('Hello from a patch', style: TextStyle(fontSize: 24.0)),
      SizedBox(height: 8.0),
      Text('rendered by the interpreter'),
    ],
  );
}
''',

  // Stateful counter: `createState` runs once, `setState` mutates it, and the
  // zero-argument `onPressed` callback re-enters the VM.
  'counter': '''
class CounterState {
  int count = 0;
}

CounterState createState() => CounterState();

Widget build(CounterState state) {
  return Column(
    children: [
      Text('Count: \${state.count}'),
      ElevatedButton(
        onPressed: () {
          setState(() {
            state.count = state.count + 1;
          });
        },
        child: Text('Increment'),
      ),
    ],
  );
}
''',

  // A one-argument callback (`onChanged`) plus a host object the patch holds
  // across rebuilds (TextEditingController) and reads back (`.text`).
  'text_input': '''
class FormState_ {
  String typed = '';
}

FormState_ createState() => FormState_();

Widget build(FormState_ state) {
  return Column(
    children: [
      TextField(
        decoration: InputDecoration(labelText: 'Name'),
        onChanged: (v) {
          setState(() {
            state.typed = v;
          });
        },
      ),
      Text('Hello, \${state.typed}'),
    ],
  );
}
''',

  // A two-argument builder that must return a Widget, driven lazily per row.
  'list_builder': '''
Widget build() {
  return ListView.builder(
    itemCount: 3,
    itemBuilder: (context, i) {
      return ListTile(title: Text('Row \$i'));
    },
  );
}
''',

  // Toggles: a bool `onChanged` round-trip through the VM.
  'toggles': '''
class ToggleState {
  bool on = false;
}

ToggleState createState() => ToggleState();

Widget build(ToggleState state) {
  return Column(
    children: [
      Switch(
        value: state.on,
        onChanged: (v) {
          setState(() {
            state.on = v;
          });
        },
      ),
      Text(state.on ? 'ON' : 'OFF'),
    ],
  );
}
''',

  // The widgets a real mobile screen is built from: an overlay, a notch-safe
  // inset, chips that wrap, a clipped + rotated box, and a grid. Compiled from
  // real source, so a binding that is registered but broken fails here rather
  // than on a user's phone.
  'mobile_chrome': '''
Widget build() {
  return SafeArea(
    child: Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            Wrap(
              spacing: 8.0,
              alignment: WrapAlignment.center,
              children: [
                Chip(label: Text('one')),
                Chip(label: Text('two')),
              ],
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(8.0),
              child: Transform.rotate(
                angle: 0.1,
                child: Container(width: 40.0, height: 40.0, color: Colors.teal),
              ),
            ),
            CircularProgressIndicator(value: 0.5, color: Colors.indigo),
          ],
        ),
        Positioned(
          right: 8.0,
          bottom: 8.0,
          child: Text('overlay'),
        ),
      ],
    ),
  );
}
''',

  // Tabs need a DefaultTabController ancestor, because a patch cannot own a
  // TickerProvider — the same constraint that limits animations to implicit ones.
  'tabs': '''
Widget build() {
  return DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: Text('Tabs'),
        bottom: TabBar(tabs: [Tab(text: 'One'), Tab(text: 'Two')]),
      ),
      body: TabBarView(children: [Text('first'), Text('second')]),
    ),
  );
}
''',

  // A grid, a dropdown, and a radio group — selection lives on the RadioGroup
  // ancestor, which is Flutter's current API.
  'forms': '''
class FormState2 {
  Object? choice = 'a';
  Object? picked;
}

FormState2 createState() => FormState2();

Widget build(FormState2 state) {
  return Column(
    children: [
      RadioGroup(
        groupValue: state.choice,
        onChanged: (v) {
          setState(() {
            state.choice = v;
          });
        },
        child: Row(
          children: [Radio(value: 'a'), Radio(value: 'b')],
        ),
      ),
      DropdownButton(
        value: state.picked,
        hint: Text('pick'),
        items: [
          DropdownMenuItem(value: 'x', child: Text('X')),
          DropdownMenuItem(value: 'y', child: Text('Y')),
        ],
        onChanged: (v) {
          setState(() {
            state.picked = v;
          });
        },
      ),
      Text('choice=\${state.choice}'),
    ],
  );
}
''',
};

/// The typed API surface every patch imports. Compiling against it is the point:
/// it proves the patch SDK and the bridge's host bindings agree.
final _patchSdk = File('flutter_bridge/patch_sdk/flutter.dart');

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  final dir = Directory('flutter_bridge/test/fixtures');
  if (!check) dir.createSync(recursive: true);
  if (!_patchSdk.existsSync()) {
    stderr.writeln('missing patch SDK: ${_patchSdk.path} (run from repo root)');
    exitCode = 1;
    return;
  }
  final sdkSource = _patchSdk.readAsStringSync();

  var drifted = false;
  for (final entry in _patches.entries) {
    // Compile the patch on disk beside the SDK, so `import 'flutter.dart'`
    // resolves through a real analyzer context.
    final work = Directory.systemTemp.createTempSync('ejenix_fixture');
    final CompileResult result;
    try {
      File('${work.path}/flutter.dart').writeAsStringSync(sdkSource);
      final patch = File('${work.path}/patch.dart')
        ..writeAsStringSync("import 'flutter.dart';\n\n${entry.value}");
      result = await Compiler().compileFile(
        patch.path,
        displayPath: '${entry.key}.dart',
      );
    } finally {
      work.deleteSync(recursive: true);
    }

    if (result.hasErrors) {
      stderr.writeln('fixture `${entry.key}` failed to compile:');
      for (final d in result.diagnostics) {
        stderr.writeln('  $d');
      }
      exitCode = 1;
      return;
    }
    final bytes = ModuleCodec.encodeBody(result.moduleOrThrow, _metadata);
    final file = File('${dir.path}/${entry.key}.mod');

    if (check) {
      if (!file.existsSync() || !_same(file.readAsBytesSync(), bytes)) {
        stderr.writeln('fixture out of date: ${file.path}');
        drifted = true;
      }
    } else {
      file.writeAsBytesSync(bytes);
      stdout.writeln('wrote ${file.path} (${bytes.length} bytes)');
    }
  }

  if (check && drifted) {
    stderr.writeln(
      '\nRun `dart run tool/gen_bridge_fixtures.dart` and commit '
      'the result.',
    );
    exitCode = 1;
  } else if (check) {
    stdout.writeln('fixtures up to date (${_patches.length})');
  }
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
