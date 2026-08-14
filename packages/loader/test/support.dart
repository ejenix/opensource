// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_loader/loader.dart';

final Signer testSigner = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 11));
final TrustAnchors testAnchors = TrustAnchors.single(testSigner.publicKey);

const testMetadata = BundleMetadata(
  targetAppId: 'com.example.app',
  targetFlutterVersion: '3.41.6',
  minSdk: '1.0.0',
);

const testHost = HostEnvironment(
  appId: 'com.example.app',
  flutterVersion: '3.41.6',
  sdkVersion: '1.2.0',
);

Module moduleReturning(int value) {
  final fn =
      (BytecodeBuilder()
            ..emitLoadInt(0, value)
            ..emitA(Op.ret, 0))
          .toProto(name: 'main', paramCount: 0, registerCount: 1);
  return Module(constants: ConstantPool(), functions: [fn], entryFunction: 0);
}

Bundle buildBundle(
  int value, {
  int? id,
  BundleMetadata metadata = testMetadata,
  Signer? signer,
}) {
  return Bundle.sign(
    module: moduleReturning(value),
    metadata: metadata,
    signer: signer ?? testSigner,
    compilerVersion: '0.1.0',
    bundleId: id == null ? null : (Uint8List(16)..fillRange(0, 16, id)),
  );
}

/// A [BundleFetcher] driven by a supplied handler.
class FakeFetcher implements BundleFetcher {
  FakeFetcher(this.handler);
  final Future<FetchResult> Function(Uri url, String? etag) handler;
  Uri? lastUrl;
  String? lastEtag;

  @override
  Future<FetchResult> fetch(Uri url, {String? etag}) {
    lastUrl = url;
    lastEtag = etag;
    return handler(url, etag);
  }
}

Directory tempStoreDir() =>
    Directory.systemTemp.createTempSync('ejenix_loader_test');
