// Copyright (c) Ejenix authors. MIT license.

// The home screen, as an interpreted patch.
//
// This file is compiled to bytecode, signed, and shipped over the air. It is
// NOT part of the app binary — change it, re-publish, and the screen changes on
// devices already in the field, in minutes rather than a release cycle.
//
// It reaches the outside world only through the two imports below: the widgets
// the bridge exposes, and the capabilities *this app* granted. Anything else —
// dart:io, a raw HTTP call, a widget nobody registered — fails to compile.

import '../patch_sdk/flutter.dart';
import '../patch_sdk/app.dart';

/// Patch-local state, created once and preserved across rebuilds.
///
/// A patch may hold host objects — the controller here is a real
/// [TextEditingController] living in the app's heap, reachable only through the
/// selectors the allow-list grants (`.text`, `.clear()`).
class HomeState {
  final TextEditingController draft = TextEditingController();
}

HomeState createState() => HomeState();

Widget build(BuildContext context, HomeState state) {
  final todos = App.todos;

  return Scaffold(
    appBar: AppBar(
      title: Text('Todos'),
      actions: [
        IconButton(
          icon: Icon(Icons.refresh),
          tooltip: 'Sync',
          onPressed: () {
            App.refresh();
          },
        ),
      ],
    ),
    body: Padding(
      padding: EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The app's own widget, in the app's own design language.
          StatCard(label: 'Pending', value: '${App.pendingCount}'),
          SizedBox(height: 16.0),

          TextField(
            controller: state.draft,
            decoration: InputDecoration(
              labelText: 'New todo',
              border: OutlineInputBorder(),
            ),
          ),
          SizedBox(height: 8.0),

          PrimaryButton(
            label: 'Add',
            onPressed: () {
              setState(() {
                App.addTodo(state.draft.text);
                state.draft.clear();
              });
            },
          ),
          SizedBox(height: 16.0),

          Expanded(
            child: ListView.builder(
              itemCount: todos.length,
              itemBuilder: (context, i) {
                final todo = todos[i];
                final title = todo['title'] as String;
                final done = todo['done'] as bool;

                return ListTile(
                  leading: Checkbox(
                    value: done,
                    onChanged: (v) {
                      setState(() {
                        App.toggleTodo(todo['id'] as int);
                      });
                    },
                  ),
                  title: Text(
                    title,
                    style: TextStyle(color: done ? Colors.grey : Colors.black),
                  ),
                  onTap: () {
                    ScaffoldMessenger.showSnackBar(
                      context,
                      SnackBar(content: Text('Tapped $title')),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
