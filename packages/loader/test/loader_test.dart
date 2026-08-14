// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_delta/delta.dart';
import 'package:ejenix_loader/loader.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory dir;
  final url = Uri.parse('https://control.example/app/bundle');

  setUp(() => dir = tempStoreDir());
  tearDown(() => dir.deleteSync(recursive: true));

  Loader loaderWith(FetchResult response, {HostEnvironment host = testHost}) {
    return Loader(
      store: BundleStore(dir),
      fetcher: FakeFetcher((_, __) async => response),
      anchors: testAnchors,
      host: host,
    );
  }

  test('not-modified yields up-to-date', () async {
    final loader = loaderWith(const FetchNotModified());
    expect(await loader.checkForUpdate(url), isA<UpToDate>());
  });

  test('fetch failure is surfaced', () async {
    final loader = loaderWith(const FetchFailure('offline'));
    final outcome = await loader.checkForUpdate(url);
    expect(outcome, isA<FetchError>());
    expect((outcome as FetchError).reason, 'offline');
  });

  test('a valid bundle is staged and can be activated', () async {
    final bundle = buildBundle(1, id: 1);
    final loader = loaderWith(FetchSuccess(bundle.encode(), 'etag-1'));
    final outcome = await loader.checkForUpdate(url);
    expect(outcome, isA<Staged>());
    expect(loader.store.staged(bundle.bundleId), isNotNull);
    expect(loader.store.lastEtag, 'etag-1');
    expect(loader.activate((outcome as Staged).bundleId), isTrue);
    expect(loader.store.activeId, bundle.bundleId);
  });

  test('malformed bytes are rejected', () async {
    final loader = loaderWith(
      FetchSuccess(Uint8List.fromList([0, 1, 2]), null),
    );
    final outcome = await loader.checkForUpdate(url);
    expect(outcome, isA<Rejected>());
    expect((outcome as Rejected).reason, contains('malformed'));
  });

  test('a bundle from an untrusted key is rejected', () async {
    final foreign = Signer.generate();
    final bundle = buildBundle(1, id: 1, signer: foreign);
    final loader = loaderWith(FetchSuccess(bundle.encode(), null));
    final outcome = await loader.checkForUpdate(url);
    expect(outcome, isA<Rejected>());
    expect((outcome as Rejected).reason, contains('untrustedKey'));
  });

  test('a bundle for the wrong app is rejected', () async {
    final bundle = buildBundle(
      1,
      id: 1,
      metadata: const BundleMetadata(
        targetAppId: 'com.other.app',
        targetFlutterVersion: '3.41.6',
        minSdk: '1.0.0',
      ),
    );
    final loader = loaderWith(FetchSuccess(bundle.encode(), null));
    final outcome = await loader.checkForUpdate(url);
    expect(outcome, isA<Rejected>());
    expect((outcome as Rejected).reason, contains('incompatible'));
  });

  test('the cached etag is sent on the next fetch', () async {
    final bundle = buildBundle(1, id: 1);
    var seenEtag = 'unset';
    final fetcher = FakeFetcher((_, etag) async {
      seenEtag = etag ?? 'none';
      return FetchSuccess(bundle.encode(), 'etag-xyz');
    });
    final loader = Loader(
      store: BundleStore(dir),
      fetcher: fetcher,
      anchors: testAnchors,
      host: testHost,
    );
    await loader.checkForUpdate(url); // stores etag-xyz
    await loader.checkForUpdate(url); // should send it back
    expect(seenEtag, 'etag-xyz');
  });

  group('deltas', () {
    test('a delta is applied against the active base and staged', () async {
      final base = buildBundle(1, id: 1);
      final target = buildBundle(2, id: 2);
      final store = BundleStore(dir);
      store
        ..writeStaging(base)
        ..activate(base.bundleId);

      final delta = DeltaBundle.create(
        base: base,
        target: target,
        signer: testSigner,
        compilerVersion: '0.1.0',
        bundleId: Uint8List(16)..fillRange(0, 16, 7),
      );
      final loader = Loader(
        store: store,
        fetcher: FakeFetcher(
          (_, __) async => FetchSuccess(delta.encode(), null),
        ),
        anchors: testAnchors,
        host: testHost,
      );
      final outcome = await loader.checkForUpdate(url);
      expect(outcome, isA<Staged>());
      expect((outcome as Staged).bundleId, target.bundleId);
      expect(loader.activate(target.bundleId), isTrue);
      expect(loader.store.activeId, target.bundleId);
    });

    test('a delta with no active base is rejected', () async {
      final base = buildBundle(1, id: 1);
      final target = buildBundle(2, id: 2);
      final delta = DeltaBundle.create(
        base: base,
        target: target,
        signer: testSigner,
        compilerVersion: '0.1.0',
      );
      final loader = loaderWith(FetchSuccess(delta.encode(), null));
      final outcome = await loader.checkForUpdate(url);
      expect(outcome, isA<Rejected>());
      expect((outcome as Rejected).reason, contains('no base'));
    });
  });

  group('crash-loop rollback', () {
    test('guardStartup reverts a crash-looping activation', () {
      final store = BundleStore(dir, crashThreshold: 2);
      final base = buildBundle(1, id: 1);
      final bad = buildBundle(2, id: 2);
      final loader = Loader(
        store: store,
        fetcher: FakeFetcher((_, __) async => const FetchNotModified()),
        anchors: testAnchors,
        host: testHost,
      );
      store
        ..writeStaging(base)
        ..activate(base.bundleId);
      store.markHealthy();
      store
        ..writeStaging(bad)
        ..activate(bad.bundleId);

      // Two launches with no markHealthy: the second guard trips a rollback.
      expect(loader.guardStartup(), isFalse);
      expect(loader.guardStartup(), isTrue);
      expect(store.activeId, base.bundleId);
    });

    test('a healthy run is never rolled back', () {
      final store = BundleStore(dir, crashThreshold: 2);
      final base = buildBundle(1, id: 1);
      final good = buildBundle(2, id: 2);
      final loader = Loader(
        store: store,
        fetcher: FakeFetcher((_, __) async => const FetchNotModified()),
        anchors: testAnchors,
        host: testHost,
      );
      store
        ..writeStaging(base)
        ..activate(base.bundleId);
      store.markHealthy();
      store
        ..writeStaging(good)
        ..activate(good.bundleId);
      loader.guardStartup();
      loader.markHealthy();
      expect(loader.guardStartup(), isFalse);
      expect(store.activeId, good.bundleId);
    });
  });
}
