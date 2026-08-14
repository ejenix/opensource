// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import '../base_command.dart';
import '../control_plane_client.dart';

/// `ejenix push <bundle> --server <url> --app <id> --token <token>`.
class PublishCommand extends EjenixCommand {
  PublishCommand() {
    argParser
      ..addOption('server', help: 'Control-plane base URL.')
      ..addOption('app', help: 'Application id.');
    addTokenOptions(help: 'App API token.');
  }

  @override
  String get name => 'push';

  /// `publish` is the pre-1.0 name, kept so existing scripts keep working.
  @override
  List<String> get aliases => const ['publish'];

  @override
  String get description => 'Push a signed patch to the control plane.';

  @override
  String get invocation =>
      'ejenix push <bundle> --server <url> --app <id> --token <token>';

  @override
  Future<int> execute() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliException('missing bundle file', exitCode: 64);
    final file = File(rest.first);
    if (!file.existsSync()) {
      throw CliException('bundle not found: ${rest.first}', exitCode: 66);
    }
    final client = ControlPlaneClient(
      server: requireOption('server'),
      appId: requireOption('app'),
      token: requireToken(),
    );
    final result = await client.publish(file.readAsBytesSync());
    console.success('published bundle ${result['bundleId']}');
    console.emitJson(result);
    return 0;
  }
}
