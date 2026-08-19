// Copyright (c) Ejenix authors. MIT license.

import '../base_command.dart';
import '../control_plane_client.dart';

/// `ejenix rollback --env <env> --server <url> --app <id> --token <token>`.
class RollbackCommand extends EjenixCommand {
  RollbackCommand() {
    argParser
      ..addOption(
        'env',
        help:
            'Target environment (required). Not defaulted: this command\n'
            'changes what real users are running, so the target is never assumed.',
      )
      ..addOption(
        'channel',
        help: 'Patchable surface within the app (one screen).',
        defaultsTo: 'default',
      )
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
    final env = requireOption(
      'env',
      hint: 'This changes what real users are running. Pass --env explicitly.',
    );
    final client = ControlPlaneClient(
      server: requireOption('server'),
      appId: requireOption('app'),
      token: requireToken(),
    );
    final result = await client.rollback(
      env,
      channel: requireOption('channel'),
    );
    console.success(
      'rolled $env back to ${result['activeBundleId']} '
      '(from ${result['rolledBackFrom']})',
    );
    console.emitJson(result);
    return 0;
  }
}
