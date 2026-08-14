// Copyright (c) Ejenix authors. MIT license.

/// `Duration` and `dart:convert` are part of the core allow-list: pure values
/// and pure computation, crossing no sandbox boundary. A patch needs them to
/// drive an implicit animation and to make sense of bytes a host-granted network
/// capability returns.
library;

import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

Future<Object?> run(String source) async {
  final result = await Compiler().compileSource(source);
  if (result.hasErrors) {
    fail('unexpected errors:\n${result.diagnostics.join('\n')}');
  }
  return Interpreter(result.moduleOrThrow).runAsync();
}

void main() {
  group('Duration', () {
    test('constructs from named units', () async {
      const src = '''
int main() {
  final d = Duration(milliseconds: 250);
  return d.inMilliseconds;
}
''';
      expect(await run(src), 250);
    });

    test('units compose', () async {
      const src = '''
int main() => Duration(minutes: 2, seconds: 30).inSeconds;
''';
      expect(await run(src), 150);
    });
  });

  group('dart:convert', () {
    test('jsonDecode reads an object into a Map', () async {
      const src = r'''
import 'dart:convert';

String main() {
  final data = jsonDecode('{"name":"ada","age":36}') as Map;
  return '${data['name']}:${data['age']}';
}
''';
      expect(await run(src), 'ada:36');
    });

    test('jsonDecode reads a list of objects', () async {
      const src = r'''
import 'dart:convert';

int main() {
  final todos = jsonDecode('[{"id":1},{"id":2},{"id":3}]') as List;
  var sum = 0;
  for (final t in todos) {
    sum += (t as Map)['id'] as int;
  }
  return sum;
}
''';
      expect(await run(src), 6);
    });

    test('jsonEncode round-trips', () async {
      const src = r'''
import 'dart:convert';

String main() {
  final encoded = jsonEncode({'a': 1, 'b': [2, 3]});
  final back = jsonDecode(encoded) as Map;
  return '$encoded|${(back['b'] as List).length}';
}
''';
      expect(await run(src), '{"a":1,"b":[2,3]}|2');
    });
  });
}
