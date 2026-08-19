// Copyright (c) Ejenix authors. MIT license.

/// Channels and staged rollout, which exist to answer one question: which
/// devices get which bundle.
///
/// Before channels, the live bundle was keyed `(appId, env)`. An app with five
/// patchable screens therefore had to register five *app ids* — the dashboard
/// showed one product as five unrelated apps, and `--app-id` stopped meaning
/// the app. Channels add the missing dimension without taking anything away:
/// every record written before them is the `default` channel, and the old
/// routes still resolve to it.
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

String _hex(List<int> b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

Module _mod(int v) {
  final f =
      (BytecodeBuilder()
            ..emitLoadInt(0, v)
            ..emitA(Op.ret, 0))
          .toProto(name: 'main', paramCount: 0, registerCount: 1);
  return Module(constants: ConstantPool(), functions: [f], entryFunction: 0);
}

const _meta = BundleMetadata(
  targetAppId: 'com.example.app',
  targetFlutterVersion: '3.41.6',
  minSdk: '1.0.0',
);

void main() {
  const adminKey = 'admin-secret-token';
  final signer = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 3));

  Bundle bundle(int v) => Bundle.sign(
    module: _mod(v),
    metadata: _meta,
    signer: signer,
    compilerVersion: '0.1.0',
    bundleId: Uint8List(16)..fillRange(0, 16, v),
  );
  String uuidOf(int v) {
    final h = _hex(Uint8List(16)..fillRange(0, 16, v));
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
        '-${h.substring(16, 20)}-${h.substring(20)}';
  }

  late Directory root;
  late Handler handler;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ejenix_channels');
    handler = ControlPlane(
      store: FileStore(root),
      adminApiKey: adminKey,
      deliverySigner: Signer.generate(),
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
    final h = <String, String>{};
    if (token != null) h['authorization'] = 'Bearer $token';
    Object? payload = body;
    if (jsonBody != null) {
      payload = jsonEncode(jsonBody);
      h['content-type'] = 'application/json';
    }
    return handler(
      Request(method, Uri.parse('http://x/$path'), headers: h, body: payload),
    );
  }

  Future<Map<String, Object?>> bodyOf(Response r) async =>
      jsonDecode(await r.readAsString()) as Map<String, Object?>;

  Future<void> setup(List<int> versions) async {
    final r = await req(
      'POST',
      'v1/apps',
      token: adminKey,
      jsonBody: {
        'id': 'acme',
        'name': 'Acme',
        'trustedKeys': [_hex(signer.publicKey)],
      },
    );
    expect(r.statusCode, 201, reason: await r.readAsString());
    for (final v in versions) {
      final u = await req(
        'POST',
        'v1/apps/acme/bundles',
        token: adminKey,
        body: bundle(v).encode(),
      );
      expect(u.statusCode, 201, reason: await u.readAsString());
    }
  }

  group('channels are independent surfaces of one app', () {
    test('promoting one channel does not disturb another', () async {
      // The whole reason channels exist. Under the old key these two promotes
      // fought over a single slot and the second silently unpublished the first.
      await setup([1, 2]);
      await req(
        'POST',
        'v1/apps/acme/channels/home/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(1)},
      );
      await req(
        'POST',
        'v1/apps/acme/channels/checkout/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(2)},
      );

      final home = await bodyOf(
        await req('GET', 'v1/apps/acme/channels/home/envs/production/active'),
      );
      final checkout = await bodyOf(
        await req(
          'GET',
          'v1/apps/acme/channels/checkout/envs/production/active',
        ),
      );

      expect(home['activeBundleId'], uuidOf(1));
      expect(checkout['activeBundleId'], uuidOf(2));
    });

    test('the same channel name in two envs is two records', () async {
      await setup([1, 2]);
      await req(
        'POST',
        'v1/apps/acme/channels/home/envs/staging/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(1)},
      );
      await req(
        'POST',
        'v1/apps/acme/channels/home/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(2)},
      );

      expect(
        (await bodyOf(
          await req('GET', 'v1/apps/acme/channels/home/envs/staging/active'),
        ))['activeBundleId'],
        uuidOf(1),
      );
      expect(
        (await bodyOf(
          await req('GET', 'v1/apps/acme/channels/home/envs/production/active'),
        ))['activeBundleId'],
        uuidOf(2),
      );
    });

    test('a traversing channel name is refused like any other slug', () async {
      await setup([1]);
      final r = await req(
        'GET',
        'v1/apps/acme/channels/%2e%2e%2f%2e%2e%2fx/envs/production/active',
      );
      expect(r.statusCode, 400);
      expect(await r.readAsString(), contains('invalid channel name'));
    });
  });

  group('the pre-channel routes still work', () {
    test('the old route is the default channel, both ways', () async {
      // Deployed devices call the old path. If this breaks, every install in
      // the field stops receiving updates.
      await setup([1]);
      await req(
        'POST',
        'v1/apps/acme/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(1)},
      );

      final viaOld = await bodyOf(
        await req('GET', 'v1/apps/acme/envs/production/active'),
      );
      final viaNew = await bodyOf(
        await req(
          'GET',
          'v1/apps/acme/channels/default/envs/production/active',
        ),
      );

      expect(viaOld['activeBundleId'], uuidOf(1));
      expect(
        viaNew['activeBundleId'],
        uuidOf(1),
        reason: 'the old route must be exactly the default channel',
      );
      expect(viaOld['channel'], 'default');
    });

    test('the default channel does not collide with a named one', () async {
      await setup([1, 2]);
      await req(
        'POST',
        'v1/apps/acme/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(1)},
      );
      await req(
        'POST',
        'v1/apps/acme/channels/home/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(2)},
      );

      expect(
        (await bodyOf(
          await req('GET', 'v1/apps/acme/envs/production/active'),
        ))['activeBundleId'],
        uuidOf(1),
      );
    });
  });

  group('staged rollout', () {
    test('a promote defaults to the whole fleet', () async {
      await setup([1]);
      await req(
        'POST',
        'v1/apps/acme/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(1)},
      );
      final b = await bodyOf(
        await req('GET', 'v1/apps/acme/envs/production/active'),
      );
      expect(b['rolloutPercent'], 100);
    });

    test('a percentage is stored and published to devices', () async {
      await setup([1]);
      await req(
        'POST',
        'v1/apps/acme/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(1), 'rolloutPercent': 5},
      );
      final b = await bodyOf(
        await req('GET', 'v1/apps/acme/envs/production/active'),
      );
      expect(b['rolloutPercent'], 5);
      expect(b['rolloutSalt'], isA<String>());
      expect((b['rolloutSalt']! as String).isNotEmpty, isTrue);
    });

    test(
      'widening keeps the salt, so it only ever admits more devices',
      () async {
        // The property that makes staged rollout safe. A new salt would reshuffle
        // every bucket and could drop a device that already had the patch.
        await setup([1]);
        await req(
          'POST',
          'v1/apps/acme/envs/production/active',
          token: adminKey,
          jsonBody: {'bundleId': uuidOf(1), 'rolloutPercent': 5},
        );
        final at5 = await bodyOf(
          await req('GET', 'v1/apps/acme/envs/production/active'),
        );

        await req(
          'POST',
          'v1/apps/acme/envs/production/active',
          token: adminKey,
          jsonBody: {'bundleId': uuidOf(1), 'rolloutPercent': 50},
        );
        final at50 = await bodyOf(
          await req('GET', 'v1/apps/acme/envs/production/active'),
        );

        expect(at50['rolloutSalt'], at5['rolloutSalt']);
        expect(at50['rolloutPercent'], 50);
      },
    );

    test('widening does not move what a rollback would restore', () async {
      // Widening is not a new release. If it shifted previousBundleId, a
      // rollback during a staged rollout would restore the canary instead of
      // the last good build.
      await setup([1, 2]);
      await req(
        'POST',
        'v1/apps/acme/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(1)},
      );
      await req(
        'POST',
        'v1/apps/acme/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(2), 'rolloutPercent': 5},
      );
      await req(
        'POST',
        'v1/apps/acme/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(2), 'rolloutPercent': 25},
      );

      final rb = await bodyOf(
        await req(
          'POST',
          'v1/apps/acme/envs/production/rollback',
          token: adminKey,
        ),
      );
      expect(
        rb['activeBundleId'],
        uuidOf(1),
        reason: 'rollback must restore the last good build, not the canary',
      );
    });

    test('a rollback goes to the whole fleet', () async {
      await setup([1, 2]);
      await req(
        'POST',
        'v1/apps/acme/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(1)},
      );
      await req(
        'POST',
        'v1/apps/acme/envs/production/active',
        token: adminKey,
        jsonBody: {'bundleId': uuidOf(2), 'rolloutPercent': 5},
      );

      final rb = await bodyOf(
        await req(
          'POST',
          'v1/apps/acme/envs/production/rollback',
          token: adminKey,
        ),
      );
      expect(
        rb['rolloutPercent'],
        100,
        reason: 'a partial rollback would split the fleet mid-incident',
      );
    });

    test('an out-of-range percentage is rejected', () async {
      await setup([1]);
      for (final bad in [-1, 101, 'half']) {
        final r = await req(
          'POST',
          'v1/apps/acme/envs/production/active',
          token: adminKey,
          jsonBody: {'bundleId': uuidOf(1), 'rolloutPercent': bad},
        );
        expect(r.statusCode, 400, reason: 'rolloutPercent $bad was accepted');
      }
    });
  });
}
