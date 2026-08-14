# ejenix_flutter — the Flutter framework bridge

Render an Ejenix patch as a **real Flutter widget tree**. An
interpreted patch runs in the sandboxed VM and can only touch the host through
the registered allow-list — this package registers Flutter widgets, constants,
and helpers as host capabilities, so a patch's `build()` produces genuine
framework widgets that Flutter lays out and paints.

```dart
InterpretedView(module: patchModule)   // runs build() → a real Widget subtree
```

## How it works

The compiler lowers a widget constructor (`Text('hi', style: …)`) to a **host
call** whose single argument is a `{parameterName: value}` map (the calling
convention in `spec/host-api.md`). This package binds each widget name to a real
constructor that reads that map:

```dart
r.registerGlobal('Text', (_, a) {
  final m = a[0] as Map;
  return Text(m['data'] as String? ?? '', style: m['style'] as TextStyle?);
});
```

- **Widgets:** `Text`, `Container`, `SizedBox`, `Center`, `Padding`, `Column`,
  `Row`, `Expanded`, `Spacer`, `Icon`, `ElevatedButton`, `TextButton`,
  `GestureDetector`, `Card`, `AppBar`, `Scaffold`, `ListView`, `Wrap`, `Stack`,
  `Align`, `Opacity`, `Divider`, `CircularProgressIndicator`.
- **Helpers:** `EdgeInsets.all`/`.symmetric`, `Color`, `TextStyle`.
- **Constants:** `Colors.*`, `MainAxisAlignment.*`, `CrossAxisAlignment.*`,
  `Alignment.*`, `FontWeight.*`, `TextAlign.*`, `Icons.*` (static getters →
  host globals).
- **Callbacks:** an interpreted closure passed as `onPressed: () => …` /
  `onTap: …` is re-entered on the same interpreter when Flutter invokes it.

### State and interactivity

Define a `createState()` that returns a persistent state object (any interpreted
value — a class instance or even a list) and a `build(state)` that reads it.
`InterpretedView` creates the state once, passes it to every `build`, and a
`setState(() { … })` host call runs the mutation and triggers a real Flutter
rebuild — so an interpreted counter increments and re-renders, all in the
sandbox. `build` may also take the `BuildContext` (`build(context, state)`).

The set is a **starter**: add widgets by registering more globals — that is the
whole extension surface, and it stays inside the sandbox.

## Toolchain note

The bridge depends only on the analyzer-free runtime (`ejenix_interpreter`,
`ejenix_bundle`, `ejenix_bytecode`), never on `ejenix_compiler`. Reason: the
compiler needs `analyzer ^14`, which requires a newer `meta` than some Flutter
SDKs pin, so the two cannot share a package. **Compile patches with the pure-Dart
toolchain** (or a Dart/Flutter version whose `meta` matches the analyzer), ship
the signed bundle, and run it here. The tests hand-build modules to stay
analyzer-free.

## Status

Proven by widget tests (`flutter test`): an interpreted patch renders a real
`Column`/`Text` tree; a button callback re-enters the VM; and a stateful counter
increments and re-renders through `setState`. Extend it by registering more
widgets. Not yet covered: the long tail of the widget catalog, inherited-widget
lookups (`Theme.of`, `MediaQuery.of`), and animation drivers.
