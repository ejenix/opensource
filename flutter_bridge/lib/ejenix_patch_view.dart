// Copyright (c) Ejenix authors. MIT license.

/// Turnkey production over-the-air patching for a Flutter screen.
///
/// [EjenixPatchView] is the drop-in that ties the whole device pipeline together —
/// a [PatchResolver] (get the active patch bytes), [Loader]/[BundleStore]
/// (verify → stage → activate, with crash-loop rollback), and [InterpretedView]
/// (render it) — so an app gets real over-the-air updates in about ten lines.
/// Everything a patch may reach beyond stock Flutter is granted through
/// [extend], exactly as with [InterpretedView].
///
/// It is **offline-first and fail-soft**: it renders the cached (or bundled)
/// patch immediately, resolves the active patch from the control plane in the
/// background on launch and on app-resume, and swaps in a newer *verified* patch
/// when one is promoted. If the control plane is unreachable, or a patch fails
/// verification, or nothing has ever been cached, it keeps running the last good
/// patch — or your [fallbackBuilder] — and never throws into the UI.
///
/// Fetching (the async, network part) is isolated behind [PatchResolver] so the
/// verify/stage/render pipeline is deterministically testable without sockets.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_loader/loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'ejenix_flutter.dart';

/// Returns the bytes of the currently-active patch, or `null` when there is
/// nothing new to apply (already current, or the control plane is unreachable).
/// The default resolves against a control plane; tests supply their own.
typedef PatchResolver = Future<Uint8List?> Function();

/// Where the on-screen patch came from and what the loader is doing — surfaced
/// through [EjenixPatchView.onStatus] for logging or a debug banner.
enum PatchStatus {
  /// Rendering a patch restored from the on-disk cache.
  cached,

  /// Rendering the patch that shipped in the app binary.
  bundled,

  /// A newer verified patch was fetched and is now on screen.
  updated,

  /// Checked the control plane; nothing new to apply.
  upToDate,

  /// A fetched patch failed verification and was discarded.
  rejected,

  /// A crash loop was detected and the previous patch was restored.
  rolledBack,

  /// The active patch could not run on this build and was rolled back.
  ///
  /// Distinct from [rolledBack]: nothing crashed and the signature was good.
  /// The patch asked for a host capability this binary does not register —
  /// usually a patch published ahead of the release that adds it — or it threw
  /// while rendering. Either way it can never work on this build, so waiting
  /// for a crash loop would just show the fallback on every launch.
  incompatible,
}

/// Renders a screen from a signed, interpreted patch fetched from a control
/// plane, updating over the air.
///
/// ```dart
/// EjenixPatchView(
///   controlPlane: Uri.parse('https://patches.myapp.com'),
///   appId: 'com.myapp',
///   trustedKeys: [myPublicKey],           // the key your CI signs with
///   cacheDir: await getApplicationSupportDirectory(), // path_provider
///   bundledFallback: await rootBundle
///       .load('assets/home.bundle')
///       .then((d) => d.buffer.asUint8List()),
///   extend: appCapabilities(repo),        // your widgets, state, services
///   fallbackBuilder: (context, error) => const NativeHomeScreen(),
/// )
/// ```
class EjenixPatchView extends StatefulWidget {
  const EjenixPatchView({
    super.key,
    required this.controlPlane,
    required this.appId,
    required this.trustedKeys,
    required this.cacheDir,
    this.env = 'production',
    this.bundledFallback,
    this.extend,
    this.functionName = 'build',
    this.createStateName = 'createState',
    this.sdkVersion = '1.0.0',
    this.flutterVersion = '0.0.0',
    this.loadingBuilder,
    this.fallbackBuilder,
    this.onStatus,
    this.source,
    this.stepLimit = kDefaultPatchStepLimit,
  });

  /// Instruction budget for a single interpreted call — see
  /// [kDefaultPatchStepLimit]. A patch that overruns it is treated as
  /// permanently unrunnable here and rolled back, exactly like one that needs
  /// a capability this build lacks. Without a budget a hanging patch is
  /// unrecoverable: it never crashes, so nothing triggers the rollback.
  final int? stepLimit;

  /// The control-plane origin, e.g. `https://patches.myapp.com`.
  final Uri controlPlane;

  /// This app's id on the control plane. A patch must target it exactly.
  final String appId;

  /// The environment to track (`production`, `staging`, …).
  final String env;

  /// Public keys this build trusts. A patch is run only if signed by one of
  /// them — the root of trust against a compromised update server.
  final List<Uint8List> trustedKeys;

  /// Directory the [BundleStore] owns (staging, active pointer, crash-loop
  /// counter). Use a per-app private dir, e.g. `path_provider`'s
  /// `getApplicationSupportDirectory()`.
  final Directory cacheDir;

  /// The patch that shipped in the binary, so the app works offline and on
  /// first launch. Verified before use, like any other patch.
  final Uint8List? bundledFallback;

  /// Grants the patch the app's own widgets/state/services. See [HostExtension].
  final HostExtension? extend;

  /// The interpreted entry point and its optional state factory.
  final String functionName;
  final String createStateName;

  /// Host identity for the loader's compatibility check (a patch declares a
  /// minimum SDK; [sdkVersion] must meet it).
  final String sdkVersion;
  final String flutterVersion;

  /// Shown while the first patch is being resolved (no cache, no fallback).
  /// Defaults to a centered progress indicator.
  final WidgetBuilder? loadingBuilder;

  /// Shown when there is nothing runnable — no cache, no valid fallback, and
  /// the control plane is unreachable. This is where you put the screen that
  /// shipped natively in your app.
  final Widget Function(BuildContext context, Object error)? fallbackBuilder;

  /// Called on every state change, for logging or a debug overlay.
  final void Function(PatchStatus status)? onStatus;

  /// Overrides how the active patch bytes are fetched. Defaults to the control
  /// plane at [controlPlane]; injected in tests to avoid real sockets.
  final PatchResolver? source;

  @override
  State<EjenixPatchView> createState() => _EjenixPatchViewState();
}

class _EjenixPatchViewState extends State<EjenixPatchView>
    with WidgetsBindingObserver {
  late final BundleStore _store;
  late final Loader _loader;
  late final PatchResolver _resolve;

  Module? _module;
  Object? _error;
  bool _checking = false;
  bool _markedHealthy = false;

  /// Set when the active patch could not run in this frame. Checked before
  /// marking the patch healthy, so an unrunnable patch never resets the
  /// crash-loop counter.
  bool _patchFailed = false;

  /// Guards the recovery below to one attempt per activated patch — the error
  /// builder runs on every rebuild, and rolling back repeatedly would walk the
  /// whole history back to nothing.
  bool _handlingFailure = false;

  /// Consecutive frames in which the patch failed to render.
  ///
  /// Naming the permanent faults (a missing capability, a non-widget return)
  /// only covers the ones we thought of. A patch can fail forever in ways no
  /// list anticipates — a cast against a capability whose shape changed, a
  /// null from state it assumed. Those were classified transient, so the patch
  /// was never rolled back and the user sat on the fallback **indefinitely**.
  ///
  /// Repetition is the signal that does not need a taxonomy: a fault that
  /// survives this many rebuilds is not going to clear itself.
  int _consecutiveFailures = 0;
  static const _failureEscalationThreshold = 3;

  /// Rollbacks performed by this view.
  ///
  /// If several patches in history are all unrunnable, recovery would walk the
  /// entire history in a single launch — a burst of disk work and a flicker per
  /// step, ending with nothing left to fall back to. Stopping after a couple of
  /// attempts keeps the remaining history intact for the next launch, by which
  /// time a fixed build or a new patch may have arrived.
  int _rollbacksThisSession = 0;
  static const _maxRollbacksPerSession = 2;

  /// The most recent render failure, shown by [fallbackBuilder] when there is
  /// nothing left to roll back to.
  Object? _lastFailure;

  /// The pending retry, cancelled on dispose so a torn-down view leaves no
  /// timer behind.
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    _store = BundleStore(widget.cacheDir);
    // The loader owns verify + stage + compatibility; fetching is done by the
    // resolver, so the loader needs no network fetcher of its own here.
    _loader = Loader(
      store: _store,
      fetcher: const _UnusedFetcher(),
      anchors: TrustAnchors(widget.trustedKeys),
      host: HostEnvironment(
        appId: widget.appId,
        flutterVersion: widget.flutterVersion,
        sdkVersion: widget.sdkVersion,
      ),
    );
    _resolve = widget.source ?? _controlPlaneResolver();

    // Tie any quarantine records to the capability surface this build ships.
    // A release that adds the missing capability changes the fingerprint and
    // clears the records, so devices that quarantined a patch try it again —
    // which is what makes "ship a build that registers it" an actual remedy
    // rather than a permanent fleet split.
    _store.reconcileHost(_capabilityFingerprint());

    // Crash-loop protection: a launch that never reaches a healthy frame counts
    // against the active patch; enough of those and we roll back *before*
    // running it again.
    _store.recordLaunch();
    if (_store.shouldAutoRollback() && _store.rollback()) {
      _report(PatchStatus.rolledBack);
    }

    _loadInitial();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void dispose() {
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check when the app returns to the foreground — the standard cadence,
    // no background polling.
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  /// The production resolver: ask the control plane which bundle is active, then
  /// download it (with an ETag so an unchanged bundle is a cheap 304).
  PatchResolver _controlPlaneResolver() {
    final client = ControlPlaneClient(
      base: widget.controlPlane,
      appId: widget.appId,
      env: widget.env,
    );
    final fetcher = HttpBundleFetcher();
    String? etag;
    return () async {
      final id = await client.activeBundleId();
      if (id == null) return null;
      // Skip the download entirely for a bundle already proved unrunnable on
      // this build. The control plane keeps serving it — it is the promoted
      // patch — so without this every launch pays for a full bundle it will
      // only refuse. Cheap to check, and the bytes are the expensive part.
      final quarantined = _parseBundleId(id);
      if (quarantined != null && _store.isQuarantined(quarantined)) {
        return null;
      }
      final result = await fetcher.fetch(client.downloadUrl(id), etag: etag);
      if (result is FetchSuccess) {
        etag = result.etag;
        return result.bytes;
      }
      return null; // not modified, or a fetch failure — nothing new
    };
  }

  /// Picks the module to show right now, without touching the network: the
  /// cached active patch if there is one, else the bundled fallback.
  void _loadInitial() {
    // A quarantined bundle can still be the active one — rollback fails when
    // there is no history, which is the normal state on a fresh install with no
    // bundledFallback. Rendering it anyway meant building the interpreter,
    // failing, and showing the fallback on every cold start forever, while a
    // perfectly good bundledFallback sat unused.
    final activeId = _store.activeId;
    final quarantined = activeId != null && _store.isQuarantined(activeId);
    final cached = quarantined ? null : _moduleFromBundle(_store.activeBundle);
    if (cached != null) {
      _module = cached;
      _report(PatchStatus.cached);
      return;
    }
    final fallback = widget.bundledFallback;
    if (fallback != null) {
      // Ingest the shipped patch so it becomes the active baseline — this makes
      // the cache work on first launch and gives deltas a base to apply against.
      final outcome = _loader.ingest(fallback);
      // Quarantine applies here too. The bundled patch and the active one are
      // frequently the same artifact, so without this check the fallback path
      // simply re-activates the bundle that was just proved unrunnable — and
      // the cold start renders it after all.
      if (outcome is Staged && !_store.isQuarantined(outcome.bundleId)) {
        _store.activate(outcome.bundleId);
        _module = _moduleFromBundle(_store.activeBundle);
        _report(PatchStatus.bundled);
        return;
      }
    }
    // Nothing runnable yet; the background check may still find one.
    _error ??= StateError('no cached or bundled patch available');
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      final bytes = await _resolve();
      if (bytes == null) {
        _report(PatchStatus.upToDate);
        return;
      }
      // Verify + stage happens here (synchronous); the bytes are untrusted.
      switch (_loader.ingest(bytes)) {
        case Staged(:final bundleId):
          // Already live. Re-activating would move it to history and back and
          // reset both the crash-loop counter and the healthy flag, so a patch
          // re-served on every launch could never accumulate the launches that
          // trip auto-rollback. The safety net would be silently disarmed.
          if (_sameAsActive(bundleId)) {
            // Already live. Drop the redundant staged copy rather than leaving
            // one behind on every check.
            _store.discardStaging(bundleId);
            _report(PatchStatus.upToDate);
            return;
          }

          // Proven unrunnable on this build. The control plane will keep
          // serving it — it is the promoted patch and the server has no idea
          // this binary lacks the capability — so without this the rollback
          // just made would be undone on the next check, forever.
          if (_store.isQuarantined(bundleId)) {
            _store.discardStaging(bundleId);
            _report(PatchStatus.incompatible);
            return;
          }

          // Decode from staging first. Activating moves the current patch to
          // history and resets the crash-loop counter, so doing it before we
          // know the new bundle is renderable would displace a working patch
          // with one we cannot show — and leave no signal that it happened.
          final next = _moduleFromBundle(_store.staged(bundleId));
          if (next == null) {
            _store.discardStaging(bundleId);
            _report(PatchStatus.rejected);
            return;
          }
          if (!mounted) {
            // The view went away mid-fetch. Leave staging for the next launch
            // rather than activating against a dead state object.
            return;
          }
          _store.activate(bundleId);
          setState(() {
            _module = next;
            _error = null;
            // A newly activated patch has not proved itself yet.
            _markedHealthy = false;
            _patchFailed = false;
            _consecutiveFailures = 0;
          });
          _report(PatchStatus.updated);
        case Rejected():
          _report(PatchStatus.rejected);
        case UpToDate():
        case FetchError():
          _report(PatchStatus.upToDate);
      }
    } finally {
      _checking = false;
    }
  }

  /// Decodes a store bundle into its module, or `null` if absent/undecodable.
  Module? _moduleFromBundle(Bundle? bundle) {
    if (bundle == null) return null;
    try {
      return bundle.decodeBody().$1;
    } on Object {
      return null;
    }
  }

  /// Delivers a status to [EjenixPatchView.onStatus], never during a build.
  ///
  /// The first statuses are reported from `initState`, which Flutter runs
  /// *inside the parent's build*. A host doing the documented thing — calling
  /// `setState` to drive a debug banner — then crashed with
  /// `setState() or markNeedsBuild() called during build`, from a callback the
  /// API invites them to write that way.
  ///
  /// Deferring to after the frame costs nothing (this is logging and overlays,
  /// not control flow) and makes the obvious usage correct.
  /// A stable digest of everything this build lets a patch reach.
  ///
  /// Cheap enough to compute once per view: building the registry is map
  /// inserts, and the result is only used to decide whether the quarantine
  /// still describes this binary.
  String _capabilityFingerprint() {
    final ctx = BridgeContext();
    final registry = flutterHostRegistry(ctx);
    widget.extend?.call(registry, ctx);
    final names = [...registry.globalNames, ...registry.methodNames];
    // FNV-1a: order is already stable (both getters sort), and a digest keeps
    // the persisted state small regardless of how large the surface grows.
    var hash = 0x811c9dc5;
    for (final name in names) {
      for (final unit in name.codeUnits) {
        hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
      }
      hash = ((hash ^ 0x2f) * 0x01000193) & 0xFFFFFFFF;
    }
    return '${names.length}-${hash.toRadixString(16)}';
  }

  void _report(PatchStatus status) {
    final callback = widget.onStatus;
    if (callback == null) return;
    // Always deferred, never conditionally. An earlier version only deferred
    // when `schedulerPhase` said a frame was building — which is right for a
    // normal frame and wrong for the warm-up frame, where the first build runs
    // with the phase still `idle`. That version passed every widget test
    // (pumpWidget uses a normal frame) and crashed on a real device on launch.
    // A status is logging, not control flow; one frame of latency costs
    // nothing and this way the phase can never be wrong.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback(status);
    });
  }

  /// Parses a control-plane bundle id (a UUID string) into raw bytes, or null
  /// if it is not one — an unrecognised id is simply not matched against the
  /// quarantine rather than treated as an error.
  static Uint8List? _parseBundleId(String id) {
    final hex = id.replaceAll('-', '');
    if (hex.length != 32) return null;
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }

  bool _sameAsActive(Uint8List id) {
    final active = _store.activeId;
    if (active == null || active.length != id.length) return false;
    for (var i = 0; i < id.length; i++) {
      if (active[i] != id[i]) return false;
    }
    return true;
  }

  /// Recovers from an active patch that cannot run on this build.
  ///
  /// Verification passed and nothing crashed — the patch simply cannot work
  /// here, because it calls a capability this binary does not register or it
  /// throws while rendering. Crash-loop detection does not help: no launch ever
  /// fails, so the counter never trips and the user would see the fallback on
  /// every launch, indefinitely.
  ///
  /// So treat it as the loader treats a crash loop — roll back to the last
  /// bundle that worked. If there is no history to roll back to, keep showing
  /// the fallback, which is still the app's own screen rather than an error.
  ///
  /// Called from the error builder during a frame, so the actual work is
  /// deferred: rolling back touches disk and calls setState.
  /// Records this frame's failure and, for a fault that can never succeed,
  /// recovers immediately.
  void _onPatchUnrunnable(Object error) {
    _patchFailed = true;
    _lastFailure = error;

    // Recover at once only for a fault we can name as permanent. Anything else
    // may be transient — a service not ready, a one-off null — and discarding a
    // working patch over one would be its own outage. Those still get the
    // fallback for this frame; if they keep failing, the repeat counter in
    // build() escalates them here anyway, so nothing can strand a user forever.
    if (!isUnrunnableOnThisBuild(error)) return;
    _recoverFromUnrunnablePatch();
  }

  /// Quarantines the active patch and restores the last one that worked.
  void _recoverFromUnrunnablePatch() {
    if (_handlingFailure) return;
    if (_rollbacksThisSession >= _maxRollbacksPerSession) {
      // Enough for one launch. The active patch stays quarantined, so the next
      // start resumes from a known-bad marker rather than re-walking history.
      setState(() => _error = _lastFailure);
      _report(PatchStatus.incompatible);
      return;
    }
    _handlingFailure = true;
    _rollbacksThisSession++;

    // Quarantine before rolling back — afterwards the active id is the previous
    // bundle and the identity of the bad one is gone. Persisted, so a cold
    // start does not re-activate it and roll back all over again.
    final failed = _store.activeId;
    if (failed != null) _store.quarantine(failed);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final restored = _store.rollback();
      if (!restored) {
        // Nothing to fall back to; fallbackBuilder owns the screen from here.
        // _handlingFailure is released so a *different* patch arriving later
        // can still be recovered from — latching it meant the next bad patch
        // was silently ignored for the life of this view.
        setState(() {
          _error = _lastFailure;
          _module = null;
          _handlingFailure = false;
          _consecutiveFailures = 0;
        });
        _report(PatchStatus.incompatible);
        return;
      }
      final previous = _moduleFromBundle(_store.activeBundle);
      setState(() {
        _module = previous;
        _error = previous == null ? _lastFailure : null;
        // The restored patch gets its own chance to prove itself healthy.
        _markedHealthy = false;
        _patchFailed = false;
        _handlingFailure = false;
        _consecutiveFailures = 0;
      });
      _report(PatchStatus.incompatible);
    });
  }

  @override
  Widget build(BuildContext context) {
    final module = _module;
    if (module != null) {
      // Once the interpreted screen has painted its first frame, the patch is
      // healthy — reset the crash-loop counter so a good patch is never rolled
      // back. Guarded so it is one disk write, not one per frame.
      //
      // The `_patchFailed` check is load-bearing. The child builds after this
      // callback is scheduled but before it runs, so if the patch turns out to
      // be unrunnable the flag is set by then. Without it, catching the error
      // would mark a broken patch healthy: the crash-loop counter would reset,
      // auto-rollback would never trip, and the user would get the fallback on
      // every launch forever.
      // This frame's verdict, not a latch. Setting it once and never clearing
      // it meant a patch that threw on frame 1 (a service not ready, a null
      // pre-login) and rendered perfectly forever after could never be marked
      // healthy again — so the crash-loop counter climbed and auto-rollback
      // eventually discarded a *working* patch. Exactly the punishment the
      // transient path exists to avoid, arriving through a different door.
      _patchFailed = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_patchFailed) {
          _consecutiveFailures++;
          // A fault that survives this many attempts is permanent in practice,
          // whatever its type. Escalate so the user gets the previous working
          // patch rather than the fallback forever.
          if (_consecutiveFailures >= _failureEscalationThreshold) {
            _recoverFromUnrunnablePatch();
            return;
          }
          // Retry explicitly. Counting rebuilds alone does not work: a patch
          // that fails identically every time renders once and nothing marks it
          // dirty again, so the counter would sit at 1 and the user would stay
          // on the fallback indefinitely — the exact stranding this exists to
          // prevent. A short delay gives a genuinely transient fault (a service
          // still loading) room to clear before the next attempt.
          _retry?.cancel();
          _retry = Timer(const Duration(milliseconds: 50), () {
            if (mounted && _patchFailed) setState(() {});
          });
          return;
        }
        _consecutiveFailures = 0;
        if (_markedHealthy) return;
        _markedHealthy = true;
        _store.markHealthy();
      });
      return InterpretedView(
        module: module,
        extend: widget.extend,
        functionName: widget.functionName,
        createStateName: widget.createStateName,
        stepLimit: widget.stepLimit,
        // A verified patch can still be unrunnable on *this* build — it may
        // need a capability released after it, or throw while rendering. Show
        // the app's own fallback for this frame, and deal with the patch
        // itself once the frame is done.
        errorBuilder: (context, error) {
          _onPatchUnrunnable(error);
          return widget.fallbackBuilder?.call(context, error) ??
              const SizedBox.shrink();
        },
      );
    }

    final error = _error;
    if (error != null && widget.fallbackBuilder != null) {
      return widget.fallbackBuilder!(context, error);
    }
    return widget.loadingBuilder?.call(context) ??
        const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

/// A [BundleFetcher] the [Loader] never calls: [EjenixPatchView] fetches through
/// its [PatchResolver] and only uses the loader to verify and stage.
class _UnusedFetcher implements BundleFetcher {
  const _UnusedFetcher();

  @override
  Future<FetchResult> fetch(Uri url, {String? etag}) async =>
      const FetchFailure('unused');
}
