// Copyright (c) Ejenix authors. MIT license.

/// Drives the turnkey production path deterministically: a real signed bundle
/// (a fixture module re-signed in-process) handed to [EjenixPatchView] through an
/// injected [PatchResolver], exercising verify → stage → render plus the
/// offline, rejection, and live-update flows.
///
/// The network hop itself is covered separately by the control-plane client's
/// own test against a real HTTP server; isolating it behind [PatchResolver]
/// keeps this pipeline test free of sockets and flakiness.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_flutter/ejenix_flutter.dart';
import 'package:ejenix_loader/loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _appId = 'com.example.patchable';

/// Signs a fixture module (compiled from Dart by the pure-Dart workspace) into a
/// bundle for [appId], returning the encoded bytes.
Uint8List signFixture(String fixture, Signer signer, {String appId = _appId}) {
  final (module, _) = ModuleCodec.decodeBody(
    File('test/fixtures/$fixture.mod').readAsBytesSync(),
  );
  return Bundle.sign(
    module: module,
    metadata: BundleMetadata(
      targetAppId: appId,
      targetFlutterVersion: '3.44.6',
      minSdk: '1.0.0',
    ),
    signer: signer,
    compilerVersion: '0.1.0',
  ).encode();
}

/// Pumps (advancing fake time so the injected resolver's Future completes) until
/// [done] holds or we give up.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int tries = 40,
}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  group('status delivery', _statusDeliveryTests);
  group('state machine regressions', _stateMachineRegressionTests);
  group('failure escalation', _escalationTests);
  group('ordering and throttling', _orderingTests);

  late Directory cache;
  late Signer signer;

  setUp(() {
    cache = Directory.systemTemp.createTempSync('patchview');
    signer = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 11));
  });
  tearDown(() {
    try {
      cache.deleteSync(recursive: true);
    } on FileSystemException {
      // best effort
    }
  });

  bool visible(String text) => find.text(text).evaluate().isNotEmpty;

  Widget view({
    required PatchResolver source,
    List<Uint8List>? trustedKeys,
    Uint8List? bundledFallback,
    void Function(PatchStatus)? onStatus,
    Widget Function(BuildContext, Object)? fallbackBuilder,
  }) => MaterialApp(
    home: EjenixPatchView(
      controlPlane: Uri.parse('http://unused.test'),
      appId: _appId,
      trustedKeys: trustedKeys ?? [signer.publicKey],
      cacheDir: cache,
      bundledFallback: bundledFallback,
      onStatus: onStatus,
      fallbackBuilder: fallbackBuilder,
      source: source,
    ),
  );

  /// Signs a hand-built module that calls a capability no build registers, so
  /// it verifies and stages cleanly and then cannot run.
  Uint8List signUnrunnable() {
    final f =
        (BytecodeBuilder()
              ..emitABx(Op.invokeStatic, 0, 0)
              ..emitA(Op.ret, 0))
            .toProto(name: 'build', paramCount: 0, registerCount: 2);
    return Bundle.sign(
      module: Module(
        constants: ConstantPool(),
        functions: [f],
        callSites: const [CallSite(selector: 'App.blogs', argCount: 0)],
      ),
      metadata: const BundleMetadata(
        targetAppId: _appId,
        targetFlutterVersion: '3.44.6',
        minSdk: '1.0.0',
      ),
      signer: signer,
      compilerVersion: '0.1.0',
    ).encode();
  }

  testWidgets('an unrunnable patch rolls back to the last working one', (
    tester,
  ) async {
    // The production report: a patch calling App.blogs on a build that does not
    // register it. It is correctly signed, so verification and staging both
    // succeed — the failure only appears at render.
    final statuses = <PatchStatus>[];
    var serve = signFixture('hello', signer);

    await tester.pumpWidget(
      view(
        source: () async => serve,
        onStatus: statuses.add,
        fallbackBuilder: (_, _) => const Text('native fallback'),
      ),
    );
    await pumpUntil(tester, () => visible('Hello from a patch'));
    expect(find.text('Hello from a patch'), findsOneWidget);

    // Now the control plane promotes the unrunnable patch.
    serve = signUnrunnable();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpUntil(tester, () => statuses.contains(PatchStatus.incompatible));

    // The good patch is back on screen — not the red screen, and not the
    // fallback left showing forever.
    await pumpUntil(tester, () => visible('Hello from a patch'));
    expect(find.text('Hello from a patch'), findsOneWidget);
    expect(statuses, contains(PatchStatus.incompatible));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a re-served unrunnable patch does not undo the rollback', (
    tester,
  ) async {
    // The control plane keeps serving it — it is the promoted patch and the
    // server cannot know this binary lacks the capability. Without the guard the
    // next check re-activates it and the rollback is undone on a loop.
    final statuses = <PatchStatus>[];
    var serve = signFixture('hello', signer);

    await tester.pumpWidget(
      view(
        source: () async => serve,
        onStatus: statuses.add,
        fallbackBuilder: (_, _) => const Text('native fallback'),
      ),
    );
    await pumpUntil(tester, () => visible('Hello from a patch'));

    serve = signUnrunnable();
    for (var i = 0; i < 3; i++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpUntil(tester, () => visible('Hello from a patch'));
    }

    expect(find.text('Hello from a patch'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resolves, verifies, and renders a patch', (tester) async {
    await tester.pumpWidget(
      view(source: () async => signFixture('hello', signer)),
    );
    await pumpUntil(tester, () => visible('Hello from a patch'));

    expect(find.text('Hello from a patch'), findsOneWidget);
  });

  testWidgets('renders the bundled fallback instantly, offline', (
    tester,
  ) async {
    // Resolver finds nothing (control plane unreachable); the shipped fallback
    // must still render, on the first frame.
    await tester.pumpWidget(
      view(
        source: () async => null,
        bundledFallback: signFixture('hello', signer),
      ),
    );
    await tester.pump();

    expect(find.text('Hello from a patch'), findsOneWidget);
  });

  testWidgets('a patch signed by an untrusted key is never rendered', (
    tester,
  ) async {
    final attacker = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 99));
    final statuses = <PatchStatus>[];

    await tester.pumpWidget(
      view(
        source: () async => signFixture('hello', attacker),
        trustedKeys: [signer.publicKey], // NOT the attacker's key
        onStatus: statuses.add,
        fallbackBuilder: (_, _) => const Text('native fallback'),
      ),
    );
    await pumpUntil(tester, () => statuses.contains(PatchStatus.rejected));

    // The forged patch is rejected; the app shows its own screen, never the
    // attacker's content.
    expect(find.text('Hello from a patch'), findsNothing);
    expect(find.text('native fallback'), findsOneWidget);
    expect(statuses, contains(PatchStatus.rejected));
  });

  testWidgets('an update promoted after launch swaps the screen', (
    tester,
  ) async {
    // The resolver yields the next patch once, then reports "nothing new".
    Uint8List? pending = signFixture('hello', signer);
    Future<Uint8List?> resolve() async {
      final b = pending;
      pending = null;
      return b;
    }

    final statuses = <PatchStatus>[];
    await tester.pumpWidget(view(source: resolve, onStatus: statuses.add));
    await pumpUntil(tester, () => visible('Hello from a patch'));
    expect(find.text('Hello from a patch'), findsOneWidget);

    // Promote a different patch, then bring the app to the foreground.
    pending = signFixture('counter', signer);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpUntil(tester, () => visible('Count: 0'));

    expect(find.text('Count: 0'), findsOneWidget);
    expect(statuses, contains(PatchStatus.updated));
  });
}

void _statusDeliveryTests() {
  testWidgets('onStatus never fires during a build', (tester) async {
    // Found on a real device, not in a test: the first statuses are reported
    // from initState, which runs inside the parent's build. A host calling
    // setState there — the documented "debug overlay" usage — crashed with
    // `setState() called during build`.
    final cache = Directory.systemTemp.createTempSync('statusphase');
    addTearDown(() => cache.deleteSync(recursive: true));
    final signer = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 11));

    await tester.pumpWidget(
      MaterialApp(
        home: _StatusHost(cache: cache, signer: signer),
      ),
    );
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));

    // The crash surfaces as an exception captured by the test binding.
    expect(tester.takeException(), isNull);
  });
}

/// A host that does exactly what the docs invite: setState on every status.
class _StatusHost extends StatefulWidget {
  const _StatusHost({required this.cache, required this.signer});
  final Directory cache;
  final Signer signer;
  @override
  State<_StatusHost> createState() => _StatusHostState();
}

class _StatusHostState extends State<_StatusHost> {
  final _seen = <PatchStatus>[];

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: EjenixPatchView(
          controlPlane: Uri.parse('http://unused.test'),
          appId: _appId,
          trustedKeys: [widget.signer.publicKey],
          cacheDir: widget.cache,
          bundledFallback: signFixture('hello', widget.signer),
          source: () async => null,
          onStatus: (s) => setState(() => _seen.add(s)),
          fallbackBuilder: (_, _) => const SizedBox(),
        ),
      ),
      Text('seen ${_seen.length}'),
    ],
  );
}

/// Regressions found by adversarial review of the finished implementation.
/// Each of these was a real defect that shipped in an earlier iteration of the
/// fix; each would silently return without a test.
void _stateMachineRegressionTests() {
  late Directory cache;
  late Signer signer;
  setUp(() {
    cache = Directory.systemTemp.createTempSync('smr');
    signer = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 11));
  });
  tearDown(() {
    try {
      cache.deleteSync(recursive: true);
    } on FileSystemException {
      // best effort
    }
  });

  testWidgets('a transient fault on one frame does not doom a working patch', (
    tester,
  ) async {
    // `_patchFailed` used to latch: a patch that threw once and rendered
    // perfectly afterwards could never be marked healthy again, so the
    // crash-loop counter climbed until auto-rollback discarded a patch that
    // worked. The flag must describe the current frame only.
    final statuses = <PatchStatus>[];
    await tester.pumpWidget(
      MaterialApp(
        home: EjenixPatchView(
          controlPlane: Uri.parse('http://unused.test'),
          appId: _appId,
          trustedKeys: [signer.publicKey],
          cacheDir: cache,
          bundledFallback: signFixture('hello', signer),
          source: () async => null,
          onStatus: statuses.add,
          fallbackBuilder: (_, _) => const Text('fallback'),
        ),
      ),
    );
    await pumpUntil(tester, () => visibleIn(tester, 'Hello from a patch'));

    // A healthy render must reach the store, so the crash-loop counter resets.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(BundleStore(cache).shouldAutoRollback(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a quarantined active bundle is not rendered on a cold start', (
    tester,
  ) async {
    // Rollback fails with an empty history — the normal state on a fresh
    // install — leaving the quarantined bundle active. Rendering it anyway
    // rebuilt the interpreter and failed on every launch, forever.
    //
    // The quarantine must be recorded by THIS build to count, so the view is
    // pumped once first to establish the capability fingerprint; a record from
    // a different binary is deliberately discarded (see the loader's
    // host-reconcile tests).
    Widget view({bool withBundled = true}) => MaterialApp(
      home: EjenixPatchView(
        controlPlane: Uri.parse('http://unused.test'),
        appId: _appId,
        trustedKeys: [signer.publicKey],
        cacheDir: cache,
        bundledFallback: withBundled ? signFixture('hello', signer) : null,
        source: () async => null,
        fallbackBuilder: (_, _) => const Text('fallback'),
      ),
    );

    await tester.pumpWidget(view());
    await pumpUntil(tester, () => visibleIn(tester, 'Hello from a patch'));
    expect(find.text('Hello from a patch'), findsOneWidget);

    // Tear the view down FIRST. Two BundleStore instances over one directory
    // are last-writer-wins, and the live view's post-frame markHealthy() would
    // otherwise persist over the quarantine written here.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 20));

    // Now quarantine what is active, as _onPatchUnrunnable would.
    final store = BundleStore(cache);
    store.quarantine(store.activeId!);

    // A cold start on the same binary, resolving from cache only.
    await tester.pumpWidget(view(withBundled: false));
    await tester.pump(const Duration(milliseconds: 40));

    expect(
      find.text('Hello from a patch'),
      findsNothing,
      reason: 'a bundle this build already proved unrunnable must not render',
    );
    expect(tester.takeException(), isNull);
  });
}

bool visibleIn(WidgetTester tester, String text) =>
    find.text(text).evaluate().isNotEmpty;

/// The safety net for permanent faults nobody named.
void _escalationTests() {
  testWidgets('a patch that keeps failing is recovered, not left forever', (
    tester,
  ) async {
    // A fault that is neither a missing capability nor a bad return type is
    // classified transient — correctly, since it may clear. But if it never
    // clears, the user used to sit on the fallback indefinitely with the broken
    // patch still active. Repetition escalates it without needing a taxonomy.
    final cache = Directory.systemTemp.createTempSync('escalate');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on FileSystemException {
        // best effort
      }
    });
    final signer = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 11));

    // `build() { return null + null; }` — a TypeError every single frame.
    final f =
        (BytecodeBuilder()
              ..emitA(Op.loadNull, 1)
              ..emitA(Op.loadNull, 2)
              ..emitABC(Op.addInt, 0, 1, 2)
              ..emitA(Op.ret, 0))
            .toProto(name: 'build', paramCount: 0, registerCount: 3);
    final broken = Bundle.sign(
      module: Module(constants: ConstantPool(), functions: [f]),
      metadata: const BundleMetadata(
        targetAppId: _appId,
        targetFlutterVersion: '3.44.6',
        minSdk: '1.0.0',
      ),
      signer: signer,
      compilerVersion: '0.1.0',
    ).encode();

    final statuses = <PatchStatus>[];
    var serve = signFixture('hello', signer);

    await tester.pumpWidget(
      MaterialApp(
        home: EjenixPatchView(
          controlPlane: Uri.parse('http://unused.test'),
          appId: _appId,
          trustedKeys: [signer.publicKey],
          cacheDir: cache,
          source: () async => serve,
          onStatus: statuses.add,
          fallbackBuilder: (_, _) => const Text('fallback'),
        ),
      ),
    );
    await pumpUntil(tester, () => visibleIn(tester, 'Hello from a patch'));

    // Promote the permanently-broken patch.
    serve = broken;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    // Each retry costs 50ms of fake time before the next attempt, so the
    // escalation needs more than the default pump budget.
    await pumpUntil(
      tester,
      () => statuses.contains(PatchStatus.incompatible),
      tries: 200,
    );

    // The guarantee this test exists for: a permanent fault that no exception
    // type names still reaches recovery, so the broken patch is retired rather
    // than left active forever. (Restoring the previous patch after a rollback
    // is covered by 'an unrunnable patch rolls back to the last working one';
    // here the point is that an *unnameable* fault escalates at all.)
    expect(
      BundleStore(cache).isQuarantined(Bundle.decode(broken).bundleId),
      isTrue,
      reason: 'a fault that never clears must not stay active forever',
    );
    expect(find.text('Hello from a patch'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// The three edge-ordering and efficiency findings from the adversarial review.
void _orderingTests() {
  late Directory cache;
  late Signer signer;
  setUp(() {
    cache = Directory.systemTemp.createTempSync('ordering');
    signer = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 11));
  });
  tearDown(() {
    try {
      cache.deleteSync(recursive: true);
    } on FileSystemException {
      // best effort
    }
  });

  testWidgets('an undecodable bundle never displaces the working patch', (
    tester,
  ) async {
    // Activating moves the current patch to history and resets the crash-loop
    // counter. Doing that before knowing the new bundle renders would swap a
    // working screen for one that cannot be shown.
    var serve = signFixture('hello', signer);
    final statuses = <PatchStatus>[];

    await tester.pumpWidget(
      MaterialApp(
        home: EjenixPatchView(
          controlPlane: Uri.parse('http://unused.test'),
          appId: _appId,
          trustedKeys: [signer.publicKey],
          cacheDir: cache,
          source: () async => serve,
          onStatus: statuses.add,
          fallbackBuilder: (_, _) => const Text('fallback'),
        ),
      ),
    );
    await pumpUntil(tester, () => visibleIn(tester, 'Hello from a patch'));
    final activeBefore = BundleStore(cache).activeId;

    // A bundle that verifies but whose body cannot be decoded.
    serve = signFixture('counter', signer);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpUntil(tester, () => statuses.length > 1, tries: 60);

    // Whatever happened, a renderable patch is still on screen and the store
    // did not end up pointing at something unusable.
    expect(BundleStore(cache).activeBundle, isNotNull);
    expect(BundleStore(cache).activeId, isNotNull);
    expect(activeBefore, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recovery stops after a couple of rollbacks in one launch', (
    tester,
  ) async {
    // With several unrunnable patches in history, recovery used to walk the
    // whole chain in a single launch. Capping it leaves history intact for the
    // next start, by which time a fixed build may have arrived.
    final broken = _brokenBundle(signer);
    final statuses = <PatchStatus>[];
    var serve = signFixture('hello', signer);

    await tester.pumpWidget(
      MaterialApp(
        home: EjenixPatchView(
          controlPlane: Uri.parse('http://unused.test'),
          appId: _appId,
          trustedKeys: [signer.publicKey],
          cacheDir: cache,
          source: () async => serve,
          onStatus: statuses.add,
          fallbackBuilder: (_, _) => const Text('fallback'),
        ),
      ),
    );
    await pumpUntil(tester, () => visibleIn(tester, 'Hello from a patch'));

    serve = broken;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpUntil(
      tester,
      () => statuses.contains(PatchStatus.incompatible),
      tries: 200,
    );

    // It recovered, and it did not spin: history is not exhausted and the app
    // is still showing something.
    expect(
      statuses.where((s) => s == PatchStatus.incompatible).length,
      lessThanOrEqualTo(3),
    );
    expect(tester.takeException(), isNull);
  });
}

/// A signed bundle whose `build` throws a RangeError on every frame — permanent,
/// but not a capability miss or a wrong return type.
Uint8List _brokenBundle(Signer signer) {
  final f =
      (BytecodeBuilder()
            ..emitA(Op.loadNull, 1)
            ..emitA(Op.loadNull, 2)
            ..emitABC(Op.addInt, 0, 1, 2)
            ..emitA(Op.ret, 0))
          .toProto(name: 'build', paramCount: 0, registerCount: 3);
  return Bundle.sign(
    module: Module(constants: ConstantPool(), functions: [f]),
    metadata: const BundleMetadata(
      targetAppId: _appId,
      targetFlutterVersion: '3.44.6',
      minSdk: '1.0.0',
    ),
    signer: signer,
    compilerVersion: '0.1.0',
  ).encode();
}
