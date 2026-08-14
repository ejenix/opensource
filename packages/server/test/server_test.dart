// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_delta/delta.dart';
import 'package:ejenix_server/server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

String hex(List<int> b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

Module moduleReturning(int value) {
  final fn =
      (BytecodeBuilder()
            ..emitLoadInt(0, value)
            ..emitA(Op.ret, 0))
          .toProto(name: 'main', paramCount: 0, registerCount: 1);
  return Module(constants: ConstantPool(), functions: [fn], entryFunction: 0);
}

const metadata = BundleMetadata(
  targetAppId: 'com.example.app',
  targetFlutterVersion: '3.41.6',
  minSdk: '1.0.0',
);

void main() {
  const adminKey = 'admin-secret-token';
  final devSigner = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 3));
  final deliverySigner = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 9));

  late Handler handler;
  late Metrics metrics;

  setUp(() {
    metrics = Metrics();
    handler = ControlPlane(
      store: InMemoryStore(),
      adminApiKey: adminKey,
      deliverySigner: deliverySigner,
      metrics: metrics,
      random: Random(1),
    ).handler;
  });

  Future<Response> req(
    String method,
    String path, {
    String? token,
    Object? jsonBody,
    List<int>? body,
    Map<String, String> headers = const {},
  }) async {
    final h = {...headers};
    if (token != null) h['authorization'] = 'Bearer $token';
    Object? payload = body;
    if (jsonBody != null) {
      payload = jsonEncode(jsonBody);
      h['content-type'] = 'application/json';
    }
    return handler(
      Request(
        method,
        Uri.parse('http://localhost/$path'),
        headers: h,
        body: payload,
      ),
    );
  }

  Future<Map<String, Object?>> jsonOf(Response r) async =>
      jsonDecode(await r.readAsString()) as Map<String, Object?>;

  Future<Uint8List> bytesOf(Response r) async {
    final out = <int>[];
    await for (final chunk in r.read()) {
      out.addAll(chunk);
    }
    return Uint8List.fromList(out);
  }

  Bundle signBundle(int value, {int? id}) => Bundle.sign(
    module: moduleReturning(value),
    metadata: metadata,
    signer: devSigner,
    compilerVersion: '0.1.0',
    bundleId: id == null ? null : (Uint8List(16)..fillRange(0, 16, id)),
  );

  Future<String> createApp([String id = 'acme']) async {
    final r = await req(
      'POST',
      'v1/apps',
      token: adminKey,
      jsonBody: {
        'id': id,
        'name': 'Acme',
        'trustedKeys': [hex(devSigner.publicKey)],
      },
    );
    final body = await r.readAsString();
    expect(r.statusCode, 201, reason: body);
    return (jsonDecode(body) as Map)['apiKey'] as String;
  }

  Future<Uint8List> upload(String app, String key, Bundle bundle) async {
    final r = await req(
      'POST',
      'v1/apps/$app/bundles',
      token: key,
      body: bundle.encode(),
    );
    expect(r.statusCode, 201, reason: await r.readAsString());
    return bundle.bundleId;
  }

  group('health and ops', () {
    test('health, ready, and metrics', () async {
      expect((await req('GET', 'v1/health')).statusCode, 200);
      expect((await req('GET', 'v1/ready')).statusCode, 200);
      final m = await req('GET', 'metrics');
      expect(m.statusCode, 200);
      expect(await m.readAsString(), contains('ejenix_requests_total'));
    });

    test('every response carries a request id', () async {
      final r = await req('GET', 'v1/health');
      expect(r.headers['X-Request-Id'], isNotNull);
    });
  });

  group('apps', () {
    test('create requires the admin key', () async {
      final r = await req(
        'POST',
        'v1/apps',
        jsonBody: {
          'id': 'x',
          'trustedKeys': [hex(devSigner.publicKey)],
        },
      );
      expect(r.statusCode, 401);
    });

    test('create returns an api key once', () async {
      final key = await createApp();
      expect(key, isNotEmpty);
    });

    test('duplicate app id is a conflict', () async {
      await createApp();
      final r = await req(
        'POST',
        'v1/apps',
        token: adminKey,
        jsonBody: {
          'id': 'acme',
          'trustedKeys': [hex(devSigner.publicKey)],
        },
      );
      expect(r.statusCode, 409);
    });

    test('an invalid slug is rejected', () async {
      final r = await req(
        'POST',
        'v1/apps',
        token: adminKey,
        jsonBody: {
          'id': 'Not A Slug',
          'trustedKeys': [hex(devSigner.publicKey)],
        },
      );
      expect(r.statusCode, 400);
    });

    test('a missing trustedKey is rejected', () async {
      final r = await req(
        'POST',
        'v1/apps',
        token: adminKey,
        jsonBody: {'id': 'acme'},
      );
      expect(r.statusCode, 400);
    });

    test('listing apps requires admin and hides key hashes', () async {
      await createApp();
      expect((await req('GET', 'v1/apps')).statusCode, 401);
      final r = await req('GET', 'v1/apps', token: adminKey);
      final apps = (await jsonOf(r))['apps'] as List;
      expect(apps.single, isNot(contains('apiKeyHash')));
    });
  });

  group('bundles', () {
    test('upload requires the app key', () async {
      await createApp();
      final r = await req(
        'POST',
        'v1/apps/acme/bundles',
        body: signBundle(1).encode(),
      );
      expect(r.statusCode, 401);
    });

    test('a verified bundle uploads, downloads, and 304s', () async {
      final key = await createApp();
      final bundle = signBundle(1, id: 1);
      await upload('acme', key, bundle);

      final download = await req(
        'GET',
        'v1/apps/acme/bundles/${hex(bundle.bundleId)}.bundle',
      );
      expect(download.statusCode, 200);
      expect(await bytesOf(download), bundle.encode());

      final etag = download.headers['etag'];
      final conditional = await req(
        'GET',
        'v1/apps/acme/bundles/${hex(bundle.bundleId)}.bundle',
        headers: {'if-none-match': etag!},
      );
      expect(conditional.statusCode, 304);
    });

    test('a bundle signed by an untrusted key is rejected', () async {
      final key = await createApp();
      final foreign = Signer.generate();
      final bundle = Bundle.sign(
        module: moduleReturning(1),
        metadata: metadata,
        signer: foreign,
        compilerVersion: '0.1.0',
      );
      final r = await req(
        'POST',
        'v1/apps/acme/bundles',
        token: key,
        body: bundle.encode(),
      );
      expect(r.statusCode, 400);
    });

    test('malformed upload is a 400', () async {
      final key = await createApp();
      final r = await req(
        'POST',
        'v1/apps/acme/bundles',
        token: key,
        body: [0, 1, 2, 3],
      );
      expect(r.statusCode, 400);
    });

    test('downloading an unknown bundle is a 404', () async {
      await createApp();
      final r = await req('GET', 'v1/apps/acme/bundles/${'0' * 32}.bundle');
      expect(r.statusCode, 404);
    });
  });

  group('environments', () {
    test('set-active promotes and get-active reflects it', () async {
      final key = await createApp();
      final bundle = signBundle(1, id: 1);
      await upload('acme', key, bundle);

      final promote = await req(
        'POST',
        'v1/apps/acme/envs/production/active',
        token: key,
        jsonBody: {'bundleId': formatUuid(bundle.bundleId)},
      );
      expect(promote.statusCode, 200);

      final active = await req('GET', 'v1/apps/acme/envs/production/active');
      expect(
        (await jsonOf(active))['activeBundleId'],
        formatUuid(bundle.bundleId),
      );
      expect(metrics.render(), contains('ejenix_activations_total'));
    });

    test('promoting an unknown bundle is a 404', () async {
      final key = await createApp();
      final r = await req(
        'POST',
        'v1/apps/acme/envs/production/active',
        token: key,
        jsonBody: {'bundleId': formatUuid(Uint8List(16))},
      );
      expect(r.statusCode, 404);
    });

    test('get-active with none is a 404', () async {
      await createApp();
      final r = await req('GET', 'v1/apps/acme/envs/dev/active');
      expect(r.statusCode, 404);
    });

    test('rollback reverts to the previously active bundle', () async {
      final key = await createApp();
      final b1 = signBundle(1, id: 1);
      final b2 = signBundle(2, id: 2);
      await upload('acme', key, b1);
      await upload('acme', key, b2);
      await req(
        'POST',
        'v1/apps/acme/envs/prod/active',
        token: key,
        jsonBody: {'bundleId': formatUuid(b1.bundleId)},
      );
      await req(
        'POST',
        'v1/apps/acme/envs/prod/active',
        token: key,
        jsonBody: {'bundleId': formatUuid(b2.bundleId)},
      );

      final rb = await req(
        'POST',
        'v1/apps/acme/envs/prod/rollback',
        token: key,
      );
      expect(rb.statusCode, 200);
      final active = await req('GET', 'v1/apps/acme/envs/prod/active');
      expect((await jsonOf(active))['activeBundleId'], formatUuid(b1.bundleId));
    });

    test('rollback with no previous is a 409', () async {
      final key = await createApp();
      final b1 = signBundle(1, id: 1);
      await upload('acme', key, b1);
      await req(
        'POST',
        'v1/apps/acme/envs/prod/active',
        token: key,
        jsonBody: {'bundleId': formatUuid(b1.bundleId)},
      );
      final rb = await req(
        'POST',
        'v1/apps/acme/envs/prod/rollback',
        token: key,
      );
      expect(rb.statusCode, 409);
    });
  });

  group('deltas', () {
    test('a server delta reconstructs and verifies end-to-end', () async {
      final key = await createApp();
      final base = signBundle(1, id: 1);
      final target = signBundle(2, id: 2);
      await upload('acme', key, base);
      await upload('acme', key, target);

      final r = await req(
        'POST',
        'v1/apps/acme/deltas',
        token: key,
        jsonBody: {
          'base': formatUuid(base.bundleId),
          'target': formatUuid(target.bundleId),
        },
      );
      expect(r.statusCode, 200);
      final deltaBundle = Bundle.decode(await bytesOf(r));

      // Signed by the server's delivery key.
      expect(
        deltaBundle
            .verify(anchors: TrustAnchors.single(deliverySigner.publicKey))
            .isValid,
        isTrue,
      );
      // Applying reconstructs the developer-signed target.
      final reconstructed = DeltaBundle.apply(deltaBundle, base.encode());
      expect(reconstructed, target.encode());
    });

    test('a delta with an unknown base is a 404', () async {
      final key = await createApp();
      final target = signBundle(2, id: 2);
      await upload('acme', key, target);
      final r = await req(
        'POST',
        'v1/apps/acme/deltas',
        token: key,
        jsonBody: {
          'base': formatUuid(Uint8List(16)..fillRange(0, 16, 7)),
          'target': formatUuid(target.bundleId),
        },
      );
      expect(r.statusCode, 404);
    });
  });

  group('errors', () {
    test('an unknown app is a 404', () async {
      final r = await req('GET', 'v1/apps/ghost/envs');
      expect(r.statusCode, 404);
    });
  });

  group('dashboard', () {
    test('serves the operator page at / and /dashboard', () async {
      for (final path in ['', 'dashboard']) {
        final r = await req('GET', path);
        expect(r.statusCode, 200);
        expect(r.headers['content-type'], contains('text/html'));
        final html = await r.readAsString();
        expect(html, contains('Ejenix'));
        expect(html, contains('control plane'));

        // The operator affordances, by the endpoint each one drives rather than
        // by its label — copy is free to change, the wiring is not.
        expect(html, contains('Create app')); // POST /v1/apps
        expect(html, contains('data-promote')); // POST …/envs/<env>/active
        expect(html, contains('data-rollback')); // POST …/envs/<env>/rollback
        expect(html, contains('/v1/apps/')); // list envs + bundles
        expect(html, contains('/v1/ready')); // health indicator

        // Self-contained: no build step, no external asset can fail to load.
        expect(html, isNot(contains('src="http')));
        expect(html, isNot(contains('href="http')));
      }
    });
  });

  group('admin override', () {
    // The admin key manages any app — the dashboard relies on this to promote
    // and roll back without holding each app's individual key.
    test(
      'the admin key can list bundles and promote, using no app key',
      () async {
        await createApp('beta');
        final id = await upload(
          'beta',
          adminKey, // upload with the ADMIN key, not the app key
          signBundle(1),
        );

        final list = await req('GET', 'v1/apps/beta/bundles', token: adminKey);
        expect(list.statusCode, 200);

        final promote = await req(
          'POST',
          'v1/apps/beta/envs/production/active',
          token: adminKey,
          jsonBody: {'bundleId': formatUuid(id)},
        );
        expect(promote.statusCode, 200, reason: await promote.readAsString());
      },
    );
  });
}
