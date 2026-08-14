// Copyright (c) Ejenix authors. MIT license.

/// App ids and environment names come straight off the URL, and the file store
/// interpolates both into paths (`envs/<app>/<env>.json`). Unchecked, a `..`
/// segment escapes the app's own directory.
///
/// The reach is wider than an operator footgun. `_authorizeApp` accepts an
/// app's *own* key, not only the admin key, so one tenant can address another
/// tenant's environment file; and `GET .../envs/<env>/active` is
/// unauthenticated, so the read side needs no token at all.
///
/// Only one attack form matters, and these tests use only that one. Dart's
/// `Uri.parse` collapses dot segments during parsing, so a literal
/// `envs/../../x/active` never arrives as a traversal — it is rewritten to
/// `/v1/apps/x/active` before any handler sees it. Percent-encoded `%2e%2e%2f`
/// is *not* collapsed: it survives parsing and is decoded into the route
/// parameter, handing the handler a segment whose value is `../../x`. Testing
/// the bare form would pass with or without the guard and prove nothing.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_server/server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// `..%2F..%2Fescaped` — the encoded traversal, which survives `Uri.parse`.
const _encodedTraversal = '%2e%2e%2f%2e%2e%2fescaped';

String _hex(List<int> b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

Module _moduleReturning(int value) {
  final fn =
      (BytecodeBuilder()
            ..emitLoadInt(0, value)
            ..emitA(Op.ret, 0))
          .toProto(name: 'main', paramCount: 0, registerCount: 1);
  return Module(constants: ConstantPool(), functions: [fn], entryFunction: 0);
}

const _metadata = BundleMetadata(
  targetAppId: 'com.example.app',
  targetFlutterVersion: '3.41.6',
  minSdk: '1.0.0',
);

void main() {
  const adminKey = 'admin-secret-token';
  final devSigner = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 3));
  final deliverySigner = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 9));

  /// A bundle whose id is all 0x01, so its uuid is predictable.
  final bundle = Bundle.sign(
    module: _moduleReturning(1),
    metadata: _metadata,
    signer: devSigner,
    compilerVersion: '0.1.0',
    bundleId: Uint8List(16)..fillRange(0, 16, 1),
  );
  const bundleUuid = '01010101-0101-0101-0101-010101010101';

  late Directory root;
  late Handler handler;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ejenix_pathsafety');
    handler = ControlPlane(
      store: FileStore(root),
      adminApiKey: adminKey,
      deliverySigner: deliverySigner,
      metrics: Metrics(),
      random: Random(1),
    ).handler;
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<Response> req(
    String method,
    String path, {
    String? token,
    Object? jsonBody,
    List<int>? body,
  }) async {
    final headers = <String, String>{};
    if (token != null) headers['authorization'] = 'Bearer $token';
    Object? payload = body;
    if (jsonBody != null) {
      payload = jsonEncode(jsonBody);
      headers['content-type'] = 'application/json';
    }
    return handler(
      Request(
        method,
        Uri.parse('http://localhost/$path'),
        headers: headers,
        body: payload,
      ),
    );
  }

  Future<String> createApp(String id) async {
    final r = await req(
      'POST',
      'v1/apps',
      token: adminKey,
      jsonBody: {
        'id': id,
        'name': 'App $id',
        'trustedKeys': [_hex(devSigner.publicKey)],
      },
    );
    final body = await r.readAsString();
    expect(r.statusCode, 201, reason: body);
    return (jsonDecode(body) as Map)['apiKey'] as String;
  }

  /// Uploads [bundle] so `_setActive` gets past its bundle-exists check and
  /// actually reaches the write. Without this the route 404s early and a
  /// traversal test passes for the wrong reason.
  Future<String> appWithBundle(String id) async {
    final key = await createApp(id);
    final r = await req(
      'POST',
      'v1/apps/$id/bundles',
      token: key,
      body: bundle.encode(),
    );
    expect(r.statusCode, anyOf(200, 201), reason: await r.readAsString());
    return key;
  }

  Set<String> filesUnderRoot() => root
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path.substring(root.path.length))
      .toSet();

  test(
    'an encoded traversal cannot write outside the app it authenticated as',
    () async {
      final acmeKey = await appWithBundle('acme');
      await createApp('victim');
      final before = filesUnderRoot();

      final r = await req(
        'POST',
        'v1/apps/acme/envs/$_encodedTraversal/active',
        token: acmeKey,
        jsonBody: {'bundleId': bundleUuid},
      );

      // Specifically 400 — not the 404 an early bundle check would give, which
      // would mask a missing guard.
      final body = await r.readAsString();
      expect(r.statusCode, 400, reason: body);
      expect(body, contains('invalid environment name'));
      expect(
        filesUnderRoot(),
        before,
        reason: 'the rejected write must not have touched the store',
      );
    },
  );

  test(
    'an encoded traversal cannot roll back another app\'s environment',
    () async {
      final acmeKey = await appWithBundle('acme');
      final before = filesUnderRoot();

      final r = await req(
        'POST',
        'v1/apps/acme/envs/$_encodedTraversal/rollback',
        token: acmeKey,
      );

      expect(r.statusCode, 400, reason: await r.readAsString());
      expect(filesUnderRoot(), before);
    },
  );

  test(
    'an encoded traversal is rejected on the unauthenticated read',
    () async {
      await createApp('acme');

      final r = await req('GET', 'v1/apps/acme/envs/$_encodedTraversal/active');

      final body = await r.readAsString();
      expect(r.statusCode, 400, reason: body);
      expect(body, contains('invalid environment name'));
    },
  );

  test('an encoded traversal in the app id is rejected too', () async {
    final r = await req(
      'GET',
      'v1/apps/$_encodedTraversal/envs/production/active',
    );

    final body = await r.readAsString();
    expect(r.statusCode, 400, reason: body);
    expect(body, contains('invalid app id'));
    expect(filesUnderRoot(), isEmpty);
  });

  test(
    'the guard rejects rather than mangles: real promotes still work',
    () async {
      // The failure mode to avoid is a fix that also breaks legitimate names —
      // that would be a worse outage than the hole it closes.
      final key = await appWithBundle('acme');

      for (final good in ['production', 'staging-2', 'qa.eu', 'a']) {
        final r = await req(
          'POST',
          'v1/apps/acme/envs/$good/active',
          token: key,
          jsonBody: {'bundleId': bundleUuid},
        );
        expect(r.statusCode, 200, reason: '$good was rejected');
      }

      final read = await req('GET', 'v1/apps/acme/envs/production/active');
      expect(read.statusCode, 200);
    },
  );
}
