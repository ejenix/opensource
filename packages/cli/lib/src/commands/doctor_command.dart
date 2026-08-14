// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import '../base_command.dart';
import '../util.dart';

/// `ejenix doctor` — validate the developer environment.
class DoctorCommand extends EjenixCommand {
  DoctorCommand() {
    argParser.addOption(
      'signing-key',
      help: 'Optionally validate this signing key file.',
    );
  }

  @override
  String get name => 'doctor';

  @override
  String get description => 'Validate the developer environment and config.';

  @override
  Future<int> execute() async {
    final checks = <String, ({bool ok, String detail})>{};

    checks['dart'] = (ok: true, detail: Platform.version.split(' ').first);

    final keyPath = argResults!['signing-key'] as String?;
    if (keyPath != null) {
      try {
        readSeedFile(keyPath);
        checks['signing-key'] = (ok: true, detail: 'valid ($keyPath)');
      } on CliException catch (e) {
        checks['signing-key'] = (ok: false, detail: e.message);
      }
    }

    var allOk = true;
    for (final entry in checks.entries) {
      final mark = entry.value.ok ? '✓' : '✗';
      if (!entry.value.ok) allOk = false;
      console.info('$mark ${entry.key.padRight(14)} ${entry.value.detail}');
    }

    console.emitJson({
      'ok': allOk,
      'checks': {
        for (final e in checks.entries)
          e.key: {'ok': e.value.ok, 'detail': e.value.detail},
      },
    });
    if (!allOk) throw CliException('one or more checks failed');
    console.success('environment looks healthy');
    return 0;
  }
}
