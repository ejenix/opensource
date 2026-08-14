// Copyright (c) Ejenix authors. MIT license.

/// The app's own state and services.
///
/// A patch never *owns* this and cannot reach it directly — it can only call the
/// capabilities the app chooses to grant (see `app_capabilities.dart`). That is
/// the answer to "how do I do state management in a patch": you don't bridge
/// Provider or Riverpod (they are codegen- and compile-time-heavy, and the wrong
/// layer). The shipped binary keeps ownership of state, and hands the patch a
/// narrow, named door to it.
library;

import 'package:ejenix_flutter/ejenix_flutter.dart' show Patchable;

class Todo {
  Todo({required this.id, required this.title, this.done = false});

  final int id;
  final String title;
  bool done;
}

/// Holds the app's todos and the (simulated) network call that refreshes them.
class TodoRepository {
  TodoRepository()
    : _todos = [
        Todo(id: 1, title: 'Ship the interpreter', done: true),
        Todo(id: 2, title: 'Write the patch SDK'),
        Todo(id: 3, title: 'Push a patch in minutes, not a release cycle'),
      ],
      _nextId = 4;

  final List<Todo> _todos;
  int _nextId;

  /// The shape a patch sees: plain maps, so they marshal across the sandbox
  /// boundary as ordinary `List`/`Map` values the interpreter already allows.
  @Patchable('App.todos')
  List<Map<String, Object?>> get todosForPatch => [
    for (final t in _todos) {'id': t.id, 'title': t.title, 'done': t.done},
  ];

  @Patchable('App.pendingCount')
  int get pendingCount => _todos.where((t) => !t.done).length;

  @Patchable('App.addTodo')
  void add(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    _todos.add(Todo(id: _nextId++, title: trimmed));
  }

  @Patchable('App.toggleTodo')
  void toggle(int id) {
    for (final t in _todos) {
      if (t.id == id) t.done = !t.done;
    }
  }

  /// Stands in for a real API call. The patch triggers it, but the app owns the
  /// URL, the auth, and the retry policy — none of which a patch can see or
  /// change. This is why the bridge grants no network access by default.
  @Patchable('App.refresh', true)
  Future<void> refresh() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    add('Synced at ${DateTime.now().second}s');
  }
}
