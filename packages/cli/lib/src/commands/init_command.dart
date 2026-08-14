// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import '../base_command.dart';

const _samplePatch = '''
// A starter patch. Compile it with:
//   ejenix build patch.dart -o patch.bundle --signing-key signing.key \\
//     --app-id com.example.app
int add(int a, int b) => a + b;

int main() => add(20, 22);
''';

const _readme = '''
# ejenix starter

1. Generate a signing key:      ejenix keygen -o signing.key
2. Compile & sign the patch:    ejenix build patch.dart -o patch.bundle \\
                                  --signing-key signing.key --app-id com.example.app
3. Inspect it:                  ejenix inspect patch.bundle
4. Verify it:                   ejenix verify patch.bundle --key signing.key.pub
''';

/// `ejenix init [<dir>]` — scaffold a starter patch project.
class InitCommand extends EjenixCommand {
  InitCommand() {
    argParser.addFlag(
      'force',
      help: 'Write into a non-empty directory.',
      negatable: false,
    );
  }

  @override
  String get name => 'init';

  @override
  String get description => 'Scaffold a starter patch project.';

  @override
  String get invocation => 'ejenix init [<dir>]';

  @override
  Future<int> execute() async {
    final rest = argResults!.rest;
    final dir = Directory(rest.isEmpty ? '.' : rest.first);
    final force = argResults!['force'] as bool;
    dir.createSync(recursive: true);
    if (!force && dir.listSync().any((e) => e.path.endsWith('patch.dart'))) {
      throw CliException('patch.dart already exists; pass --force');
    }

    File('${dir.path}/patch.dart').writeAsStringSync(_samplePatch);
    File('${dir.path}/README.md').writeAsStringSync(_readme);

    console.success('scaffolded a starter project in ${dir.path}');
    console.info('next: ejenix keygen -o ${dir.path}/signing.key');
    console.emitJson({
      'directory': dir.path,
      'files': ['patch.dart', 'README.md'],
    });
    return 0;
  }
}
