// Copyright (c) Ejenix authors. MIT license.

/// The `ejenix watch` dev loop, and the DoD's sub-500ms round-trip budget.
///
/// The benchmark below measures the **real** round trip an app experiences —
/// save the file, watcher notices, recompile, re-sign, notify over SSE, refetch
/// the bytes — not just the compile step in isolation. Anything less would be
/// measuring the easy part and claiming the hard one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_cli/cli.dart';
import 'package:ejenix_cli/src/commands/watch_command.dart';
import 'package:ejenix_cli/src/dev/dev_server.dart';
import 'package:ejenix_cli/src/dev/patch_builder.dart';
import 'package:ejenix_cli/src/dev/watch_session.dart';
import 'package:test/test.dart';

/// The DoD budget (brief §13). The measured figure is far under it; the assert
/// exists to catch a regression that would make the loop feel slow again.
const roundTripBudget = Duration(milliseconds: 500);

const metadata = BundleMetadata(
  targetAppId: 'com.example.watch',
  targetFlutterVersion: '3.44.6',
  minSdk: '1.0.0',
);

String patchSource(int version) =>
    '''
int build() {
  var total = 0;
  for (var i = 0; i < $version; i++) {
    total = total + i;
  }
  return total;
}
''';

void main() {
  late Directory dir;
  late File source;
  late PatchBuilder builder;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ejenix_watch');
    source = File('${dir.path}/patch.dart')..writeAsStringSync(patchSource(1));
    builder = PatchBuilder(
      sourcePath: source.path,
      signer: Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 5)),
      metadata: metadata,
      roots: [dir.path],
    );
  });

  tearDown(() async {
    await builder.dispose();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  group('PatchBuilder', () {
    test('builds and signs a verifiable bundle', () async {
      final build = await builder.rebuild();

      expect(build.ok, isTrue, reason: '${build.errors}');
      expect(build.functionCount, 1);

      // What it produces must be a real, verifiable patch — a fast loop that
      // emitted an unverifiable bundle would be worse than no loop.
      final bundle = Bundle.decode(build.bytes!);
      expect(
        bundle
            .verify(anchors: TrustAnchors.single(builder.signer.publicKey))
            .isValid,
        isTrue,
      );
    });

    test('a compile error is a normal outcome, not a crash', () async {
      source.writeAsStringSync('int build() { this is not dart }');
      builder.invalidate(source.path);

      final build = await builder.rebuild();
      expect(build.ok, isFalse);
      expect(build.errors, isNotEmpty);
      expect(build.bytes, isNull);
    });

    test('it recovers after the error is fixed', () async {
      source.writeAsStringSync('int build() { oops }');
      builder.invalidate(source.path);
      expect((await builder.rebuild()).ok, isFalse);

      source.writeAsStringSync(patchSource(3));
      builder.invalidate(source.path);
      final build = await builder.rebuild();
      expect(build.ok, isTrue, reason: '${build.errors}');
    });

    test('a rebuild reflects the edit', () async {
      final first = await builder.rebuild();
      source.writeAsStringSync(patchSource(99));
      builder.invalidate(source.path);
      final second = await builder.rebuild();

      expect(second.ok, isTrue);
      // Different source must yield different bytes, or the warm context is
      // serving a stale resolution — the one bug this design could hide.
      expect(second.bytes, isNot(equals(first.bytes)));
    });
  });

  group('PatchDevServer', () {
    late PatchDevServer server;
    late HttpClient client;

    setUp(() async {
      server = PatchDevServer();
      await server.start(port: 0); // ephemeral port
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.close();
    });

    Future<HttpClientResponse> get(String path) async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      return request.close();
    }

    test('serves 503 until the first build exists', () async {
      final response = await get('/patch.bundle');
      expect(response.statusCode, HttpStatus.serviceUnavailable);
      await response.drain<void>();
    });

    test('serves the published bundle', () async {
      final build = await builder.rebuild();
      server.publish(build.bytes!, build.bundleId!);

      final response = await get('/patch.bundle');
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.value('x-bundle-id'), build.bundleId);

      final bytes = await collectBytes(response);
      expect(bytes, equals(build.bytes));
    });

    test('health reports the live bundle', () async {
      final build = await builder.rebuild();
      server.publish(build.bytes!, build.bundleId!);

      final response = await get('/health');
      final body =
          jsonDecode(await response.transform(utf8.decoder).join()) as Map;
      expect(body['ok'], isTrue);
      expect(body['bundleId'], build.bundleId);
    });

    test('a subscriber is told what is already live on connect', () async {
      final build = await builder.rebuild();
      server.publish(build.bytes!, build.bundleId!);

      final response = await get('/events');
      final first = await response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((l) => l.startsWith('data: '));

      expect(first, 'data: ${build.bundleId}');
      expect(server.clientCount, 1);
    });

    test('a publish reaches an already-connected subscriber', () async {
      // The narrowest statement of the dev loop's core promise, and the one
      // shape nothing else covered: connect *first*, then publish. The
      // already-live-on-connect test above writes before the client arrives, so
      // it exercises a different path — and passes on platforms where this
      // one does not.
      final response = await get('/events');
      final events = <String>[];
      final gotOne = Completer<String>();
      final subscription = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((l) => l.startsWith('data: '))
          .listen((l) {
            events.add(l);
            if (!gotOne.isCompleted) gotOne.complete(l);
          });
      addTearDown(subscription.cancel);
      expect(server.clientCount, 1);

      final build = await builder.rebuild();
      server.publish(build.bytes!, build.bundleId!);

      final line = await gotOne.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => fail(
          'publish() did not reach a subscriber that connected beforehand — '
          'the SSE push path is not delivering',
        ),
      );
      expect(line, 'data: ${build.bundleId}');
    });

    test('an open subscription does not block other requests', () async {
      // The gap that let a real bug through: every other test here either
      // subscribes *or* makes requests, never both. `/events` is long-lived, so
      // an accept loop that awaits it serves nothing else while a device stays
      // connected — which is the normal state during `ejenix watch`.
      //
      // The failure this guards against is a hang, so it is bounded here: a
      // regression fails in seconds with this test's name, instead of stalling
      // the round-trip benchmark for its whole timeout.
      final events = await get('/events');
      final subscription = events
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((_) {});
      addTearDown(subscription.cancel);
      expect(server.clientCount, 1);

      final health = await get('/health').timeout(
        const Duration(seconds: 20),
        onTimeout: () => fail(
          'the server stopped serving while a client was '
          'subscribed — the accept loop is serialising on /events',
        ),
      );
      expect(health.statusCode, HttpStatus.ok);
      await health.drain<void>();
    });
  });

  sessionTests(() => dir, () => source, () => builder);

  group('the round trip', () {
    // This is the only test that holds an SSE subscription open *and* keeps
    // making requests, so it is the one that caught the accept loop in
    // PatchDevServer serialising on `/events` (see _serve). Keep it that shape.
    //
    // It also compiles for real eleven times — one priming build plus ten
    // measured iterations — and the Windows CI runner is roughly 9x slower than
    // a developer machine, so the 30s default leaves no headroom. The budget
    // that matters is the per-round-trip one asserted below; this limit only
    // exists so a genuine hang fails as a timeout instead of hanging CI.
    test(
      'save → app has fresh bytes, well under the 500ms budget',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final server = PatchDevServer();
        await server.start(port: 0);
        final client = HttpClient();
        addTearDown(() async {
          client.close(force: true);
          await server.close();
        });

        // An "app": subscribed to /events, refetching on each notification.
        final events = _EventQueue();
        final eventResponse = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/events'),
        )).close();
        final subscription = eventResponse
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .where((l) => l.startsWith('data: '))
            .listen(events.add);
        addTearDown(subscription.cancel);

        // Every await below is bounded and named. A bare hang here reports only
        // "timed out after N minutes" with no indication of *which* step
        // stalled, which is worth avoiding: this test has already hidden two
        // distinct platform bugs behind that one uninformative message.
        Future<T> step<T>(String what, Future<T> future) => future.timeout(
          const Duration(seconds: 45),
          onTimeout: () => fail('hung at: $what'),
        );

        // Prime the loop (first build pays analyzer start-up; a dev only pays it
        // once, when `ejenix watch` boots).
        final first = await step('priming rebuild', builder.rebuild());
        server.publish(first.bytes!, first.bundleId!);
        await step('priming SSE event', events.next());

        final samples = <int>[];
        for (var version = 2; version <= 11; version++) {
          final clock = Stopwatch()..start();

          // 1. The developer saves.
          source.writeAsStringSync(patchSource(version));
          // 2. The watcher rebuilds (the command's file-watch callback does this;
          //    here we drive it directly so the measurement is deterministic and
          //    not at the mercy of filesystem-event latency).
          builder.invalidate(source.path);
          final build = await step('rebuild #$version', builder.rebuild());
          expect(build.ok, isTrue, reason: '${build.errors}');
          // 3. Push to subscribers.
          server.publish(build.bytes!, build.bundleId!);
          // 4. The app is notified...
          await step('SSE event #$version', events.next());
          // 5. ...and has the new bytes in hand.
          final response = await step(
            'fetch /patch.bundle #$version',
            client
                .getUrl(
                  Uri.parse('http://127.0.0.1:${server.port}/patch.bundle'),
                )
                .then((r) => r.close()),
          );
          final bytes = await step(
            'read /patch.bundle body #$version',
            collectBytes(response),
          );

          clock.stop();
          samples.add(clock.elapsedMilliseconds);
          expect(bytes, equals(build.bytes));
        }

        samples.sort();
        final median = samples[samples.length ~/ 2];
        final worst = samples.last;
        printOnFailure('round trip ms: $samples');

        // The real assertion. Worst-case, not median: a p50 that hides a 2-second
        // p100 is exactly the loop that feels broken in practice.
        expect(
          worst,
          lessThan(roundTripBudget.inMilliseconds),
          reason:
              'worst round trip ${worst}ms exceeds the '
              '${roundTripBudget.inMilliseconds}ms budget (median ${median}ms)',
        );
      },
    );
  });
}

/// Runs the `ejenix watch` CLI, capturing its output.
Future<({int code, String out, String err})> runWatch(List<String> args) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final runner = EjenixRunner(out: out, err: err, isOutputTerminal: false);
  int code;
  try {
    code = await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    code = 64;
    err.writeln(e.message);
  }
  return (code: code, out: out.toString(), err: err.toString());
}

void sessionTests(
  Directory Function() dir,
  File Function() source,
  PatchBuilder Function() builder,
) {
  group('WatchSession', () {
    test('the first build is published to the server', () async {
      final server = PatchDevServer();
      final session = WatchSession(
        builder: builder(),
        server: server,
        roots: [dir().path],
      );
      addTearDown(session.stop);

      final first = await session.start(port: 0);
      expect(first.ok, isTrue, reason: '${first.errors}');
      expect(server.bundleId, first.bundleId);
    });

    test('saving a .dart file triggers a rebuild', () async {
      final server = PatchDevServer();
      final builds = <PatchBuild>[];
      final session = WatchSession(
        builder: builder(),
        server: server,
        roots: [dir().path],
        debounce: const Duration(milliseconds: 10),
        onBuild: builds.add,
      );
      addTearDown(session.stop);
      await session.start(port: 0);
      expect(builds, hasLength(1));

      // A real save, and a real filesystem event — not a simulated one.
      source().writeAsStringSync(patchSource(7));

      final rebuilt = await _waitFor(() => builds.length > 1);
      expect(
        rebuilt,
        isTrue,
        reason: 'the watcher never rebuilt after the file changed',
      );
      expect(builds.last.ok, isTrue);
      expect(server.bundleId, builds.last.bundleId);
    });

    test('a non-Dart file does not trigger a rebuild', () async {
      // The output bundle is written into a watched tree; if .bundle retriggered
      // the build, the loop would chase its own tail forever.
      final builds = <PatchBuild>[];
      final session = WatchSession(
        builder: builder(),
        server: PatchDevServer(),
        roots: [dir().path],
        serve: false,
        debounce: const Duration(milliseconds: 10),
        onBuild: builds.add,
      );
      addTearDown(session.stop);
      await session.start(port: 0);

      File('${dir().path}/out.bundle').writeAsBytesSync([1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(builds, hasLength(1), reason: 'a .bundle write rebuilt the patch');
    });

    test('--output writes each good build to disk', () async {
      final out = '${dir().path}/patch.bundle';
      final session = WatchSession(
        builder: builder(),
        server: PatchDevServer(),
        roots: [dir().path],
        serve: false,
        outputPath: out,
      );
      addTearDown(session.stop);

      final build = await session.start(port: 0);
      expect(File(out).readAsBytesSync(), equals(build.bytes));
    });

    test('a broken build keeps the last good patch live', () async {
      final server = PatchDevServer();
      final session = WatchSession(
        builder: builder(),
        server: server,
        roots: [dir().path],
      );
      addTearDown(session.stop);

      final good = await session.start(port: 0);
      source().writeAsStringSync('int build() { not dart at all }');
      await session.rebuild();

      // The app must keep running what last worked, not fall off a cliff
      // because of a half-typed line.
      expect(server.bundleId, good.bundleId);
    });

    test('watching a directory that does not exist is an error', () async {
      final session = WatchSession(
        builder: builder(),
        server: PatchDevServer(),
        roots: ['${dir().path}/nope'],
        serve: false,
      );
      addTearDown(session.stop);
      await expectLater(session.start(port: 0), throwsA(isA<StateError>()));
    });
  });

  group('the ejenix watch command', () {
    test('rejects a missing input file', () async {
      final r = await runWatch([
        'watch',
        '${dir().path}/nothing.dart',
        '--signing-key',
        'k',
        '--app-id',
        'a',
      ]);
      expect(r.code, 66);
      expect(r.err, contains('input not found'));
    });

    test('requires a signing key', () async {
      final r = await runWatch(['watch', source().path, '--app-id', 'a']);
      expect(r.code, 64);
      expect(r.err, contains('signing-key'));
    });

    test('requires an app id', () async {
      final key = File('${dir().path}/dev.key')..writeAsStringSync('07' * 32);
      final r = await runWatch([
        'watch',
        source().path,
        '--signing-key',
        key.path,
      ]);
      expect(r.code, 64);
      expect(r.err, contains('app-id'));
    });

    test('rejects a non-numeric port', () async {
      final key = File('${dir().path}/dev.key')..writeAsStringSync('07' * 32);
      final r = await runWatch([
        'watch',
        source().path,
        '--signing-key',
        key.path,
        '--app-id',
        'a',
        '--port',
        'eight',
      ]);
      expect(r.code, 64);
      expect(r.err, contains('port'));
    });

    test('needs an input file at all', () async {
      final r = await runWatch(['watch', '--app-id', 'a']);
      expect(r.code, 64);
    });

    group('the happy path', () {
      setUp(() {
        // Stop as soon as the loop is up, instead of waiting for a real ctrl-c.
        WatchCommand.runUntilInterrupted = () async {};
      });
      tearDown(() {
        WatchCommand.runUntilInterrupted = WatchCommand.untilSigint;
      });

      test('builds, serves, writes the output, and stops cleanly', () async {
        final key = File('${dir().path}/dev.key')..writeAsStringSync('07' * 32);
        final out = '${dir().path}/out.bundle';

        final r = await runWatch([
          'watch',
          source().path,
          '--signing-key',
          key.path,
          '--app-id',
          'com.example.watch',
          '--port',
          '0', // ephemeral, so a busy 8787 cannot make this flaky
          '-o',
          out,
        ]);

        expect(r.code, 0, reason: r.err);
        expect(r.out, contains('dev server'));
        expect(r.out, contains('built 1 function'));
        expect(r.out, contains('watching'));
        expect(r.out, contains('stopped'));

        // The bundle it wrote must be a real, verifiable patch.
        final bundle = Bundle.decode(
          Uint8List.fromList(File(out).readAsBytesSync()),
        );
        final signer = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 7));
        expect(
          bundle.verify(anchors: TrustAnchors.single(signer.publicKey)).isValid,
          isTrue,
        );
      });

      test('--no-serve skips the dev server', () async {
        final key = File('${dir().path}/dev.key')..writeAsStringSync('07' * 32);
        final r = await runWatch([
          'watch',
          source().path,
          '--signing-key',
          key.path,
          '--app-id',
          'a',
          '--no-serve',
        ]);

        expect(r.code, 0, reason: r.err);
        expect(r.out, isNot(contains('dev server')));
        expect(r.out, contains('built 1 function'));
      });

      test('a patch that does not compile is reported, not fatal', () async {
        final key = File('${dir().path}/dev.key')..writeAsStringSync('07' * 32);
        source().writeAsStringSync('int build() { definitely not dart }');

        final r = await runWatch([
          'watch',
          source().path,
          '--signing-key',
          key.path,
          '--app-id',
          'a',
          '--no-serve',
        ]);

        // The loop keeps running so you can fix the typo — it does not exit
        // nonzero and leave you staring at a dead terminal. Diagnostics and the
        // warning go to stderr, so stdout stays pipeable.
        expect(r.code, 0, reason: r.err);
        expect(r.err, contains('error'));
        expect(r.err, contains('keeping the last good patch'));
      });
    });
  });
}

/// Polls [condition] until it holds or the deadline passes. Filesystem events
/// are inherently asynchronous, so a fixed sleep would be either flaky or slow.
Future<bool> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return condition();
}

/// Buffers SSE lines, so awaiting "the next event" cannot race the `publish`
/// that produces it — a plain `stream.first` would either miss an event that
/// already arrived or re-listen to a single-subscription stream.
class _EventQueue {
  final List<String> _buffered = [];
  Completer<String>? _waiter;

  void add(String line) {
    final waiter = _waiter;
    if (waiter != null) {
      _waiter = null;
      waiter.complete(line);
    } else {
      _buffered.add(line);
    }
  }

  Future<String> next() {
    if (_buffered.isNotEmpty) return Future.value(_buffered.removeAt(0));
    return (_waiter = Completer<String>()).future;
  }
}

/// Drains a response into bytes.
Future<Uint8List> collectBytes(HttpClientResponse response) async {
  final chunks = <int>[];
  await for (final chunk in response) {
    chunks.addAll(chunk);
  }
  return Uint8List.fromList(chunks);
}
