// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';

/// The on-disk bundle store: staging, the active bundle, a bounded history, and
/// the crash-loop counter (brief §6.6).
///
/// Layout under [root]:
///
/// ```text
///   active.bundle          the currently active bundle
///   staging/<id>.bundle    verified, awaiting activation
///   history/<id>.bundle    previous actives (LRU-capped at [historyLimit])
///   state.json            authoritative pointer + crash-loop counter
/// ```
///
/// `state.json` is the source of truth; activation and rollback move files with
/// atomic renames and update the state last. All I/O is synchronous because the
/// store is driven at process startup.
class BundleStore {
  BundleStore(this.root, {this.historyLimit = 5, this.crashThreshold = 3}) {
    _stagingDir.createSync(recursive: true);
    _historyDir.createSync(recursive: true);
    _load();
  }

  /// The store's root directory.
  final Directory root;

  /// Maximum number of retained history entries.
  final int historyLimit;

  /// Consecutive un-healthy launches after which [shouldAutoRollback] trips.
  final int crashThreshold;

  Uint8List? _activeId;
  int _activatedAtMillis = 0;
  int _launchesSinceActivation = 0;
  bool _healthy = false;
  final List<String> _history = []; // hex ids, most recent first
  String? _lastEtag;

  /// The active bundle's id, or `null` if none is active.
  Uint8List? get activeId => _activeId;

  /// The number of launches since the active bundle was activated without a
  /// [markHealthy] call.
  int get launchesSinceActivation => _launchesSinceActivation;

  /// Whether the active bundle has been marked healthy at least once.
  bool get isHealthy => _healthy;

  /// History bundle ids, most recent first.
  List<String> get historyIds => List.unmodifiable(_history);

  /// The cached HTTP entity tag from the last successful fetch.
  String? get lastEtag => _lastEtag;
  set lastEtag(String? value) {
    _lastEtag = value;
    _persist();
  }

  /// The active bundle, decoded, or `null` if none / unreadable.
  Bundle? get activeBundle {
    final bytes = activeBundleBytes;
    if (bytes == null) return null;
    try {
      return Bundle.decode(bytes);
    } on BundleFormatException {
      return null;
    }
  }

  /// The raw bytes of the active bundle, or `null` if none. Used as the base
  /// when applying a delta.
  Uint8List? get activeBundleBytes {
    final file = _activeFile;
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  /// Writes [bundle] to staging, ready to be activated.
  void writeStaging(Bundle bundle) {
    _stagingFile(bundle.bundleId).writeAsBytesSync(bundle.encode());
  }

  /// Reads a staged bundle by [id], or `null` if not staged.
  Bundle? staged(Uint8List id) {
    final file = _stagingFile(id);
    if (!file.existsSync()) return null;
    return Bundle.decode(file.readAsBytesSync());
  }

  /// Activates the staged bundle [id]: the current active moves to history and
  /// the staged bundle becomes active. Returns `false` if [id] is not staged.
  bool activate(Uint8List id) {
    final staging = _stagingFile(id);
    if (!staging.existsSync()) return false;

    final previous = _activeId;
    if (previous != null && _activeFile.existsSync()) {
      final hex = _hex(previous);
      _activeFile.renameSync(_historyFile(previous).path);
      _history
        ..remove(hex)
        ..insert(0, hex);
    }
    staging.renameSync(_activeFile.path);

    _activeId = id;
    _activatedAtMillis = DateTime.now().millisecondsSinceEpoch;
    _launchesSinceActivation = 0;
    _healthy = false;
    _enforceHistoryLimit();
    _persist();
    return true;
  }

  /// Reverts to the most recent history entry. Returns `false` if history is
  /// empty. The rolled-back-from bundle is discarded.
  bool rollback() {
    if (_history.isEmpty) return false;
    final restoreHex = _history.removeAt(0);
    final restoreId = _unhex(restoreHex);
    final restoreFile = _historyFile(restoreId);

    if (_activeFile.existsSync()) _activeFile.deleteSync();
    restoreFile.renameSync(_activeFile.path);

    _activeId = restoreId;
    _activatedAtMillis = DateTime.now().millisecondsSinceEpoch;
    _launchesSinceActivation = 0;
    _healthy = true; // it ran before, so treat as known-good
    _persist();
    return true;
  }

  /// Records a process launch. Call once, early, at startup.
  void recordLaunch() {
    _launchesSinceActivation++;
    _persist();
  }

  /// Marks the active bundle healthy, resetting the crash-loop counter. Call
  /// once the app has confirmed a good startup (e.g. first frame rendered).
  void markHealthy() {
    if (_healthy && _launchesSinceActivation == 0) return;
    _healthy = true;
    _launchesSinceActivation = 0;
    _persist();
  }

  /// Whether the active bundle appears to be crash-looping and should be rolled
  /// back before the next run.
  bool shouldAutoRollback() =>
      !_healthy &&
      _activeId != null &&
      _history.isNotEmpty &&
      _launchesSinceActivation >= crashThreshold;

  /// The wall-clock time the active bundle was activated.
  DateTime get activatedAt =>
      DateTime.fromMillisecondsSinceEpoch(_activatedAtMillis);

  // --- Paths ---

  File get _activeFile => File('${root.path}/active.bundle');
  Directory get _stagingDir => Directory('${root.path}/staging');
  Directory get _historyDir => Directory('${root.path}/history');
  File get _stateFile => File('${root.path}/state.json');
  File _stagingFile(Uint8List id) =>
      File('${_stagingDir.path}/${_hex(id)}.bundle');
  File _historyFile(Uint8List id) =>
      File('${_historyDir.path}/${_hex(id)}.bundle');

  void _enforceHistoryLimit() {
    while (_history.length > historyLimit) {
      final evicted = _unhex(_history.removeLast());
      final file = _historyFile(evicted);
      if (file.existsSync()) file.deleteSync();
    }
  }

  // --- Persistence ---

  /// Bundle ids that verified and staged but could not run on this build.
  ///
  /// Survives a restart because the control plane will keep serving such a
  /// bundle — it is the promoted patch, and the server cannot know this binary
  /// lacks the capability. Without remembering, every launch would re-activate
  /// it, fail to render, and roll back again: a permanent churn the user sees
  /// as a flash of the fallback on every cold start.
  final Set<String> _quarantined = <String>{};

  /// Deletes the staged copy of [id], if any.
  ///
  /// A bundle that verified and staged but was then refused activation — it is
  /// quarantined, or already live — otherwise sits in staging forever. Nothing
  /// GCs it, and every refusal adds another, so a device that keeps being
  /// offered a patch it cannot run accumulates copies until storage complains.
  void discardStaging(Uint8List id) {
    final file = _stagingFile(id);
    if (file.existsSync()) file.deleteSync();
  }

  /// Whether [id] already proved unrunnable on this build.
  bool isQuarantined(Uint8List id) => _quarantined.contains(_hex(id));

  /// Discards quarantine records when the host's capability surface changes.
  ///
  /// Quarantine is a property of (bundle, binary), but it is keyed on bundle
  /// alone. A bundle id is baked in at signing, so the operator's actual
  /// remedy — ship a build that registers the capability, leave the patch
  /// promoted — produces the *same* id, and every device that quarantined it
  /// would stay pinned to the older patch forever on a binary that can now run
  /// the new one. The fleet would split with no device-side way back.
  ///
  /// Passing a fingerprint of what this build registers ties the record to the
  /// binary that made it: a release that changes the capability surface clears
  /// the slate and lets the patch be tried again.
  void reconcileHost(String fingerprint) {
    if (_hostFingerprint == fingerprint) return;
    _hostFingerprint = fingerprint;
    _quarantined.clear();
    _persist();
  }

  /// The capability fingerprint the quarantine records belong to.
  String? get hostFingerprint => _hostFingerprint;
  String? _hostFingerprint;

  /// Records [id] as unrunnable, so it is never activated again.
  void quarantine(Uint8List id) {
    if (_quarantined.add(_hex(id))) _persist();
  }

  void _load() {
    if (!_stateFile.existsSync()) return;
    try {
      final json = jsonDecode(_stateFile.readAsStringSync()) as Map;
      final active = json['activeId'] as String?;
      _activeId = active == null ? null : _unhex(active);
      _activatedAtMillis = (json['activatedAtMillis'] as num?)?.toInt() ?? 0;
      _launchesSinceActivation =
          (json['launchesSinceActivation'] as num?)?.toInt() ?? 0;
      _healthy = json['healthy'] as bool? ?? false;
      _lastEtag = json['lastEtag'] as String?;
      _history
        ..clear()
        ..addAll((json['history'] as List? ?? const []).cast<String>());
      _quarantined
        ..clear()
        ..addAll((json['quarantined'] as List? ?? const []).cast<String>());
      _hostFingerprint = json['hostFingerprint'] as String?;
      // Self-heal: an activeId with no file means nothing is active.
      if (_activeId != null && !_activeFile.existsSync()) _activeId = null;
    } on FormatException {
      // Corrupt state resets to empty; the loader will re-fetch.
    }
  }

  void _persist() {
    _stateFile.writeAsStringSync(
      jsonEncode({
        'activeId': _activeId == null ? null : _hex(_activeId!),
        'activatedAtMillis': _activatedAtMillis,
        'launchesSinceActivation': _launchesSinceActivation,
        'healthy': _healthy,
        'lastEtag': _lastEtag,
        'history': _history,
        'quarantined': _quarantined.toList(),
        'hostFingerprint': _hostFingerprint,
      }),
    );
  }

  static String _hex(Uint8List bytes) =>
      [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
