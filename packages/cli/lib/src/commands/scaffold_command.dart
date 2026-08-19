// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../base_command.dart';
import '../codegen/scaffold.dart';
import '../util.dart';

/// `ejenix scaffold <name>` — generate a patch stub plus the production host
/// widget that wraps `EjenixPatchView`, so making a screen patchable is one command
/// instead of hand-wiring the cache directory, trusted keys, fallback, and
/// update lifecycle.
class ScaffoldCommand extends EjenixCommand {
  ScaffoldCommand() {
    argParser
      ..addOption('app-id', help: 'Target application id (fills the template).')
      ..addOption(
        'dir',
        help: 'Project root to generate into.',
        defaultsTo: '.',
      )
      ..addOption(
        'patches-dir',
        help: 'Directory for interpreted patches, relative to --dir.',
        defaultsTo: 'patches',
      )
      ..addOption(
        'lib-dir',
        help: 'Directory for the host widget, relative to --dir.',
        defaultsTo: 'lib',
      )
      ..addOption(
        'sdk-dir',
        help: 'Directory holding the patch SDK, relative to --dir.',
        defaultsTo: 'patch_sdk',
      )
      ..addFlag(
        'force',
        help: 'Overwrite files that already exist.',
        negatable: false,
      );
  }

  @override
  String get name => 'scaffold';

  @override
  String get description =>
      'Generate a patch stub and a EjenixPatchView host for a new screen.';

  @override
  String get invocation => 'ejenix scaffold <screen_name> [--app-id <id>]';

  static final _validName = RegExp(r'^[a-z][a-z0-9_]*$');

  @override
  Future<int> execute() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw CliException('missing screen name', exitCode: 64);
    }
    final name = rest.first;
    if (!_validName.hasMatch(name)) {
      throw CliException(
        "invalid name '$name': use snake_case (e.g. home_screen)",
        exitCode: 64,
      );
    }

    final dir = argResults!['dir'] as String;
    final patchesDir = argResults!['patches-dir'] as String;
    final libDir = argResults!['lib-dir'] as String;
    final sdkDir = argResults!['sdk-dir'] as String;
    final force = argResults!['force'] as bool;
    final appId = argResults!['app-id'] as String? ?? '<app-id>';

    final patchPath = p.join(dir, patchesDir, '$name.dart');
    final viewPath = p.join(dir, libDir, '${name}_view.dart');
    // The patch imports the SDK by a path relative to its own directory. That
    // path goes into an `import`, so it must be POSIX-style on every platform.
    final sdkPrefix = toImportPath(
      p.relative(p.join(dir, sdkDir), from: p.join(dir, patchesDir)),
    );

    for (final path in [patchPath, viewPath]) {
      if (File(path).existsSync() && !force) {
        throw CliException(
          '$path already exists (use --force to overwrite)',
          exitCode: 73,
        );
      }
    }

    _write(patchPath, scaffoldPatch(name: name, sdkPrefix: sdkPrefix));
    _write(viewPath, scaffoldView(name: name, appId: appId));

    console.success('scaffolded $patchPath and $viewPath');
    console.info('Next:');
    // Step 1 first, and stated plainly: the generated patch imports
    // $sdkDir/flutter.dart, which is copied rather than generated. Leaving it
    // out was the first thing every new integration hit — `ejenix build` fails
    // with "The function 'Scaffold' isn't defined", which reads like a broken
    // patch and is actually a missing SDK.
    console.info(
      '  1. copy the framework patch SDK (required, or the build fails):\n'
      '       cp <ejenix-clone>/flutter_bridge/patch_sdk/flutter.dart '
      '$sdkDir/',
    );
    console.info(
      '  2. `ejenix gen` your @Patchable code into $sdkDir + '
      'app_capabilities.g.dart',
    );
    console.info(
      '  3. fill the TODOs in $viewPath (key, control plane, app id, env)',
    );
    console.info('  4. place ${pascalCase(name)}View() in your widget tree');
    console.info('  5. `ejenix build $patchPath` → push → promote');
    console.info(
      '  6. for an offline first launch, ship the bundle as an asset:\n'
      '       cp $name.bundle assets/$name.bundle\n'
      '       and add "assets/$name.bundle" under flutter: assets: in '
      'pubspec.yaml',
    );
    console.emitJson({'patch': patchPath, 'view': viewPath});
    return 0;
  }

  void _write(String path, String contents) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }
}
