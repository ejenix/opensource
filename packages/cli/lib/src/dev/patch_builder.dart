// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_compiler/compiler.dart';

/// One rebuild of a patch: compile, then sign, each timed.
///
/// A failed build carries its [errors] and no [bytes] — the watch loop reports
/// them and keeps the previously-good bundle live, so a syntax error mid-edit
/// never takes the running app down.
class PatchBuild {
  PatchBuild.ok({
    required this.bytes,
    required this.bundleId,
    required this.functionCount,
    required this.compile,
    required this.sign,
  }) : errors = const [];

  PatchBuild.failed(this.errors, {required this.compile})
    : bytes = null,
      bundleId = null,
      functionCount = 0,
      sign = Duration.zero;

  /// The signed bundle, or `null` if the build failed.
  final Uint8List? bytes;
  final String? bundleId;
  final int functionCount;

  /// Time spent resolving and lowering to bytecode.
  final Duration compile;

  /// Time spent signing and encoding the bundle.
  final Duration sign;

  /// Compile errors; empty on success.
  final List<CompileDiagnostic> errors;

  bool get ok => errors.isEmpty && bytes != null;

  /// End-to-end build time — what the sub-500ms budget is spent on.
  Duration get total => compile + sign;
}

/// Compiles and signs a patch on demand, keeping the analyzer **warm**.
///
/// The warm context is the whole trick. A cold `Compiler.compileFile` re-resolves
/// the SDK and every dependency on each call — roughly a second for a real patch.
/// Holding one analysis context open and invalidating just the edited file drops
/// a rebuild to single-digit milliseconds, which is what leaves room in the
/// budget for watching, signing, and delivery (see `docs/benchmarks.md`).
class PatchBuilder {
  PatchBuilder({
    required this.sourcePath,
    required this.signer,
    required this.metadata,
    this.compilerVersion = '0.1.0',
    List<String>? roots,
  }) : _compiler = IncrementalCompiler(
         includedPaths: roots ?? [File(sourcePath).parent.absolute.path],
       );

  /// The patch entry point being watched.
  final String sourcePath;
  final Signer signer;
  final BundleMetadata metadata;
  final String compilerVersion;

  final IncrementalCompiler _compiler;

  /// Marks [path] as changed, so the next [rebuild] re-reads it.
  void invalidate(String path) => _compiler.invalidate(path);

  /// Compiles and signs. Never throws on a *user* error — a compile failure is a
  /// normal outcome in a watch loop, returned as a failed [PatchBuild].
  Future<PatchBuild> rebuild() async {
    final compileWatch = Stopwatch()..start();
    final result = await _compiler.compile(sourcePath);
    compileWatch.stop();

    if (result.hasErrors) {
      return PatchBuild.failed(
        result.errors.toList(),
        compile: compileWatch.elapsed,
      );
    }

    final signWatch = Stopwatch()..start();
    final bundle = Bundle.sign(
      module: result.moduleOrThrow,
      metadata: metadata,
      signer: signer,
      compilerVersion: compilerVersion,
    );
    final bytes = bundle.encode();
    signWatch.stop();

    return PatchBuild.ok(
      bytes: bytes,
      bundleId: _hex(bundle.bundleId),
      functionCount: result.moduleOrThrow.functions.length,
      compile: compileWatch.elapsed,
      sign: signWatch.elapsed,
    );
  }

  Future<void> dispose() => _compiler.dispose();
}

String _hex(Uint8List bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
