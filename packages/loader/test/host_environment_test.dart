// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_loader/loader.dart';
import 'package:test/test.dart';

void main() {
  const host = HostEnvironment(
    appId: 'com.example.app',
    flutterVersion: '3.41.6',
    sdkVersion: '1.2.0',
  );

  BundleMetadata meta({
    String app = 'com.example.app',
    String minSdk = '1.0.0',
  }) => BundleMetadata(
    targetAppId: app,
    targetFlutterVersion: '3.41.6',
    minSdk: minSdk,
  );

  test('compatible when app matches and SDK is new enough', () {
    expect(host.isCompatible(meta()).isCompatible, isTrue);
  });

  test('incompatible app id is rejected with a reason', () {
    final result = host.isCompatible(meta(app: 'com.other.app'));
    expect(result.isCompatible, isFalse);
    expect(result.reason, contains('com.other.app'));
  });

  test('SDK below the bundle minimum is rejected', () {
    final result = host.isCompatible(meta(minSdk: '2.0.0'));
    expect(result.isCompatible, isFalse);
    expect(result.reason, contains('below'));
  });

  test('semver comparison is numeric, not lexical', () {
    const older = HostEnvironment(
      appId: 'com.example.app',
      flutterVersion: '3.41.6',
      sdkVersion: '1.9.0',
    );
    // 1.9.0 >= 1.10.0 must be false (numeric), even though "1.9" > "1.10"
    // lexically.
    expect(older.isCompatible(meta(minSdk: '1.10.0')).isCompatible, isFalse);
    const newer = HostEnvironment(
      appId: 'com.example.app',
      flutterVersion: '3.41.6',
      sdkVersion: '1.10.0',
    );
    expect(newer.isCompatible(meta(minSdk: '1.9.0')).isCompatible, isTrue);
  });
}
