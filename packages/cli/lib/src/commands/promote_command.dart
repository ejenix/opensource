// Copyright (c) Ejenix authors. MIT license.

import '../base_command.dart';
import '../control_plane_client.dart';

/// `ejenix promote <bundle-id> --env <env> --server <url> --app <id>
/// --token <token>`.
class PromoteCommand extends EjenixCommand {
  PromoteCommand() {
    argParser
      ..addOption('env', help: 'Target environment.', defaultsTo: 'production')
      ..addOption(
        'channel',
        help: 'Patchable surface within the app (one screen).',
        defaultsTo: 'default',
      )
      ..addOption(
        'rollout',
        help:
            'Percentage of the fleet to expose, 0-100. Devices decide whether '
            'they are in the share; re-promote the same bundle at a higher '
            'number to widen without disturbing devices already on it.',
      )
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
    final channel = requireOption('channel');
    final rolloutRaw = argResults!['rollout'] as String?;
    final rollout = rolloutRaw == null ? null : int.tryParse(rolloutRaw);
    if (rolloutRaw != null &&
        (rollout == null || rollout < 0 || rollout > 100)) {
      throw CliException('--rollout must be an integer 0-100', exitCode: 64);
    }
    final client = ControlPlaneClient(
      server: requireOption('server'),
      appId: requireOption('app'),
      token: requireToken(),
    );
    final result = await client.setActive(
      env,
      rest.first,
      channel: channel,
      rolloutPercent: rollout,
    );
    final where = channel == 'default' ? env : '$channel/$env';
    final share = rollout == null || rollout == 100
        ? ''
        : ' for $rollout% of devices';
    console.success('promoted ${result['activeBundleId']} to $where$share');
    console.emitJson(result);
    return 0;
  }
}
