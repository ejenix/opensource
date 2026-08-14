// Copyright (c) Ejenix authors. MIT license.

import '../base_command.dart';
import '../control_plane_client.dart';

/// `ejenix rollback --env <env> --server <url> --app <id> --token <token>`.
class RollbackCommand extends EjenixCommand {
  RollbackCommand() {
    argParser
      ..addOption('env', help: 'Target environment.', defaultsTo: 'production')
      ..addOption('server', help: 'Control-plane base URL.')
      ..addOption('app', help: 'Application id.');
    addTokenOptions(help: 'App API token.');
  }

  @override
  String get name => 'rollback';

  @override
  String get description =>
      'Roll an environment back to its previously active bundle.';

  @override
  String get invocation =>
      'ejenix rollback --env <env> --server <url> --app <id> --token <token>';

  @override
  Future<int> execute() async {
    final env = requireOption('env');
    final client = ControlPlaneClient(
      server: requireOption('server'),
      appId: requireOption('app'),
      token: requireToken(),
    );
    final result = await client.rollback(env);
    console.success(
      'rolled $env back to ${result['activeBundleId']} '
      '(from ${result['rolledBackFrom']})',
    );
    console.emitJson(result);
    return 0;
  }
}
