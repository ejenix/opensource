// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:io';

import 'package:ejenix_loader/loader.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Uri base;
  String? servedActiveId;
  int status = 200;

  setUp(() async {
    servedActiveId = '019f0000-0000-7000-8000-000000000001';
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((req) async {
      // Mimic the control plane's active-pointer route.
      if (req.uri.path == '/v1/apps/com.example.app/envs/production/active') {
        if (status != 200 || servedActiveId == null) {
          req.response.statusCode = status == 200 ? 404 : status;
          await req.response.close();
          return;
        }
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({'env': 'production', 'activeBundleId': servedActiveId}),
          );
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  ControlPlaneClient client() =>
      ControlPlaneClient(base: base, appId: 'com.example.app');

  test('resolves the active bundle id', () async {
    expect(await client().activeBundleId(), servedActiveId);
  });

  test('builds a download URL from base + app + id', () {
    final url = client().downloadUrl('abc');
    expect(url.path, '/v1/apps/com.example.app/bundles/abc.bundle');
    expect(url.host, '127.0.0.1');
  });

  test('preserves a base path prefix', () {
    final c = ControlPlaneClient(
      base: base.replace(path: '/ejenix'),
      appId: 'com.example.app',
    );
    expect(
      c.downloadUrl('abc').path,
      '/ejenix/v1/apps/com.example.app/bundles/abc.bundle',
    );
  });

  test('a 404 (no active bundle) resolves to null, not a throw', () async {
    servedActiveId = null;
    expect(await client().activeBundleId(), isNull);
  });

  test('an unreachable control plane resolves to null (fail-soft)', () async {
    final dead = ControlPlaneClient(
      base: Uri.parse('http://127.0.0.1:1'), // nothing listening
      appId: 'com.example.app',
      timeout: const Duration(milliseconds: 300),
    );
    expect(await dead.activeBundleId(), isNull);
  });

  test('a 500 resolves to null', () async {
    status = 500;
    expect(await client().activeBundleId(), isNull);
  });
}
