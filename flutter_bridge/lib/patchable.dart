// Copyright (c) Ejenix authors. MIT license.

/// Annotations that let `ejenix gen` write your capability plumbing for you.
///
/// A capability normally has to be declared **twice** — once as an `external`
/// declaration in the patch SDK (so a patch type-checks), and once as a
/// `registerGlobal` binding in your `HostExtension` (so it actually runs). That
/// duplication is mechanical and drift-prone.
///
/// Mark the real thing — a widget class, a static or instance method, a getter,
/// or a top-level function — with [Patchable], and run `ejenix gen`. It reads
/// these annotations off your real code and generates *both* halves, so the
/// signature is written once, where it already lives.
library;

/// Marks a declaration as a capability an interpreted patch may use.
///
/// Put it on:
///
/// * a **widget class** — its unnamed constructor becomes a patch-constructable
///   widget (`@patchable class PrimaryButton extends StatelessWidget { … }`);
/// * a **method, getter, or top-level function** — it becomes a callable the
///   patch can invoke (`@Patchable('App.addTodo') void add(String t) { … }`).
///
/// Give [name] to choose the patch-facing name — including a `Namespace.member`
/// form that groups the member under a class in the generated SDK (so
/// `@Patchable('App.addTodo')` is reached as `App.addTodo` from a patch). Omit
/// it to expose the declaration under its own name.
///
/// Pass `rebuild: true` on a method that mutates app state the patch does not
/// own (a refresh, a sync): the generated binding then asks the hosting view to
/// rebuild after the call — awaiting it first if it returns a `Future` — so the
/// screen reflects the change without the patch having to `setState`.
class Patchable {
  /// Exposes the annotated declaration, optionally renamed to [name], and
  /// requesting a view rebuild afterwards when [rebuild] is set.
  const Patchable([this.name, this.rebuild = false]);

  /// The patch-facing name. `null` uses the declaration's own name. A `.` groups
  /// the member under a namespace class in the generated SDK.
  final String? name;

  /// Whether the generated binding requests a view rebuild after the call.
  /// Ignored for widgets and getters.
  final bool rebuild;
}

/// The zero-configuration [Patchable] — exposes a declaration under its own
/// name. Use `@patchable` where you do not need to rename or namespace.
const patchable = Patchable();
