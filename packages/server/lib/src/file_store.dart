// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'model.dart';
import 'store.dart';

/// A filesystem-backed [Store] — the default persistent backend.
///
/// Layout under [root]:
///
/// ```text
///   apps/<id>.json          app records
///   blobs/<app>/<hex>.bundle bundle bytes (content is the blob interface)
///   refs/<app>.jsonl         one bundle ref per line
///   envs/<app>/<name>.json             default-channel environment pointers
///   envs/<app>/<channel>/<name>.json   named-channel environment pointers
/// ```
///
/// This is deliberately dependency-free (no native SQLite). The SQLite and
/// Postgres backends the brief mentions are additional [Store] implementations;
/// the API depends only on the interface.
class FileStore implements Store {
  FileStore(this.root) {
    for (final sub in ['apps', 'blobs', 'refs', 'envs']) {
      Directory('${root.path}/$sub').createSync(recursive: true);
    }
  }

  final Directory root;

  @override
  Future<App?> getApp(String id) async {
    final file = File('${root.path}/apps/$id.json');
    if (!file.existsSync()) return null;
    return App.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
    );
  }

  @override
  Future<List<App>> listApps() async {
    final dir = Directory('${root.path}/apps');
    return [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.json'))
          App.fromJson(
            jsonDecode(f.readAsStringSync()) as Map<String, Object?>,
          ),
    ];
  }

  @override
  Future<void> putApp(App app) async => File(
    '${root.path}/apps/${app.id}.json',
  ).writeAsStringSync(jsonEncode(app.toJson()));

  @override
  Future<void> putBundle(
    String appId,
    Uint8List bundleId,
    Uint8List bytes,
  ) async {
    final dir = Directory('${root.path}/blobs/$appId')
      ..createSync(recursive: true);
    File('${dir.path}/${_hex(bundleId)}.bundle').writeAsBytesSync(bytes);
  }

  @override
  Future<Uint8List?> getBundle(String appId, Uint8List bundleId) async {
    final file = File('${root.path}/blobs/$appId/${_hex(bundleId)}.bundle');
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  @override
  Future<void> putBundleRef(String appId, BundleRef ref) async {
    File(
      '${root.path}/refs/$appId.jsonl',
    ).writeAsStringSync('${jsonEncode(ref.toJson())}\n', mode: FileMode.append);
  }

  @override
  Future<List<BundleRef>> listBundleRefs(String appId) async {
    final file = File('${root.path}/refs/$appId.jsonl');
    if (!file.existsSync()) return const [];
    return [
      for (final line in file.readAsLinesSync())
        if (line.isNotEmpty)
          BundleRef.fromJson(jsonDecode(line) as Map<String, Object?>),
    ];
  }

  /// Where one environment record lives.
  ///
  /// The default channel keeps the pre-channel layout — `envs/<app>/<env>.json`
  /// — so a control plane that has been running keeps serving its data with no
  /// migration step. Named channels nest one level deeper. A channel directory
  /// and an environment file can never collide: one is `<name>/`, the other is
  /// `<name>.json`.
  String _envPath(String appId, String channel, String name) =>
      channel == defaultChannel
      ? '${root.path}/envs/$appId/$name.json'
      : '${root.path}/envs/$appId/$channel/$name.json';

  @override
  Future<Env?> getEnv(
    String appId,
    String name, {
    String channel = defaultChannel,
  }) async {
    final file = File(_envPath(appId, channel, name));
    if (!file.existsSync()) return null;
    return Env.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
    );
  }

  @override
  Future<List<Env>> listEnvs(String appId) async {
    final dir = Directory('${root.path}/envs/$appId');
    if (!dir.existsSync()) return const [];
    final out = <Env>[];
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      out.add(
        Env.fromJson(
          jsonDecode(entity.readAsStringSync()) as Map<String, Object?>,
        ),
      );
    }
    return out;
  }

  @override
  Future<void> putEnv(Env env) async {
    final file = File(_envPath(env.appId, env.channel, env.name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(env.toJson()));
  }

  @override
  Future<bool> isHealthy() async => root.existsSync();
}

String _hex(Uint8List b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
