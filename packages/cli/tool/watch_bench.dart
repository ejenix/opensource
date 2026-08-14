// Copyright (c) Ejenix authors. MIT license.

/// Measures the `ejenix watch` rebuild loop against the DoD's 500ms budget.
///
///     dart run packages/cli/tool/watch_bench.dart
///
/// It benchmarks the **real** example patch — 10 functions, importing the full
/// Flutter patch SDK — not a toy file, because the cost that matters is
/// re-resolving a realistic import graph.
///
/// The headline is the gap between the two numbers it prints. A cold compile
/// builds a fresh analyzer context and re-resolves the SDK and every dependency;
/// a warm rebuild reuses that context and re-resolves only the edited library.
/// `ejenix watch` pays the cold cost once, at boot, and the warm cost on every
/// save — which is what puts the loop two orders of magnitude inside the budget.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_cli/src/dev/patch_builder.dart';

const _patch = 'example/patchable_app/patches/home_screen.dart';
const _root = 'example/patchable_app';
const _iterations = 20;
const _budgetMs = 500;

Future<void> main() async {
  final file = File(_patch);
  if (!file.existsSync()) {
    stderr.writeln('run from the repo root: $_patch not found');
    exit(66);
  }
  final original = file.readAsStringSync();

  final builder = PatchBuilder(
    sourcePath: file.absolute.path,
    signer: Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 5)),
    metadata: const BundleMetadata(
      targetAppId: 'bench',
      targetFlutterVersion: '3.44.6',
      minSdk: '1.0.0',
    ),
    roots: [Directory(_root).absolute.path],
  );

  final cold = await builder.rebuild();
  if (!cold.ok) {
    stderr.writeln('the example patch does not compile: ${cold.errors.first}');
    exit(65);
  }

  final compile = <int>[];
  final sign = <int>[];
  final total = <int>[];

  try {
    for (var i = 0; i < _iterations; i++) {
      // A real edit: rewrite the file, exactly as a save would.
      file.writeAsStringSync('$original\n// benchmark edit $i\n');
      builder.invalidate(file.absolute.path);

      final build = await builder.rebuild();
      if (!build.ok) {
        stderr.writeln('rebuild failed: ${build.errors.first}');
        exit(65);
      }
      compile.add(build.compile.inMicroseconds);
      sign.add(build.sign.inMicroseconds);
      total.add(build.total.inMicroseconds);
    }
  } finally {
    file.writeAsStringSync(original);
    await builder.dispose();
  }

  compile.sort();
  sign.sort();
  total.sort();

  print('ejenix watch — rebuild loop');
  print('  patch: $_patch (${cold.functionCount} functions, full Flutter SDK)');
  print(
    '  cold start (paid once, when `ejenix watch` boots): '
    '${cold.total.inMilliseconds} ms',
  );
  print('  warm rebuild (n=$_iterations):');
  print('    compile   p50 ${_ms(compile, 50)}   p95 ${_ms(compile, 95)}');
  print('    sign      p50 ${_ms(sign, 50)}   p95 ${_ms(sign, 95)}');
  print(
    '    total     p50 ${_ms(total, 50)}   p95 ${_ms(total, 95)}   '
    'max ${_ms(total, 100)}',
  );

  final worstMs = total.last / 1000;
  print(
    '  budget: ${_budgetMs}ms — worst ${worstMs.toStringAsFixed(1)}ms '
    '(${(_budgetMs / worstMs).toStringAsFixed(0)}x headroom)',
  );
  if (worstMs >= _budgetMs) exit(1);
}

/// The [percentile] of [sorted] microsecond samples, rendered as milliseconds.
String _ms(List<int> sorted, int percentile) {
  final index = (sorted.length * percentile / 100).floor().clamp(
    0,
    sorted.length - 1,
  );
  return '${(sorted[index] / 1000).toStringAsFixed(1)} ms';
}
