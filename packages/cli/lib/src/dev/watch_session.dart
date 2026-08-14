// Copyright (c) Ejenix authors. MIT license.

import 'dart:async';
import 'dart:io';

import 'patch_builder.dart';
import 'dev_server.dart';

/// The `ejenix watch` engine: watch → rebuild → publish.
///
/// Deliberately owns no CLI concerns — no argument parsing, no terminal, no
/// signal handling. That keeps the loop that actually matters testable without a
/// process to interrupt, and leaves [WatchCommand] a thin shell over it.
///
/// Reporting is a callback ([onBuild]) rather than printing: the command prints,
/// and a test asserts.
class WatchSession {
  WatchSession({
    required this.builder,
    required this.server,
    required this.roots,
    this.serve = true,
    this.outputPath,
    this.debounce = const Duration(milliseconds: 30),
    this.onBuild,
  });

  final PatchBuilder builder;
  final PatchDevServer server;

  /// Directories watched for `.dart` changes.
  final List<String> roots;

  final bool serve;

  /// If set, every good build is also written here.
  final String? outputPath;

  /// How long to coalesce filesystem events. One editor save is several events
  /// (write, attribute change, sometimes an atomic rename); rebuilding per event
  /// would be wasted work racing itself.
  final Duration debounce;

  /// Called after every build attempt, good or bad.
  final void Function(PatchBuild build)? onBuild;

  final List<StreamSubscription<FileSystemEvent>> _watches = [];
  Timer? _debounce;
  bool _building = false;
  bool _pending = false;

  /// Starts the server (if [serve]), performs the first build, and begins
  /// watching. Returns the first build so a caller can report it.
  Future<PatchBuild> start({int port = 8787, String host = '127.0.0.1'}) async {
    if (serve) {
      await server.start(
        port: port,
        address: host == '0.0.0.0' ? InternetAddress.anyIPv4 : host,
      );
    }

    final first = await _build();

    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      _watches.add(dir.watch(recursive: true).listen(_onEvent));
    }
    if (_watches.isEmpty) {
      throw StateError('nothing to watch: no such directory in $roots');
    }
    return first;
  }

  void _onEvent(FileSystemEvent event) {
    // Only Dart source triggers a rebuild. This also breaks the feedback loop:
    // `--output` writes a .bundle into a watched tree, and that must not
    // retrigger the build that produced it.
    if (!event.path.endsWith('.dart')) return;
    builder.invalidate(event.path);
    _debounce?.cancel();
    _debounce = Timer(debounce, rebuild);
  }

  /// Rebuilds now, coalescing a save that lands mid-build into one follow-up
  /// rebuild rather than a queue of them.
  Future<void> rebuild() async {
    if (_building) {
      _pending = true;
      return;
    }
    _building = true;
    try {
      do {
        _pending = false;
        builder.invalidate(builder.sourcePath);
        await _build();
      } while (_pending);
    } finally {
      _building = false;
    }
  }

  /// Builds and, if the build is good, publishes it. A compile error is reported
  /// but does **not** replace the live patch — the app keeps running the last
  /// good build while the developer fixes the typo.
  Future<PatchBuild> _build() async {
    final build = await builder.rebuild();
    if (build.ok) {
      if (serve) server.publish(build.bytes!, build.bundleId!);
      final output = outputPath;
      if (output != null) File(output).writeAsBytesSync(build.bytes!);
    }
    onBuild?.call(build);
    return build;
  }

  /// Stops watching and closes the server.
  ///
  /// Deliberately does **not** dispose [builder]: the session did not create it,
  /// so it does not own it. Whoever constructed the builder disposes it. (Doing
  /// otherwise means two owners racing to dispose one analyzer context, which
  /// hangs rather than failing cleanly.)
  Future<void> stop() async {
    _debounce?.cancel();
    for (final watch in _watches) {
      await watch.cancel();
    }
    _watches.clear();
    await server.close();
  }
}
