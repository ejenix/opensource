// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:ejenix_cli/cli.dart';

Future<void> main(List<String> args) async {
  final runner = EjenixRunner();
  try {
    exit(await runner.run(args) ?? 0);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  }
}
