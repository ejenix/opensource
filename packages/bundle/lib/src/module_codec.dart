// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'package:ejenix_bytecode/bytecode.dart';

import 'cbor.dart';
import 'metadata.dart';

/// Serializes a [Module] plus its [BundleMetadata] to and from the canonical
/// CBOR bundle body (brief §6.4).
///
/// The body is a positional CBOR array — no maps — so encoding is deterministic
/// without any key-ordering rule: identical inputs always produce identical
/// bytes, which is what makes the content hash and signature reproducible.
/// Bytecode is stored little-endian regardless of host byte order.
class ModuleCodec {
  /// The body schema version. Bumped only on a breaking layout change.
  /// v2 adds the call-site table; v3 adds the class table; v4 adds each
  /// function's closure-capture list; v5 adds the async flag; v6 adds each
  /// function's exception-handler table; v7 adds the static-field global count
  /// and initializer index; v8 widens the async flag to a function-kind int
  /// (0 sync, 1 async, 2 sync*, 3 async*).
  static const int bodyFormatVersion = 9;

  /// The oldest body version this build can still read.
  ///
  /// Accepting a range rather than one exact version is what makes the format
  /// extensible at all. With a strict `!=`, bumping the version rejected
  /// bundles in *both* directions at once: a new device could not read an
  /// already-published bundle, and every deployed device rejected anything new.
  /// A field could therefore never be added without stranding a fleet.
  ///
  /// Reading old bundles is always safe — fields introduced later simply take
  /// their documented defaults. Refusing *newer* bundles stays correct: a build
  /// that cannot see a field cannot enforce what that field promises, and
  /// `minSdk` is the mechanism for keeping such bundles away from it.
  static const int minReadableBodyVersion = 8;

  /// Encodes [module] and [metadata] to canonical CBOR body bytes.
  static Uint8List encodeBody(Module module, BundleMetadata metadata) {
    final w = CborWriter()..writeArrayHeader(10);
    w.writeInt(bodyFormatVersion);

    final constants = module.constants.values;
    w.writeArrayHeader(constants.length);
    for (final value in constants) {
      w.writeValue(value);
    }

    w.writeArrayHeader(module.functions.length);
    for (final fn in module.functions) {
      w
        ..writeArrayHeader(7)
        ..writeString(fn.name)
        ..writeInt(fn.paramCount)
        ..writeInt(fn.registerCount)
        ..writeBytes(_codeToBytes(fn.code));
      w.writeArrayHeader(fn.captures.length);
      for (final r in fn.captures) {
        w.writeInt(r);
      }
      w.writeInt(
        fn.isSyncStar
            ? 2
            : fn.isAsyncStar
            ? 3
            : fn.isAsync
            ? 1
            : 0,
      );
      w.writeArrayHeader(fn.handlers.length);
      for (final h in fn.handlers) {
        w
          ..writeArrayHeader(4)
          ..writeInt(h.start)
          ..writeInt(h.end)
          ..writeInt(h.target)
          ..writeInt(h.catchReg);
      }
    }

    w.writeInt(module.entryFunction);
    w.writeInt(module.globalCount);
    w.writeInt(module.staticInit);

    w.writeArrayHeader(module.callSites.length);
    for (final site in module.callSites) {
      w
        ..writeArrayHeader(2)
        ..writeString(site.selector)
        ..writeInt(site.argCount);
    }

    w.writeArrayHeader(module.classes.length);
    for (final cls in module.classes) {
      w
        ..writeArrayHeader(5)
        ..writeString(cls.name)
        ..writeInt(cls.fieldCount)
        ..writeInt(cls.superIndex);
      w.writeArrayHeader(cls.methods.length);
      for (final entry in cls.methods.entries) {
        w
          ..writeArrayHeader(2)
          ..writeString(entry.key)
          ..writeInt(entry.value);
      }
      w.writeArrayHeader(cls.fields.length);
      for (final entry in cls.fields.entries) {
        w
          ..writeArrayHeader(2)
          ..writeString(entry.key)
          ..writeInt(entry.value);
      }
    }

    w
      ..writeArrayHeader(3)
      ..writeString(metadata.targetAppId)
      ..writeString(metadata.targetFlutterVersion)
      ..writeString(metadata.minSdk)
      ..writeInt(metadata.releaseGeneration);

    return w.takeBytes();
  }

  /// Decodes body [bytes] back into a module and its metadata.
  static (Module, BundleMetadata) decodeBody(Uint8List bytes) {
    final r = CborReader(bytes);
    final bodyElements = r.readArrayHeader();
    if (bodyElements != 9 && bodyElements != 10) {
      throw CborException(
        'bundle body must be a 9- or 10-element array, got $bodyElements',
      );
    }
    final version = r.readInt();
    if (version < minReadableBodyVersion || version > bodyFormatVersion) {
      throw CborException(
        'unsupported body format version $version '
        '(this build reads $minReadableBodyVersion..$bodyFormatVersion)',
      );
    }

    final constants = ConstantPool();
    final constantCount = r.readArrayHeader();
    for (var i = 0; i < constantCount; i++) {
      constants.add(r.readValue());
    }

    final functionCount = r.readArrayHeader();
    final functions = <FunctionProto>[];
    for (var i = 0; i < functionCount; i++) {
      if (r.readArrayHeader() != 7) {
        throw CborException('function entry must be a 7-element array');
      }
      final name = r.readString();
      final paramCount = r.readInt();
      final registerCount = r.readInt();
      final code = _bytesToCode(r.readBytes());
      final captureCount = r.readArrayHeader();
      final captures = <int>[
        for (var j = 0; j < captureCount; j++) r.readInt(),
      ];
      final kind = r.readInt();
      final handlerCount = r.readArrayHeader();
      final handlers = <ExceptionHandler>[];
      for (var j = 0; j < handlerCount; j++) {
        if (r.readArrayHeader() != 4) {
          throw CborException('handler entry must be a 4-element array');
        }
        handlers.add(
          ExceptionHandler(
            start: r.readInt(),
            end: r.readInt(),
            target: r.readInt(),
            catchReg: r.readInt(),
          ),
        );
      }
      functions.add(
        FunctionProto(
          name: name,
          paramCount: paramCount,
          registerCount: registerCount,
          code: code,
          captures: captures,
          isAsync: kind == 1,
          isSyncStar: kind == 2,
          isAsyncStar: kind == 3,
          handlers: handlers,
        ),
      );
    }

    final entry = r.readInt();
    final globalCount = r.readInt();
    final staticInit = r.readInt();

    final callSiteCount = r.readArrayHeader();
    final callSites = <CallSite>[];
    for (var i = 0; i < callSiteCount; i++) {
      if (r.readArrayHeader() != 2) {
        throw CborException('call site must be a 2-element array');
      }
      callSites.add(CallSite(selector: r.readString(), argCount: r.readInt()));
    }

    final classCount = r.readArrayHeader();
    final classes = <ClassDescriptor>[];
    for (var i = 0; i < classCount; i++) {
      if (r.readArrayHeader() != 5) {
        throw CborException('class must be a 5-element array');
      }
      final name = r.readString();
      final fieldCount = r.readInt();
      final superIndex = r.readInt();
      final methods = <String, int>{};
      final methodCount = r.readArrayHeader();
      for (var j = 0; j < methodCount; j++) {
        if (r.readArrayHeader() != 2) {
          throw CborException('method entry must be a 2-element array');
        }
        methods[r.readString()] = r.readInt();
      }
      final fields = <String, int>{};
      final fieldEntryCount = r.readArrayHeader();
      for (var j = 0; j < fieldEntryCount; j++) {
        if (r.readArrayHeader() != 2) {
          throw CborException('field entry must be a 2-element array');
        }
        fields[r.readString()] = r.readInt();
      }
      classes.add(
        ClassDescriptor(
          name: name,
          fieldCount: fieldCount,
          superIndex: superIndex,
          methods: methods,
          fields: fields,
        ),
      );
    }

    if (r.readArrayHeader() != 3) {
      throw CborException('metadata must be a 3-element array');
    }
    final metadata = BundleMetadata(
      targetAppId: r.readString(),
      targetFlutterVersion: r.readString(),
      minSdk: r.readString(),
      // Absent in v8 bodies, which predate freshness. Zero means "no
      // generation claimed", and a device applies no ordering rule to it.
      releaseGeneration: bodyElements == 10 ? r.readInt() : 0,
    );

    return (
      Module(
        constants: constants,
        functions: functions,
        entryFunction: entry,
        callSites: callSites,
        classes: classes,
        globalCount: globalCount,
        staticInit: staticInit,
      ),
      metadata,
    );
  }

  static Uint8List _codeToBytes(Uint32List code) {
    final out = Uint8List(code.length * 4);
    final view = ByteData.sublistView(out);
    for (var i = 0; i < code.length; i++) {
      view.setUint32(i * 4, code[i], Endian.little);
    }
    return out;
  }

  static Uint32List _bytesToCode(Uint8List bytes) {
    if (bytes.length % 4 != 0) {
      throw CborException(
        'bytecode length ${bytes.length} is not a multiple '
        'of 4',
      );
    }
    final code = Uint32List(bytes.length ~/ 4);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < code.length; i++) {
      code[i] = view.getUint32(i * 4, Endian.little);
    }
    return code;
  }
}
