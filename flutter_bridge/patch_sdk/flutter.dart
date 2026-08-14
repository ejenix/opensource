// Copyright (c) Ejenix authors. MIT license.

/// The typed Flutter API surface a **patch** is written against.
///
/// A patch is compiled by the pure-Dart toolchain, which cannot see
/// `package:flutter` (the Flutter SDK pins an older `meta` than `analyzer`
/// requires, so they cannot share a package). Import this file instead:
///
/// ```dart
/// import 'flutter.dart';
///
/// Widget build() => Center(child: Text('hello'));
/// ```
///
/// Every declaration here is `external`: it has no body, and the compiler
/// lowers each use to a host call through the [HostRegistry] allow-list. The
/// implementations live in `ejenix_flutter.dart` — **this file and that one are
/// two halves of one contract**, and `test/api_surface_test.dart` fails if they
/// drift apart.
///
/// This is also what makes patch authoring real: a patch gets type checking and
/// IDE completion, and anything *not* declared here is not in the sandbox.
library;

// --- Foundations -------------------------------------------------------------

/// The base of the widget tree. A patch's `build()` returns one of these.
abstract class Widget {}

/// The handle Flutter passes to a builder callback. Opaque to a patch.
abstract class BuildContext {}

/// A widget that can sit in [Scaffold.appBar].
abstract class PreferredSizeWidget implements Widget {}

/// Runs [fn], then rebuilds the interpreted view, so a mutation to the patch's
/// state object is reflected on screen.
external void setState(void Function() fn);

// --- Values ------------------------------------------------------------------

class Color {
  external Color(int value);
}

class IconData {}

class TextStyle {
  external TextStyle({
    double? fontSize,
    Color? color,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    double? letterSpacing,
    double? height,
  });
}

class EdgeInsets {
  external EdgeInsets.all(double value);
  external EdgeInsets.symmetric({double horizontal, double vertical});
  external EdgeInsets.only({
    double left,
    double top,
    double right,
    double bottom,
  });
  external EdgeInsets.fromLTRB(
    double left,
    double top,
    double right,
    double bottom,
  );
  external static EdgeInsets get zero;
}

class BorderRadius {
  external BorderRadius.circular(double radius);
}

class BoxDecoration {
  external BoxDecoration({
    Color? color,
    BorderRadius? borderRadius,
    BoxShape? shape,
  });
}

class InputBorder {}

class OutlineInputBorder implements InputBorder {
  external OutlineInputBorder();
}

class InputDecoration {
  external InputDecoration({
    String? labelText,
    String? hintText,
    String? errorText,
    InputBorder? border,
  });
}

/// A text field's value, created once in `createState()` and read back later.
class TextEditingController {
  external TextEditingController({String text});
  external String get text;
  external void clear();
}

/// The result handed to a [FutureBuilder] / [StreamBuilder] builder.
class AsyncSnapshot<T> {
  external bool get hasData;
  external T? get data;
  external bool get hasError;
  external Object? get error;
  external ConnectionState get connectionState;
}

// --- Enumerations ------------------------------------------------------------

class MainAxisAlignment {
  external static MainAxisAlignment get start;
  external static MainAxisAlignment get center;
  external static MainAxisAlignment get end;
  external static MainAxisAlignment get spaceBetween;
  external static MainAxisAlignment get spaceAround;
  external static MainAxisAlignment get spaceEvenly;
}

class CrossAxisAlignment {
  external static CrossAxisAlignment get start;
  external static CrossAxisAlignment get center;
  external static CrossAxisAlignment get end;
  external static CrossAxisAlignment get stretch;
}

class MainAxisSize {
  external static MainAxisSize get min;
  external static MainAxisSize get max;
}

class FontWeight {
  external static FontWeight get normal;
  external static FontWeight get bold;
  external static FontWeight get w300;
  external static FontWeight get w500;
  external static FontWeight get w600;
}

class FontStyle {
  external static FontStyle get normal;
  external static FontStyle get italic;
}

class TextAlign {
  external static TextAlign get left;
  external static TextAlign get center;
  external static TextAlign get right;
}

class TextOverflow {
  external static TextOverflow get clip;
  external static TextOverflow get ellipsis;
  external static TextOverflow get fade;
}

class BoxFit {
  external static BoxFit get cover;
  external static BoxFit get contain;
  external static BoxFit get fill;
  external static BoxFit get fitWidth;
  external static BoxFit get fitHeight;
}

class BoxShape {
  external static BoxShape get rectangle;
  external static BoxShape get circle;
}

class ConnectionState {
  external static ConnectionState get none;
  external static ConnectionState get waiting;
  external static ConnectionState get active;
  external static ConnectionState get done;
}

class Alignment {
  external static Alignment get center;
  external static Alignment get topLeft;
  external static Alignment get topCenter;
  external static Alignment get topRight;
  external static Alignment get centerLeft;
  external static Alignment get centerRight;
  external static Alignment get bottomLeft;
  external static Alignment get bottomCenter;
  external static Alignment get bottomRight;
}

class Colors {
  external static Color get red;
  external static Color get green;
  external static Color get blue;
  external static Color get black;
  external static Color get white;
  external static Color get orange;
  external static Color get purple;
  external static Color get yellow;
  external static Color get teal;
  external static Color get pink;
  external static Color get amber;
  external static Color get indigo;
  external static Color get cyan;
  external static Color get brown;
  external static Color get grey;
  external static Color get transparent;
}

class Icons {
  external static IconData get add;
  external static IconData get remove;
  external static IconData get star;
  external static IconData get home;
  external static IconData get favorite;
  external static IconData get settings;
  external static IconData get search;
  external static IconData get menu;
  external static IconData get close;
  external static IconData get check;
  external static IconData get edit;
  external static IconData get delete;
  external static IconData get person;
  external static IconData get arrow_back;
  external static IconData get arrow_forward;
  external static IconData get refresh;
  external static IconData get share;
  external static IconData get info;
  external static IconData get warning;
  external static IconData get error;
  external static IconData get shopping_cart;
  external static IconData get notifications;
}

// --- Layout ------------------------------------------------------------------

class SizedBox implements Widget {
  external SizedBox({double? width, double? height, Widget? child});
}

class Container implements Widget {
  external Container({
    double? width,
    double? height,
    Color? color,
    Alignment? alignment,
    EdgeInsets? padding,
    EdgeInsets? margin,
    BoxDecoration? decoration,
    Widget? child,
  });
}

class Center implements Widget {
  external Center({Widget? child});
}

class Padding implements Widget {
  external Padding({required EdgeInsets padding, Widget? child});
}

class Column implements Widget {
  external Column({
    MainAxisAlignment? mainAxisAlignment,
    CrossAxisAlignment? crossAxisAlignment,
    MainAxisSize? mainAxisSize,
    List<Widget> children,
  });
}

class Row implements Widget {
  external Row({
    MainAxisAlignment? mainAxisAlignment,
    CrossAxisAlignment? crossAxisAlignment,
    MainAxisSize? mainAxisSize,
    List<Widget> children,
  });
}

class Expanded implements Widget {
  external Expanded({int flex, required Widget child});
}

class Flexible implements Widget {
  external Flexible({int flex, required Widget child});
}

class Stack implements Widget {
  external Stack({Alignment? alignment, StackFit? fit, List<Widget> children});
}

class Positioned implements Widget {
  external Positioned({
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
    required Widget child,
  });
}

class Wrap implements Widget {
  external Wrap({
    double spacing,
    double runSpacing,
    WrapAlignment? alignment,
    List<Widget> children,
  });
}

class Align implements Widget {
  external Align({Alignment? alignment, Widget? child});
}

class AspectRatio implements Widget {
  external AspectRatio({required double aspectRatio, Widget? child});
}

class SafeArea implements Widget {
  external SafeArea({
    bool top,
    bool bottom,
    bool left,
    bool right,
    required Widget child,
  });
}

class SingleChildScrollView implements Widget {
  external SingleChildScrollView({EdgeInsets? padding, Widget? child});
}

class Spacer implements Widget {
  external Spacer();
}

// --- Display -----------------------------------------------------------------

class Text implements Widget {
  external Text(
    String data, {
    TextStyle? style,
    TextAlign? textAlign,
    TextOverflow? overflow,
    int? maxLines,
  });
}

class Icon implements Widget {
  external Icon(IconData? icon, {double? size, Color? color});
}

class Image implements Widget {
  external Image.network(
    String src, {
    double? width,
    double? height,
    BoxFit? fit,
  });
  external Image.asset(
    String name, {
    double? width,
    double? height,
    BoxFit? fit,
  });
}

class CircleAvatar implements Widget {
  external CircleAvatar({
    double? radius,
    Color? backgroundColor,
    Widget? child,
  });
}

class Chip implements Widget {
  external Chip({
    required Widget label,
    Widget? avatar,
    Color? backgroundColor,
  });
}

class Card implements Widget {
  external Card({
    Color? color,
    double? elevation,
    EdgeInsets? margin,
    Widget? child,
  });
}

class Divider implements Widget {
  external Divider({double? height, double? thickness, Color? color});
}

class Opacity implements Widget {
  external Opacity({required double opacity, Widget? child});
}

class CircularProgressIndicator implements Widget {
  external CircularProgressIndicator({double? value, Color? color});
}

class LinearProgressIndicator implements Widget {
  external LinearProgressIndicator({double? value, Color? color});
}

class Tooltip implements Widget {
  external Tooltip({required String message, Widget? child});
}

class Placeholder implements Widget {
  external Placeholder();
}

// --- Input and buttons -------------------------------------------------------

class ElevatedButton implements Widget {
  external ElevatedButton({
    required void Function()? onPressed,
    required Widget child,
  });
}

class TextButton implements Widget {
  external TextButton({
    required void Function()? onPressed,
    required Widget child,
  });
}

class OutlinedButton implements Widget {
  external OutlinedButton({
    required void Function()? onPressed,
    required Widget child,
  });
}

class IconButton implements Widget {
  external IconButton({
    required void Function()? onPressed,
    required Widget icon,
    String? tooltip,
    Color? color,
  });
}

class FloatingActionButton implements Widget {
  external FloatingActionButton({
    required void Function()? onPressed,
    String? tooltip,
    Color? backgroundColor,
    Widget? child,
  });
}

class GestureDetector implements Widget {
  external GestureDetector({
    void Function()? onTap,
    void Function()? onLongPress,
    Widget? child,
  });
}

class InkWell implements Widget {
  external InkWell({
    void Function()? onTap,
    void Function()? onLongPress,
    Widget? child,
  });
}

class TextField implements Widget {
  external TextField({
    TextEditingController? controller,
    void Function(String)? onChanged,
    void Function(String)? onSubmitted,
    bool obscureText,
    InputDecoration? decoration,
  });
}

class Checkbox implements Widget {
  external Checkbox({
    required bool value,
    required void Function(bool?)? onChanged,
  });
}

class Switch implements Widget {
  external Switch({
    required bool value,
    required void Function(bool)? onChanged,
  });
}

class Slider implements Widget {
  external Slider({
    required double value,
    double min,
    double max,
    int? divisions,
    String? label,
    required void Function(double)? onChanged,
  });
}

// --- Structure ---------------------------------------------------------------

class Scaffold implements Widget {
  external Scaffold({
    PreferredSizeWidget? appBar,
    Widget? body,
    Widget? floatingActionButton,
    Widget? drawer,
    Widget? bottomNavigationBar,
    Color? backgroundColor,
  });
}

class AppBar implements PreferredSizeWidget {
  external AppBar({
    Widget? title,
    bool? centerTitle,
    Color? backgroundColor,
    Widget? leading,
    double? elevation,
    List<Widget>? actions,
    PreferredSizeWidget? bottom,
  });
}

class Material implements Widget {
  external Material({Color? color, double elevation, Widget? child});
}

class ListView implements Widget {
  external ListView({EdgeInsets? padding, List<Widget> children});

  /// Builds rows lazily: [itemBuilder] re-enters the interpreter per visible
  /// row, so a long list does not materialize up front.
  external ListView.builder({
    int? itemCount,
    EdgeInsets? padding,
    required Widget Function(BuildContext, int) itemBuilder,
  });
}

class ListTile implements Widget {
  external ListTile({
    Widget? leading,
    Widget? title,
    Widget? subtitle,
    Widget? trailing,
    void Function()? onTap,
  });
}

class BottomNavigationBarItem {
  external BottomNavigationBarItem({required Widget icon, String? label});
}

class BottomNavigationBar implements Widget {
  external BottomNavigationBar({
    int currentIndex,
    void Function(int)? onTap,
    required List<BottomNavigationBarItem> items,
  });
}

class AlertDialog implements Widget {
  external AlertDialog({Widget? title, Widget? content, List<Widget>? actions});
}

// --- Layout, part two --------------------------------------------------------

class StackFit {
  external static StackFit get loose;
  external static StackFit get expand;
}

class WrapAlignment {
  external static WrapAlignment get start;
  external static WrapAlignment get center;
  external static WrapAlignment get spaceBetween;
}

class ClipRRect implements Widget {
  external ClipRRect({BorderRadius? borderRadius, Widget? child});
}

/// Only the two transforms a patch can express safely. A general `Matrix4` is
/// not exposed: nobody hand-writes one, and it is a footgun across the boundary.
class Transform {
  external static Widget rotate({required double angle, Widget? child});
  external static Widget scale({required double scale, Widget? child});
}

// --- Scrolling and paging ----------------------------------------------------

class GridView implements Widget {
  external GridView.builder({
    int? itemCount,
    required int crossAxisCount,
    double mainAxisSpacing,
    double crossAxisSpacing,
    double childAspectRatio,
    EdgeInsets? padding,
    required Widget Function(BuildContext, int) itemBuilder,
  });
}

class PageView implements Widget {
  external PageView({void Function(int)? onPageChanged, List<Widget> children});
}

/// `onRefresh` may be `async`; the indicator awaits the Future it returns, so
/// the spinner stops when your work does.
class RefreshIndicator implements Widget {
  external RefreshIndicator({
    required Future<void> Function() onRefresh,
    required Widget child,
  });
}

// --- Drawers, tabs, forms, and inputs ----------------------------------------

class Drawer implements Widget {
  external Drawer({Widget? child});
}

/// Wrap a [TabBar]/[TabBarView] in a [DefaultTabController]. A patch cannot own
/// a `TickerProvider`, so it cannot construct a `TabController` itself — the
/// same reason only implicit animations are available.
class DefaultTabController implements Widget {
  external DefaultTabController({required int length, required Widget child});
}

class TabBar implements PreferredSizeWidget {
  external TabBar({List<Widget> tabs});
}

class Tab implements Widget {
  external Tab({String? text, Widget? icon});
}

class TabBarView implements Widget {
  external TabBarView({List<Widget> children});
}

class Form implements Widget {
  external Form({required Widget child});
}

/// Selection lives on the enclosing [RadioGroup], not on each [Radio] — this is
/// Flutter's current API (`groupValue`/`onChanged` on `Radio` were deprecated in
/// 3.32).
class RadioGroup implements Widget {
  external RadioGroup({
    Object? groupValue,
    void Function(Object?)? onChanged,
    required Widget child,
  });
}

class Radio implements Widget {
  external Radio({required Object? value});
}

class DropdownMenuItem implements Widget {
  external DropdownMenuItem({required Object? value, required Widget child});
}

class DropdownButton implements Widget {
  external DropdownButton({
    Object? value,
    Widget? hint,
    bool isExpanded,
    List<DropdownMenuItem> items,
    void Function(Object?)? onChanged,
  });
}

// --- Navigation and feedback -------------------------------------------------

/// Navigation is **route-name only** by design: a patch travels to routes the
/// app already declared, so it can never reach a destination the shipped binary
/// did not intend.
class Navigator {
  external static void pop(BuildContext context, [Object? result]);
  external static Future<Object?> pushNamed(
    BuildContext context,
    String routeName, {
    Object? arguments,
  });
  external static bool canPop(BuildContext context);
}

/// Shows a modal dialog. Differs from `package:flutter`, which spells this
/// `ScaffoldMessenger.of(context)` — the bridge flattens the `of(context)` step.
class ScaffoldMessenger {
  external static void showSnackBar(BuildContext context, SnackBar snackBar);
}

class SnackBar implements Widget {
  external SnackBar({
    required Widget content,
    Duration? duration,
    Color? backgroundColor,
  });
}

external Future<Object?> showDialog({
  required BuildContext context,
  required Widget Function(BuildContext) builder,
  bool barrierDismissible,
});

// --- Implicit animations -----------------------------------------------------

/// The easing of an implicit animation. Only *implicit* animations are
/// available: explicit ones (`AnimationController`) need a `TickerProvider` tied
/// to the host element's lifecycle, which a patch cannot own.
class Curve {}

class Curves {
  external static Curve get linear;
  external static Curve get easeIn;
  external static Curve get easeOut;
  external static Curve get easeInOut;
  external static Curve get fastOutSlowIn;
  external static Curve get bounceOut;
}

class AnimatedContainer implements Widget {
  external AnimatedContainer({
    required Duration duration,
    Curve? curve,
    double? width,
    double? height,
    Color? color,
    Alignment? alignment,
    EdgeInsets? padding,
    EdgeInsets? margin,
    BoxDecoration? decoration,
    Widget? child,
  });
}

class AnimatedOpacity implements Widget {
  external AnimatedOpacity({
    required Duration duration,
    Curve? curve,
    required double opacity,
    Widget? child,
  });
}

class AnimatedSwitcher implements Widget {
  external AnimatedSwitcher({required Duration duration, Widget? child});
}

class Hero implements Widget {
  external Hero({required Object tag, required Widget child});
}

// --- Async builders ----------------------------------------------------------

class FutureBuilder<T> implements Widget {
  external FutureBuilder({
    Future<T>? future,
    T? initialData,
    required Widget Function(BuildContext, AsyncSnapshot<T>) builder,
  });
}

class StreamBuilder<T> implements Widget {
  external StreamBuilder({
    Stream<T>? stream,
    T? initialData,
    required Widget Function(BuildContext, AsyncSnapshot<T>) builder,
  });
}
