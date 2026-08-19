// Copyright (c) Ejenix authors. MIT license.

/// Staged rollout is decided on the device, by hashing a local install id with
/// a salt the control plane publishes. The server never learns which installs
/// took a bundle, so a percentage rollout costs no device registry and gives
/// the control plane no way to target one install.
///
/// Three properties make it safe, and each is pinned below: the answer is
/// stable for an install, widening only ever admits more devices, and the
/// spread across installs is close to the requested share.
library;

import 'dart:io';

import 'package:ejenix_loader/loader.dart';
import 'package:test/test.dart';

/// A plausible install id — the store writes 16 random bytes as hex.
String _install(int n) => n.toRadixString(16).padLeft(32, '0');

void main() {
  group('bucketing', () {
    test('100 percent takes everyone, 0 percent takes no one', () {
      for (var i = 0; i < 200; i++) {
        expect(
          isInRollout(installId: _install(i), salt: 's', percent: 100),
          isTrue,
        );
        expect(
          isInRollout(installId: _install(i), salt: 's', percent: 0),
          isFalse,
        );
      }
    });

    test('the same install always gets the same answer', () {
      // If this drifted, a device would flip in and out of a canary between
      // launches — the patch appearing and vanishing with no explanation.
      for (var i = 0; i < 50; i++) {
        final first = isInRollout(
          installId: _install(i),
          salt: 'abc',
          percent: 37,
        );
        for (var repeat = 0; repeat < 5; repeat++) {
          expect(
            isInRollout(installId: _install(i), salt: 'abc', percent: 37),
            first,
          );
        }
      }
    });

    test('widening is additive — nobody loses a patch they had', () {
      // The property that makes staged rollout safe to operate. Raising the
      // percentage must never drop an install that already took the bundle.
      const salt = 'fixed-for-this-promotion';
      final admitted = <int, int>{};
      for (var i = 0; i < 500; i++) {
        for (final pct in [5, 25, 50, 90]) {
          if (isInRollout(installId: _install(i), salt: salt, percent: pct)) {
            admitted[i] ??= pct;
          }
        }
      }
      // Anyone admitted at a low percentage must still be admitted at a higher
      // one.
      for (final entry in admitted.entries) {
        for (final pct in [5, 25, 50, 90]) {
          if (pct >= entry.value) {
            expect(
              isInRollout(
                installId: _install(entry.key),
                salt: salt,
                percent: pct,
              ),
              isTrue,
              reason:
                  'install ${entry.key} admitted at ${entry.value}% '
                  'was dropped at $pct%',
            );
          }
        }
      }
    });

    test('the share is roughly the requested percentage', () {
      // Not a statistical proof — a sanity check that the hash spreads. A
      // badly distributed bucket would silently ship a "5%" canary to half the
      // fleet, or to nobody.
      for (final pct in [5, 25, 50]) {
        var hits = 0;
        const n = 4000;
        for (var i = 0; i < n; i++) {
          if (isInRollout(installId: _install(i), salt: 'salt', percent: pct)) {
            hits++;
          }
        }
        final actual = hits * 100 / n;
        expect(
          (actual - pct).abs(),
          lessThan(5),
          reason: 'asked for $pct%, got ${actual.toStringAsFixed(1)}%',
        );
      }
    });

    test('a different salt selects a different slice', () {
      // Otherwise the same unlucky installs would receive every canary.
      var same = 0;
      for (var i = 0; i < 500; i++) {
        final a = isInRollout(installId: _install(i), salt: 'a', percent: 50);
        final b = isInRollout(installId: _install(i), salt: 'b', percent: 50);
        if (a == b) same++;
      }
      expect(same, lessThan(450), reason: 'salts should reshuffle the slice');
    });

    test('an install with no id is treated as outside', () {
      // A device that cannot be bucketed consistently must not receive a
      // canary — it could take it on one launch and lose it on the next.
      expect(isInRollout(installId: '', salt: 's', percent: 50), isFalse);
      expect(
        isInRollout(installId: '', salt: 's', percent: 100),
        isTrue,
        reason: 'a full rollout still reaches everyone',
      );
    });
  });

  group('install id', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ejenix_install'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('is generated once and survives a restart', () {
      final first = BundleStore(dir).installId;
      expect(first, hasLength(32));
      expect(
        BundleStore(dir).installId,
        first,
        reason: 'a new id each launch would reshuffle the rollout',
      );
    });

    test('differs between installs', () {
      final other = Directory.systemTemp.createTempSync('ejenix_install2');
      addTearDown(() => other.deleteSync(recursive: true));
      expect(BundleStore(dir).installId, isNot(BundleStore(other).installId));
    });
  });
}
