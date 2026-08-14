// Copyright (c) Ejenix authors. MIT license.

/// The device-side loader and verifier.
///
/// [Loader] fetches a bundle from the configured control plane, verifies it in
/// strict order, checks host compatibility, applies deltas, and stages the
/// result. [BundleStore] owns the on-disk lifecycle — staging, atomic
/// activation, bounded history, and the crash-loop counter that drives
/// automatic rollback. The loader's only network egress is its [BundleFetcher];
/// it performs no telemetry.
library;

export 'src/bundle_store.dart';
export 'src/control_plane_client.dart';
export 'src/fetcher.dart';
export 'src/host_environment.dart';
export 'src/loader.dart';
