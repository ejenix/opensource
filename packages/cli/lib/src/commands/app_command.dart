// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import '../base_command.dart';
import '../control_plane_client.dart';

/// `ejenix app <create|list>` — manage apps on the control plane.
///
/// A thin, first-class wrapper over the admin API so registering an app is a
/// command like everything else, not a hand-rolled `curl`.
class AppCommand extends EjenixCommand {
  AppCommand() {
    addSubcommand(AppCreateCommand());
    addSubcommand(AppListCommand());
  }

  @override
  String get name => 'app';

  @override
  String get description => 'Manage apps on the control plane (create, list).';

  @override
  Future<int> execute() async {
    console.error('specify a subcommand: ${subcommands.keys.join(', ')}');
    return 64;
  }
}

/// `ejenix app create --id <id> --key <pubkey> --server <url> --token <admin>`.
class AppCreateCommand extends EjenixCommand {
  AppCreateCommand() {
    argParser
      ..addOption('id', help: 'App id (a slug, e.g. com.myapp).')
      ..addOption('name', help: 'Human-readable name (defaults to the id).')
      ..addOption(
        'key',
        help:
            'Public signing key: a path to a .pub file, or the hex directly. '
            'Repeatable.',
      )
      ..addMultiOption('keys', help: 'Additional public keys (path or hex).')
      ..addOption('server', help: 'Control-plane base URL.');
    addTokenOptions(help: 'Admin API token.');
  }

  @override
  String get name => 'create';

  @override
  String get description =>
      'Register a new app and its trusted signing key(s).';

  @override
  String get invocation =>
      'ejenix app create --id <id> --key <pubkey> --server <url> '
      '--token <admin>';

  @override
  Future<int> execute() async {
    final id = requireOption('id');
    final keyArgs = <String>[
      if (argResults!['key'] != null) argResults!['key'] as String,
      ...argResults!['keys'] as List<String>,
    ];
    if (keyArgs.isEmpty) {
      throw CliException(
        'missing required --key (public signing key)',
        exitCode: 64,
      );
    }
    // Each key is a .pub file path or the hex itself.
    final trustedKeys = [
      for (final k in keyArgs)
        File(k).existsSync() ? File(k).readAsStringSync().trim() : k.trim(),
    ];

    final client = ControlPlaneClient(
      server: requireOption('server'),
      token: requireToken(),
    );
    final result = await client.createApp(
      id: id,
      trustedKeys: trustedKeys,
      name: argResults!['name'] as String?,
    );

    console.success('registered app "$id"');
    final apiKey = result['apiKey'];
    if (apiKey != null) {
      console.info('app API key (shown once — store it): $apiKey');
    }
    console.emitJson(result);
    return 0;
  }
}

/// `ejenix app list --server <url> --token <admin>`.
class AppListCommand extends EjenixCommand {
  AppListCommand() {
    argParser..addOption('server', help: 'Control-plane base URL.');
    addTokenOptions(help: 'Admin API token.');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List the apps registered on the control plane.';

  @override
  String get invocation => 'ejenix app list --server <url> --token <admin>';

  @override
  Future<int> execute() async {
    final client = ControlPlaneClient(
      server: requireOption('server'),
      token: requireToken(),
    );
    final result = await client.listApps();
    final apps = (result['apps'] as List?) ?? const [];
    if (apps.isEmpty) {
      console.info('no apps registered');
    } else {
      for (final a in apps) {
        final m = a as Map;
        console.info('${m['id']}  ${m['name'] ?? ''}');
      }
    }
    console.emitJson(result);
    return 0;
  }
}
