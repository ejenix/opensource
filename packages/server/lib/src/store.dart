// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'model.dart';

/// Persistence for the control plane: apps, bundle blobs, environments, and the
/// per-app environment pointers.
///
/// The interface is the seam the brief calls for (§6.8): the default is
/// [InMemoryStore] (and the file-backed store), and a SQLite or Postgres
/// adapter can be dropped in without touching the API. All methods are async so
/// a database-backed implementation fits.
abstract interface class Store {
  Future<App?> getApp(String id);
  Future<List<App>> listApps();
  Future<void> putApp(App app);

  Future<void> putBundle(String appId, Uint8List bundleId, Uint8List bytes);
  Future<Uint8List?> getBundle(String appId, Uint8List bundleId);
  Future<void> putBundleRef(String appId, BundleRef ref);
  Future<List<BundleRef>> listBundleRefs(String appId);

  Future<Env?> getEnv(String appId, String name);
  Future<List<Env>> listEnvs(String appId);
  Future<void> putEnv(Env env);

  /// Whether the backing store is reachable (readiness).
  Future<bool> isHealthy();
}

/// A non-persistent [Store] for tests and ephemeral deployments.
class InMemoryStore implements Store {
  final Map<String, App> _apps = {};
  final Map<String, Uint8List> _blobs = {}; // "app/hex" -> bytes
  final Map<String, List<BundleRef>> _refs = {};
  final Map<String, Env> _envs = {}; // "app/name" -> env

  @override
  Future<App?> getApp(String id) async => _apps[id];

  @override
  Future<List<App>> listApps() async => _apps.values.toList();

  @override
  Future<void> putApp(App app) async => _apps[app.id] = app;

  @override
  Future<void> putBundle(
    String appId,
    Uint8List bundleId,
    Uint8List bytes,
  ) async {
    _blobs['$appId/${_hex(bundleId)}'] = bytes;
  }

  @override
  Future<Uint8List?> getBundle(String appId, Uint8List bundleId) async =>
      _blobs['$appId/${_hex(bundleId)}'];

  @override
  Future<void> putBundleRef(String appId, BundleRef ref) async =>
      (_refs[appId] ??= []).add(ref);

  @override
  Future<List<BundleRef>> listBundleRefs(String appId) async =>
      List.of(_refs[appId] ?? const []);

  @override
  Future<Env?> getEnv(String appId, String name) async => _envs['$appId/$name'];

  @override
  Future<List<Env>> listEnvs(String appId) async =>
      _envs.values.where((e) => e.appId == appId).toList();

  @override
  Future<void> putEnv(Env env) async => _envs['${env.appId}/${env.name}'] = env;

  @override
  Future<bool> isHealthy() async => true;
}

String _hex(Uint8List b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
