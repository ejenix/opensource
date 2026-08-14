// Copyright (c) Ejenix authors. MIT license.

import '../base_command.dart';
import '../control_plane_client.dart';

/// `ejenix promote <bundle-id> --env <env> --server <url> --app <id>
/// --token <token>`.
class PromoteCommand extends EjenixCommand {
  PromoteCommand() {
    argParser
      ..addOption('env', help: 'Target environment.', defaultsTo: 'production')
      ..addOption('server', help: 'Control-plane base URL.')
      ..addOption('app', help: 'Application id.');
    addTokenOptions(help: 'App API token.');
  }

  @override
  String get name => 'promote';

  @override
  String get description =>
      'Set a bundle active in an environment on the control plane.';

  @override
  String get invocation =>
      'ejenix promote <bundle-id> --env <env> --server <url> --app <id> '
      '--token <token>';

  @override
  Future<int> execute() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliException('missing bundle id', exitCode: 64);
    final env = requireOption('env');
    final client = ControlPlaneClient(
      server: requireOption('server'),
      appId: requireOption('app'),
      token: requireToken(),
    );
    final result = await client.setActive(env, rest.first);
    console.success('promoted ${result['activeBundleId']} to $env');
    console.emitJson(result);
    return 0;
  }
}
