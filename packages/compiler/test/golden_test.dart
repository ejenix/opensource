// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_compiler/compiler.dart';
import 'package:test/test.dart';

/// Golden tests pin the exact bytecode the compiler emits. They guard against
/// silent codegen changes and, because the output is byte-stable, they are the
/// visible face of the determinism guarantee (brief §6.2, §6.13).
///
/// Regenerate after an intentional codegen change with:
///
/// ```sh
/// REGEN_GOLDENS=1 dart test packages/compiler/test/golden_test.dart
/// ```
/// Resolves the golden directory whether tests are run from the package root
/// (`dart test`) or the workspace root (`dart test packages/compiler/...`).
Directory _goldenDir() {
  for (final candidate in ['test/golden', 'packages/compiler/test/golden']) {
    final dir = Directory(candidate);
    if (dir.existsSync()) return dir;
  }
  throw StateError('golden directory not found from ${Directory.current.path}');
}

void main() {
  final goldenDir = _goldenDir();
  final regen = Platform.environment['REGEN_GOLDENS'] == '1';

  for (final entry in goldenDir.listSync().whereType<File>()) {
    if (!entry.path.endsWith('.dart')) continue;
    final name = entry.uri.pathSegments.last;

    test('golden: $name', () async {
      final result = await Compiler().compileFile(entry.absolute.path);
      expect(result.hasErrors, isFalse, reason: result.diagnostics.join('\n'));
      final disassembly = Disassembler.disassemble(result.moduleOrThrow);
      final goldenFile = File('${entry.path}.golden');

      if (regen) {
        goldenFile.writeAsStringSync(disassembly);
        return;
      }
      expect(
        goldenFile.existsSync(),
        isTrue,
        reason: 'missing golden; run with REGEN_GOLDENS=1',
      );
      expect(disassembly, goldenFile.readAsStringSync());
    });
  }
}
