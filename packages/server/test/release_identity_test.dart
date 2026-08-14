// Copyright (c) Ejenix authors. MIT license.

/// A bundle id names a release. It must never name two different sets of bytes.
///
/// The failure this prevents is the quiet kind. The store used to overwrite a
/// blob whose id already existed, and the download ETag was derived from that
/// id — so after a re-upload under the same id, devices holding the old bytes
/// revalidated with `If-None-Match`, were told 304 Not Modified, and kept
/// running the old code, while devices fetching fresh received the new code
/// under the identical id and ETag. The fleet splits, and the control plane
/// reports one active release the entire time. Nothing logs an error, and no
/// dashboard column disagrees.
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

  /// Two *validly signed* bundles that share an id but differ in content —
  /// exactly what a compromised or careless release process produces.
  Bundle signed(int value) => Bundle.sign(
    module: _moduleReturning(value),
    metadata: _metadata,
    signer: devSigner,
    compilerVersion: '0.1.0',
    bundleId: Uint8List(16)..fillRange(0, 16, 1),
  );
  const sharedUuid = '01010101-0101-0101-0101-010101010101';

  late Directory root;
  late Handler handler;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ejenix_identity');
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

  Future<String> createApp() async {
    final r = await req(
      'POST',
      'v1/apps',
      token: adminKey,
      jsonBody: {
        'id': 'acme',
        'name': 'Acme',
        'trustedKeys': [_hex(devSigner.publicKey)],
      },
    );
    final body = await r.readAsString();
    expect(r.statusCode, 201, reason: body);
    return (jsonDecode(body) as Map)['apiKey'] as String;
  }

  test('re-uploading identical bytes under the same id is accepted', () async {
    // Idempotent republish must keep working — CI re-running a publish step is
    // normal, and failing it would be a worse regression than the hole.
    final key = await createApp();
    final bundle = signed(1);
    for (var i = 0; i < 2; i++) {
      final r = await req(
        'POST',
        'v1/apps/acme/bundles',
        token: key,
        body: bundle.encode(),
      );
      expect(r.statusCode, 201, reason: 'upload $i: ${await r.readAsString()}');
    }
  });

  test('re-uploading DIFFERENT bytes under the same id is refused', () async {
    final key = await createApp();
    await req(
      'POST',
      'v1/apps/acme/bundles',
      token: key,
      body: signed(1).encode(),
    );

    final r = await req(
      'POST',
      'v1/apps/acme/bundles',
      token: key,
      body: signed(2).encode(),
    );

    final body = await r.readAsString();
    expect(r.statusCode, 409, reason: body);
    expect(body, contains('different'));
  });

  test('the refused upload does not replace the stored bytes', () async {
    // The status code alone is not the guarantee — the bytes on disk are.
    final key = await createApp();
    final original = signed(1).encode();
    await req('POST', 'v1/apps/acme/bundles', token: key, body: original);
    await req(
      'POST',
      'v1/apps/acme/bundles',
      token: key,
      body: signed(2).encode(),
    );

    final download = await req(
      'GET',
      'v1/apps/acme/bundles/$sharedUuid.bundle',
    );
    expect(download.statusCode, 200);
    final served = <int>[];
    await for (final chunk in download.read()) {
      served.addAll(chunk);
    }
    expect(served, original, reason: 'the first release must still be served');
  });

  test('the ETag is derived from content, not from the bundle id', () async {
    final key = await createApp();
    await req(
      'POST',
      'v1/apps/acme/bundles',
      token: key,
      body: signed(1).encode(),
    );

    final r = await req('GET', 'v1/apps/acme/bundles/$sharedUuid.bundle');
    final etag = r.headers['etag']!;

    // An id-derived ETag was literally the uuid hex; a content digest is not.
    expect(etag, isNot(contains('01010101010101010101010101010101')));
    expect(etag.replaceAll('"', '').length, 64, reason: 'sha-256 hex');
  });

  test('conditional revalidation still works with the content ETag', () async {
    // Caching must keep functioning — the point is a correct validator, not no
    // validator.
    final key = await createApp();
    await req(
      'POST',
      'v1/apps/acme/bundles',
      token: key,
      body: signed(1).encode(),
    );

    final first = await req('GET', 'v1/apps/acme/bundles/$sharedUuid.bundle');
    final etag = first.headers['etag']!;

    final second = await req(
      'GET',
      'v1/apps/acme/bundles/$sharedUuid.bundle',
      headers: {'if-none-match': etag},
    );
    expect(second.statusCode, 304);
  });
}
