// Entrypoint for `_web_cond_fixture` in `flutter/tests/web_test.bzl`.
//
// Exercises platform-conditional imports: `package:cond_icons` exports
// `icon_vm.dart` normally and `icon_web.dart` when `dart.library.js_interop`
// is available. The web icon tree-shake kernel must compile against the web
// platform so it resolves the web branch (0xe04b); a VM-platform kernel
// resolves the VM branch (0xe04c) and the shipped web font misses 0xe04b.
import 'package:cond_icons/cond_icons.dart';
import 'package:flutter/material.dart';

@pragma('vm:entry-point')
void main() {
  final keep = <Object?>[
    platformIcon,
    Icons.b,
  ];
  if (keep.isEmpty) {
    throw StateError('unreachable');
  }
}
