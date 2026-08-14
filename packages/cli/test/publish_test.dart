// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_cli/cli.dart';
import 'package:ejenix_server/server.dart';
import 'package:test/test.dart';

typedef CliResult = ({int code, String out, String err});

Future<CliResult> runCli(List<String> args) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final runner = EjenixRunner(out: out, err: err, isOutputTerminal: false);
  int code;
  try {
    code = await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    err.writeln(e);
    code = 64;
  }
  return (code: code, out: out.toString(), err: err.toString());
}

void main() {
  late Directory dir;
  late HttpServer server;
  late String baseUrl;
  String p(String name) => '${dir.path}/$name';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ejenix_publish_test');
    final plane = ControlPlane(
      store: InMemoryStore(),
      adminApiKey: 'admin-token',
      deliverySigner: Signer.generate(),
      random: Random(7),
    );
    server = await serve(plane, address: 'localhost', port: 0);
    baseUrl = 'http://localhost:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  Future<String> createApp(String id, String publicKeyHex) async {
    final client = HttpClient();
    final request = await client.postUrl(Uri.parse('$baseUrl/v1/apps'));
    request.headers
      ..set('authorization', 'Bearer admin-token')
      ..contentType = ContentType.json;
    request.add(
      utf8.encode(
        jsonEncode({
          'id': id,
          'trustedKeys': [publicKeyHex],
        }),
      ),
    );
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    client.close();
    return jsonDecode(body)['apiKey'] as String;
  }

  Future<Map<String, Object?>> getJson(String path) async {
    final client = HttpClient();
    final response = await (await client.getUrl(
      Uri.parse('$baseUrl$path'),
    )).close();
    final body = await utf8.decodeStream(response);
    client.close();
    return jsonDecode(body) as Map<String, Object?>;
  }

  Future<({String appKey, String bundleId})> compileAndPublish(
    String source,
    String bundleFile,
  ) async {
    await runCli(['keygen', '-o', p('signing.key')]);
    final pubHex = File('${p('signing.key')}.pub').readAsStringSync().trim();
    final appKey = await createApp('acme', pubHex);

    File(p('patch.dart')).writeAsStringSync(source);
    final compile = await runCli([
      'compile',
      p('patch.dart'),
      '-o',
      p(bundleFile),
      '--signing-key',
      p('signing.key'),
      '--app-id',
      'acme',
    ]);
    expect(compile.code, 0, reason: compile.err);

    final publish = await runCli([
      '--json',
      'publish',
      p(bundleFile),
      '--server',
      baseUrl,
      '--app',
      'acme',
      '--token',
      appKey,
    ]);
    expect(publish.code, 0, reason: publish.err);
    return (
      appKey: appKey,
      bundleId: jsonDecode(publish.out)['bundleId'] as String,
    );
  }

  test('publish then promote makes a bundle active on the server', () async {
    final r = await compileAndPublish('int main() => 1;', 'b1.bundle');

    final promote = await runCli([
      'promote',
      r.bundleId,
      '--env',
      'production',
      '--server',
      baseUrl,
      '--app',
      'acme',
      '--token',
      r.appKey,
    ]);
    expect(promote.code, 0, reason: promote.err);

    final active = await getJson('/v1/apps/acme/envs/production/active');
    expect(active['activeBundleId'], r.bundleId);
  });

  test('rollback reverts the active bundle on the server', () async {
    final first = await compileAndPublish('int main() => 1;', 'b1.bundle');
    await runCli([
      'promote',
      first.bundleId,
      '--env',
      'production',
      '--server',
      baseUrl,
      '--app',
      'acme',
      '--token',
      first.appKey,
    ]);

    // Publish + promote a second bundle using the same key.
    File(p('patch2.dart')).writeAsStringSync('int main() => 2;');
    await runCli([
      'compile',
      p('patch2.dart'),
      '-o',
      p('b2.bundle'),
      '--signing-key',
      p('signing.key'),
      '--app-id',
      'acme',
    ]);
    final pub2 = await runCli([
      '--json',
      'publish',
      p('b2.bundle'),
      '--server',
      baseUrl,
      '--app',
      'acme',
      '--token',
      first.appKey,
    ]);
    final secondId = jsonDecode(pub2.out)['bundleId'] as String;
    await runCli([
      'promote',
      secondId,
      '--env',
      'production',
      '--server',
      baseUrl,
      '--app',
      'acme',
      '--token',
      first.appKey,
    ]);

    final rollback = await runCli([
      'rollback',
      '--env',
      'production',
      '--server',
      baseUrl,
      '--app',
      'acme',
      '--token',
      first.appKey,
    ]);
    expect(rollback.code, 0, reason: rollback.err);

    final active = await getJson('/v1/apps/acme/envs/production/active');
    expect(active['activeBundleId'], first.bundleId);
  });

  test('publish reports an unreachable server clearly', () async {
    await runCli(['keygen', '-o', p('signing.key')]);
    File(p('patch.dart')).writeAsStringSync('int main() => 1;');
    await runCli([
      'compile',
      p('patch.dart'),
      '-o',
      p('b.bundle'),
      '--signing-key',
      p('signing.key'),
      '--app-id',
      'acme',
    ]);
    final r = await runCli([
      'publish',
      p('b.bundle'),
      '--server',
      'http://localhost:1',
      '--app',
      'acme',
      '--token',
      'x',
    ]);
    expect(r.code, 69); // EX_UNAVAILABLE
  });

  group('app create / list', () {
    test('registers an app from a keygen .pub file, then lists it', () async {
      await runCli(['keygen', '-o', p('signing.key')]);

      final create = await runCli([
        '--json',
        'app',
        'create',
        '--id',
        'com.acme',
        '--name',
        'Acme',
        '--key',
        '${p('signing.key')}.pub', // a .pub file path
        '--server',
        baseUrl,
        '--token',
        'admin-token',
      ]);
      expect(create.code, 0, reason: create.err);
      expect(jsonDecode(create.out)['apiKey'], isNotEmpty);

      // `app list` (admin-authenticated) surfaces the newly registered app.
      final list = await runCli([
        'app',
        'list',
        '--server',
        baseUrl,
        '--token',
        'admin-token',
      ]);
      expect(list.code, 0, reason: list.err);
      expect(list.out, contains('com.acme'));
    });

    test('accepts a raw hex key too', () async {
      await runCli(['keygen', '-o', p('k.key')]);
      final hex = File('${p('k.key')}.pub').readAsStringSync().trim();
      final create = await runCli([
        'app',
        'create',
        '--id',
        'com.hex',
        '--key',
        hex, // the hex directly, not a file
        '--server',
        baseUrl,
        '--token',
        'admin-token',
      ]);
      expect(create.code, 0, reason: create.err);
    });

    test('a bad admin token is rejected', () async {
      await runCli(['keygen', '-o', p('k.key')]);
      final r = await runCli([
        'app',
        'create',
        '--id',
        'com.nope',
        '--key',
        '${p('k.key')}.pub',
        '--server',
        baseUrl,
        '--token',
        'wrong-token',
      ]);
      expect(r.code, isNot(0));
    });

    test('missing --key is a usage error', () async {
      final r = await runCli([
        'app',
        'create',
        '--id',
        'com.x',
        '--server',
        baseUrl,
        '--token',
        'admin-token',
      ]);
      expect(r.code, 64);
    });
  });
}
