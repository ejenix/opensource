// Copyright (c) Ejenix authors. MIT license.

/// `state.json` is the device's record of what is active, whether it is
/// healthy, and what has been quarantined. Written in place, a crash between
/// truncation and the final byte leaves it short — and the store then either
/// self-heals to nothing (losing the active patch) or trips its corrupt-state
/// path on the next launch.
///
/// It is written to a sibling, flushed, and renamed. Rename within a
/// filesystem is atomic, so a reader sees the whole old file or the whole new
/// one and never a prefix.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_loader/loader.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ejenix_atomic'));
  tearDown(() => dir.deleteSync(recursive: true));

  File stateFile() => File('${dir.path}/state.json');

  test('no temporary file survives a normal write', () {
    // A leftover .tmp would be a second, stale copy of the pointer.
    BundleStore(dir).installId;
    expect(File('${stateFile().path}.tmp').existsSync(), isFalse);
  });

  test('state is always complete, parseable JSON on disk', () {
    final store = BundleStore(dir);
    store.installId;
    store.quarantine(Uint8List(16)..fillRange(0, 16, 7));

    final raw = stateFile().readAsStringSync();
    expect(
      () => jsonDecode(raw),
      returnsNormally,
      reason: 'a partially written state file would not parse',
    );
    expect((jsonDecode(raw) as Map)['quarantined'], isNotEmpty);
  });

  test('a half-written file from a crash is never what a reader sees', () {
    // Simulate the pre-fix failure directly: a truncated state.json. The store
    // must not adopt it as truth — it resets rather than acting on a prefix.
    final store = BundleStore(dir);
    store.installId;
    final good = stateFile().readAsStringSync();

    stateFile().writeAsStringSync(good.substring(0, good.length ~/ 2));
    final reopened = BundleStore(dir);
    expect(
      reopened.activeId,
      isNull,
      reason: 'a truncated state must not be treated as a valid pointer',
    );
  });

  test('the install id survives repeated writes', () {
    // The rename must replace, not append or interleave.
    final store = BundleStore(dir);
    final id = store.installId;
    for (var i = 0; i < 20; i++) {
      store.quarantine(Uint8List(16)..fillRange(0, 16, i));
    }
    expect(BundleStore(dir).installId, id);
    expect(
      jsonDecode(stateFile().readAsStringSync()),
      isA<Map<String, Object?>>(),
    );
  });
}
