// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:ejenix_loader/loader.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Uri url;

  Future<void> serve(Future<void> Function(HttpRequest request) handler) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = Uri.parse('http://${server.address.host}:${server.port}/bundle');
    server.listen(handler);
  }

  tearDown(() => server.close(force: true));

  // Fast backoff keeps retry tests quick.
  HttpBundleFetcher fetcher({int maxRetries = 3}) => HttpBundleFetcher(
    maxRetries: maxRetries,
    baseBackoff: const Duration(milliseconds: 1),
  );

  test('200 returns the body and etag', () async {
    await serve((request) async {
      request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final result = await fetcher().fetch(url);
    expect(result, isA<FetchSuccess>());
    final success = result as FetchSuccess;
    expect(success.bytes, [1, 2, 3, 4]);
    expect(success.etag, '"v1"');
  });

  test('304 with a matching If-None-Match returns not-modified', () async {
    await serve((request) async {
      expect(request.headers.value(HttpHeaders.ifNoneMatchHeader), '"v1"');
      request.response.statusCode = HttpStatus.notModified;
      await request.response.close();
    });
    expect(await fetcher().fetch(url, etag: '"v1"'), isA<FetchNotModified>());
  });

  test('a 404 is returned immediately without retrying', () async {
    var hits = 0;
    await serve((request) async {
      hits++;
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    final result = await fetcher().fetch(url);
    expect(result, isA<FetchFailure>());
    expect((result as FetchFailure).statusCode, 404);
    expect(hits, 1); // no retries on 4xx
  });

  test('a transient 500 is retried and then succeeds', () async {
    var hits = 0;
    await serve((request) async {
      hits++;
      if (hits == 1) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } else {
        request.response.add([9, 9]);
        await request.response.close();
      }
    });
    final result = await fetcher().fetch(url);
    expect(result, isA<FetchSuccess>());
    expect((result as FetchSuccess).bytes, [9, 9]);
    expect(hits, 2);
  });

  test('gives up after exhausting retries', () async {
    await serve((request) async {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    });
    final result = await fetcher(maxRetries: 2).fetch(url);
    expect(result, isA<FetchFailure>());
    expect((result as FetchFailure).statusCode, 502);
  });
}
