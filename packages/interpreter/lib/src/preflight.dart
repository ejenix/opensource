// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';

import 'host_api.dart';

/// Names the host globals a [module] calls that a [registry] does not provide.
///
/// A patch may only reach capabilities that exist in the **binary already on
/// the device**. Add `@Patchable('App.blogs')` to your app, regenerate the SDK,
/// compile a patch against it, and that patch is valid source — but the build
/// in the store still registers the old set, and the call fails on a user's
/// phone with `no host global 'App.blogs'`.
///
/// Checking is cheap and static: every host call is an `invokeStatic` naming a
/// selector, so the whole requirement set is known before a single instruction
/// runs. Callers use this to refuse a patch *before* it replaces a working
/// screen, rather than discovering the gap mid-render.
///
/// Only `invokeStatic` sites are considered. The call-site table is shared with
/// `invokeDyn`, whose selectors are ordinary method names on interpreted or
/// host objects (`length`, `add`) and are resolved by receiver kind — treating
/// those as missing globals would reject every healthy patch.
///
/// Returns the distinct selectors in first-seen order, so the message an
/// operator reads is stable across runs.
List<String> missingHostGlobals(Module module, HostRegistry registry) {
  final missing = <String>[];
  final seen = <String>{};
  for (final selector in requiredHostGlobals(module)) {
    if (registry.hasGlobal(selector)) continue;
    if (seen.add(selector)) missing.add(selector);
  }
  return missing;
}

/// Every host global [module] can call, in first-seen order.
///
/// The static requirement set a host must satisfy to run this patch. Useful on
/// its own for tooling — diffing a bundle against a host's registered surface
/// before publishing beats finding out from a crash report.
List<String> requiredHostGlobals(Module module) {
  final out = <String>[];
  final seen = <String>{};
  for (final fn in module.functions) {
    final code = fn.code;
    var pc = 0;
    while (pc < code.length) {
      // `Op.fromCode` throws on a code this build does not know, and a module
      // compiled by a newer CLI can legitimately contain one without a body
      // version bump. Reporting what we could read beats throwing out of a
      // routine callers use for diagnostics.
      final Instruction first;
      try {
        first = Instruction(code[pc]);
        first.op;
      } on Object {
        break;
      }
      var ins = first;
      pc++;
      // `pfx` carries the high bits of the following instruction's operand.
      var high = 0;
      if (ins.op == Op.pfx) {
        if (pc >= code.length) break;
        high = ins.ax;
        try {
          ins = Instruction(code[pc]);
          ins.op;
        } on Object {
          break;
        }
        pc++;
      }
      if (ins.op != Op.invokeStatic) continue;
      final index = (high << 16) | ins.bx;
      if (index < 0 || index >= module.callSites.length) continue;
      final selector = module.callSites[index].selector;
      if (seen.add(selector)) out.add(selector);
    }
  }
  return out;
}
