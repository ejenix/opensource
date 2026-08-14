// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_loader/loader.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('quarantine', _quarantineTests);
  group('host reconcile', _hostReconcileTests);
  group('staging hygiene', _stagingHygieneTests);

  late Directory dir;
  setUp(() => dir = tempStoreDir());
  tearDown(() => dir.deleteSync(recursive: true));

  test('stage then activate makes a bundle active', () {
    final store = BundleStore(dir);
    final bundle = buildBundle(1, id: 1);
    store.writeStaging(bundle);
    expect(store.staged(bundle.bundleId), isNotNull);
    expect(store.activate(bundle.bundleId), isTrue);
    expect(store.activeId, bundle.bundleId);
    expect(store.activeBundle!.bundleId, bundle.bundleId);
  });

  test('activating cannot use a bundle that is not staged', () {
    final store = BundleStore(dir);
    expect(store.activate(Uint8List(16)), isFalse);
  });

  test('activation moves the previous active into history', () {
    final store = BundleStore(dir);
    for (final v in [1, 2, 3]) {
      final b = buildBundle(v, id: v);
      store.writeStaging(b);
      store.activate(b.bundleId);
    }
    expect(store.activeId![0], 3);
    // Two previous actives, most-recent first.
    expect(store.historyIds.length, 2);
  });

  test('history is LRU-capped', () {
    final store = BundleStore(dir, historyLimit: 2);
    for (var v = 1; v <= 5; v++) {
      final b = buildBundle(v, id: v);
      store.writeStaging(b);
      store.activate(b.bundleId);
    }
    expect(store.historyIds.length, 2);
    // Oldest evicted; the two most recent previous actives remain.
    expect(Directory('${dir.path}/history').listSync().length, 2);
  });

  test('rollback reverts to the previous active', () {
    final store = BundleStore(dir);
    final a = buildBundle(1, id: 1);
    final b = buildBundle(2, id: 2);
    store
      ..writeStaging(a)
      ..activate(a.bundleId);
    store
      ..writeStaging(b)
      ..activate(b.bundleId);
    expect(store.activeId![0], 2);
    expect(store.rollback(), isTrue);
    expect(store.activeId![0], 1);
    expect(store.isHealthy, isTrue); // reverted-to bundle is known good
  });

  test('rollback with empty history returns false', () {
    final store = BundleStore(dir);
    final a = buildBundle(1, id: 1);
    store
      ..writeStaging(a)
      ..activate(a.bundleId);
    expect(store.rollback(), isFalse);
  });

  group('crash-loop counter', () {
    test('trips after the threshold when unhealthy', () {
      final store = BundleStore(dir, crashThreshold: 3);
      final a = buildBundle(1, id: 1);
      final b = buildBundle(2, id: 2);
      store
        ..writeStaging(a)
        ..activate(a.bundleId);
      store.markHealthy();
      store
        ..writeStaging(b)
        ..activate(b.bundleId);

      expect(store.shouldAutoRollback(), isFalse);
      store.recordLaunch();
      store.recordLaunch();
      expect(store.shouldAutoRollback(), isFalse); // only 2
      store.recordLaunch();
      expect(store.shouldAutoRollback(), isTrue); // 3 >= threshold
    });

    test('markHealthy prevents rollback', () {
      final store = BundleStore(dir, crashThreshold: 2);
      final a = buildBundle(1, id: 1);
      final b = buildBundle(2, id: 2);
      store
        ..writeStaging(a)
        ..activate(a.bundleId);
      store.markHealthy();
      store
        ..writeStaging(b)
        ..activate(b.bundleId);
      store.recordLaunch();
      store.recordLaunch();
      expect(store.shouldAutoRollback(), isTrue);
      store.markHealthy();
      expect(store.shouldAutoRollback(), isFalse);
    });

    test('does not trip without a history to revert to', () {
      final store = BundleStore(dir, crashThreshold: 1);
      final a = buildBundle(1, id: 1);
      store
        ..writeStaging(a)
        ..activate(a.bundleId);
      store.recordLaunch();
      expect(store.shouldAutoRollback(), isFalse); // no history
    });
  });

  group('persistence', () {
    test('state survives reopening the store', () {
      final first = BundleStore(dir);
      final a = buildBundle(1, id: 1);
      final b = buildBundle(2, id: 2);
      first
        ..writeStaging(a)
        ..activate(a.bundleId);
      first
        ..writeStaging(b)
        ..activate(b.bundleId);
      first.recordLaunch();
      first.lastEtag = 'etag-123';

      final reopened = BundleStore(dir);
      expect(reopened.activeId![0], 2);
      expect(reopened.historyIds.length, 1);
      expect(reopened.launchesSinceActivation, 1);
      expect(reopened.lastEtag, 'etag-123');
    });

    test('self-heals when the active file is missing', () {
      final store = BundleStore(dir);
      final a = buildBundle(1, id: 1);
      store
        ..writeStaging(a)
        ..activate(a.bundleId);
      File('${dir.path}/active.bundle').deleteSync();

      final reopened = BundleStore(dir);
      expect(reopened.activeId, isNull);
    });
  });
}

/// A patch that verifies and stages cleanly but cannot run on this build — the
/// capability was released after the binary — must not be re-activated on the
/// next launch. The control plane keeps serving it (it is the promoted patch,
/// and the server cannot know this binary lacks the capability), so without a
/// record that survives a restart every cold start would re-activate it, fail
/// to render, and roll back again.
void _quarantineTests() {
  late Directory dir;
  setUp(() => dir = tempStoreDir());
  tearDown(() => dir.deleteSync(recursive: true));

  test('a quarantined bundle is remembered across a restart', () {
    final bundle = buildBundle(1, id: 7);

    final first = BundleStore(dir);
    expect(first.isQuarantined(bundle.bundleId), isFalse);
    first.quarantine(bundle.bundleId);
    expect(first.isQuarantined(bundle.bundleId), isTrue);

    // A cold start: a brand-new store over the same directory.
    final restarted = BundleStore(dir);
    expect(
      restarted.isQuarantined(bundle.bundleId),
      isTrue,
      reason: 'must survive a restart or the rollback is undone every launch',
    );
  });

  test('quarantine is per-bundle, not a blanket stop', () {
    final bad = buildBundle(1, id: 8);
    final good = buildBundle(2, id: 9);
    final store = BundleStore(dir)..quarantine(bad.bundleId);

    expect(store.isQuarantined(bad.bundleId), isTrue);
    expect(
      BundleStore(dir).isQuarantined(good.bundleId),
      isFalse,
      reason: 'a later good patch must still be applicable',
    );
  });

  test('quarantining twice is idempotent', () {
    final bundle = buildBundle(1, id: 10);
    final store = BundleStore(dir)
      ..quarantine(bundle.bundleId)
      ..quarantine(bundle.bundleId);
    expect(store.isQuarantined(bundle.bundleId), isTrue);
    expect(BundleStore(dir).isQuarantined(bundle.bundleId), isTrue);
  });

  test('quarantine survives alongside activation state', () {
    final active = buildBundle(1, id: 11);
    final bad = buildBundle(2, id: 12);

    final store = BundleStore(dir)..writeStaging(active);
    store
      ..activate(active.bundleId)
      ..quarantine(bad.bundleId);

    final restarted = BundleStore(dir);
    expect(restarted.activeId, active.bundleId);
    expect(restarted.isQuarantined(bad.bundleId), isTrue);
  });
}

/// Quarantine is a property of (bundle, binary) but is keyed on bundle alone.
/// A bundle id is baked in at signing, so shipping the build that registers the
/// missing capability leaves the id unchanged — without reconciling against the
/// host, every device that quarantined it would stay pinned to an older patch
/// forever, on a binary that can now run the new one.
void _hostReconcileTests() {
  late Directory dir;
  setUp(() => dir = tempStoreDir());
  tearDown(() => dir.deleteSync(recursive: true));

  test('an unchanged host keeps the quarantine', () {
    final bad = buildBundle(1, id: 20);
    BundleStore(dir)
      ..reconcileHost('caps-v1')
      ..quarantine(bad.bundleId);

    final restarted = BundleStore(dir)..reconcileHost('caps-v1');
    expect(restarted.isQuarantined(bad.bundleId), isTrue);
  });

  test(
    'a changed host clears it, so shipping the fix un-sticks the device',
    () {
      final bad = buildBundle(1, id: 21);
      BundleStore(dir)
        ..reconcileHost('caps-v1')
        ..quarantine(bad.bundleId);

      // The release that registers the missing capability.
      final upgraded = BundleStore(dir)..reconcileHost('caps-v2');
      expect(
        upgraded.isQuarantined(bad.bundleId),
        isFalse,
        reason: 'the same patch must be retried on a binary that can run it',
      );
      expect(BundleStore(dir).isQuarantined(bad.bundleId), isFalse);
    },
  );

  test('reconciling does not disturb activation state', () {
    final active = buildBundle(1, id: 22);
    final store = BundleStore(dir)..writeStaging(active);
    store
      ..activate(active.bundleId)
      ..reconcileHost('caps-v1');

    final upgraded = BundleStore(dir)..reconcileHost('caps-v2');
    expect(upgraded.activeId, active.bundleId);
  });
}

void _stagingHygieneTests() {
  late Directory dir;
  setUp(() => dir = tempStoreDir());
  tearDown(() => dir.deleteSync(recursive: true));

  test('a refused staged bundle can be discarded', () {
    // A bundle that verified and staged but was refused activation — already
    // live, or quarantined — otherwise sits in staging forever. Nothing GCs it,
    // and every check adds another copy.
    final b = buildBundle(1, id: 30);
    final store = BundleStore(dir)..writeStaging(b);
    expect(store.staged(b.bundleId), isNotNull);

    store.discardStaging(b.bundleId);
    expect(store.staged(b.bundleId), isNull);
  });

  test('discarding one that is not staged is harmless', () {
    final b = buildBundle(1, id: 31);
    expect(() => BundleStore(dir).discardStaging(b.bundleId), returnsNormally);
  });

  test('discarding staging does not disturb the active bundle', () {
    final active = buildBundle(1, id: 32);
    final other = buildBundle(2, id: 33);
    final store = BundleStore(dir)..writeStaging(active);
    store
      ..activate(active.bundleId)
      ..writeStaging(other)
      ..discardStaging(other.bundleId);

    expect(store.activeId, active.bundleId);
    expect(store.activeBundle, isNotNull);
  });
}
