// Copyright (c) Ejenix authors. MIT license.

/// The self-hosted control plane.
///
/// Construct a [ControlPlane] over a [Store] and serve its `handler` with
/// [serve] (or any shelf adapter). The REST API is specified by the endpoint
/// list in the brief §6.8; storage is pluggable behind [Store].
library;

import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;

import 'src/control_plane.dart';

export 'src/auth.dart' show generateApiKey, hashApiKey;
export 'src/control_plane.dart' show ControlPlane;
export 'src/file_store.dart';
export 'src/model.dart';
export 'src/observability.dart' show Metrics;
export 'src/store.dart';

/// Binds [plane]'s handler to [address]:[port].
Future<HttpServer> serve(
  ControlPlane plane, {
  Object address = 'localhost',
  int port = 8080,
}) => shelf_io.serve(plane.handler, address, port);
