// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_server/server.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ejenix_filestore'));
  tearDown(() => dir.deleteSync(recursive: true));

  Uint8List id(int v) => Uint8List(16)..fillRange(0, 16, v);

  App app(String id) => App(
    id: id,
    name: 'App $id',
    apiKeyHash: 'hash-$id',
    trustedKeys: [Uint8List(32)..fillRange(0, 32, 5)],
    createdAtMillis: 1720800000000,
  );

  test('apps round-trip and persist across reopen', () async {
    final store = FileStore(dir);
    await store.putApp(app('acme'));
    await store.putApp(app('globex'));

    final reopened = FileStore(dir);
    final loaded = await reopened.getApp('acme');
    expect(loaded, isNotNull);
    expect(loaded!.name, 'App acme');
    expect(loaded.trustedKeys.single, Uint8List(32)..fillRange(0, 32, 5));
    expect((await reopened.listApps()).length, 2);
    expect(await reopened.getApp('missing'), isNull);
  });

  test('bundle blobs round-trip', () async {
    final store = FileStore(dir);
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    await store.putBundle('acme', id(1), bytes);
    expect(await store.getBundle('acme', id(1)), bytes);
    expect(await store.getBundle('acme', id(2)), isNull);
  });

  test('bundle refs append and list', () async {
    final store = FileStore(dir);
    await store.putBundleRef(
      'acme',
      BundleRef(bundleId: id(1), sizeBytes: 100, uploadedAtMillis: 1),
    );
    await store.putBundleRef(
      'acme',
      BundleRef(bundleId: id(2), sizeBytes: 200, uploadedAtMillis: 2),
    );
    final refs = await FileStore(dir).listBundleRefs('acme');
    expect(refs.length, 2);
    expect(refs[1].bundleId, id(2));
    expect(refs[1].sizeBytes, 200);
    expect(await store.listBundleRefs('nobody'), isEmpty);
  });

  test('environments round-trip', () async {
    final store = FileStore(dir);
    await store.putEnv(Env(appId: 'acme', name: 'prod', activeBundleId: id(9)));
    await store.putEnv(Env(appId: 'acme', name: 'dev'));
    final reopened = FileStore(dir);
    expect((await reopened.getEnv('acme', 'prod'))!.activeBundleId, id(9));
    expect((await reopened.getEnv('acme', 'dev'))!.activeBundleId, isNull);
    expect((await reopened.listEnvs('acme')).length, 2);
    expect(await reopened.getEnv('acme', 'missing'), isNull);
    expect(await reopened.listEnvs('nobody'), isEmpty);
  });

  test('reports healthy when the directory exists', () async {
    expect(await FileStore(dir).isHealthy(), isTrue);
  });
}
