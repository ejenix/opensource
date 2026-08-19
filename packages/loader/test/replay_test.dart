// Copyright (c) Ejenix authors. MIT license.

/// A signature proves a release was authored by the key holder. It says
/// nothing about whether it is the *current* one.
///
/// Without a freshness rule, a compromised — or merely stale — control plane
/// can re-serve an old, validly signed bundle. Every cryptographic check
/// passes, because the signature is genuine, and whatever that release
/// contained comes back: a fixed bug, a withdrawn feature, a patch that was
/// pulled for a reason.
///
/// The device therefore records the highest generation it has accepted and
/// refuses anything below it.
library;

import 'dart:io';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_loader/loader.dart';
import 'package:test/test.dart';

import 'support.dart';

BundleMetadata _gen(int generation) => BundleMetadata(
  targetAppId: 'com.example.app',
  targetFlutterVersion: '3.41.6',
  minSdk: '1.0.0',
  releaseGeneration: generation,
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ejenix_replay'));
  tearDown(() => dir.deleteSync(recursive: true));

  Loader loaderFor(BundleStore store, Bundle bundle) => Loader(
    store: store,
    fetcher: FakeFetcher((_, __) async => FetchSuccess(bundle.encode(), null)),
    anchors: testAnchors,
    host: testHost,
  );

  final url = Uri.parse('https://example.test/b.bundle');

  test('a newer generation is accepted and advances the mark', () async {
    final store = BundleStore(dir);
    expect(store.acceptedGeneration, 0);

    final r = await loaderFor(
      store,
      buildBundle(1, id: 1, metadata: _gen(5)),
    ).checkForUpdate(url);

    expect(r, isA<Staged>());
    expect(store.acceptedGeneration, 5);
  });

  test('an older generation is refused as stale', () async {
    // The replay itself: the bundle is genuinely signed, and that is exactly
    // why nothing else would have stopped it.
    final store = BundleStore(dir);
    await loaderFor(
      store,
      buildBundle(1, id: 1, metadata: _gen(7)),
    ).checkForUpdate(url);

    final replayed = await loaderFor(
      store,
      buildBundle(2, id: 2, metadata: _gen(3)),
    ).checkForUpdate(url);

    expect(replayed, isA<Rejected>());
    expect((replayed as Rejected).reason, contains('stale release'));
    expect(store.acceptedGeneration, 7, reason: 'the mark must not go back');
  });

  test('the same generation is still accepted', () async {
    // Re-publishing one release must keep working — the rule is "never
    // backwards", not "always strictly forwards".
    final store = BundleStore(dir);
    await loaderFor(
      store,
      buildBundle(1, id: 1, metadata: _gen(4)),
    ).checkForUpdate(url);

    final again = await loaderFor(
      store,
      buildBundle(1, id: 3, metadata: _gen(4)),
    ).checkForUpdate(url);
    expect(again, isA<Staged>());
  });

  test('the mark survives a restart', () async {
    // Held only in memory, the rule would reset on every launch and a replay
    // would land on the next cold start.
    final store = BundleStore(dir);
    await loaderFor(
      store,
      buildBundle(1, id: 1, metadata: _gen(9)),
    ).checkForUpdate(url);

    expect(BundleStore(dir).acceptedGeneration, 9);

    final replayed = await loaderFor(
      BundleStore(dir),
      buildBundle(2, id: 2, metadata: _gen(2)),
    ).checkForUpdate(url);
    expect(replayed, isA<Rejected>());
  });

  test('bundles without a generation are unaffected', () async {
    // Everything published before this field existed carries 0. Enforcing an
    // order on them would have made every existing bundle unacceptable the day
    // this shipped.
    final store = BundleStore(dir);
    await loaderFor(
      store,
      buildBundle(1, id: 1, metadata: _gen(6)),
    ).checkForUpdate(url);

    final legacy = await loaderFor(
      store,
      buildBundle(2, id: 2, metadata: testMetadata),
    ).checkForUpdate(url);
    expect(legacy, isA<Staged>(), reason: 'generation 0 claims no ordering');
  });
}
