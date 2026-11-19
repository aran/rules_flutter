// A program reaching pub.dev's `runfiles` through a `flutter_pub` hub and
// `@rules_dart//dart/runfiles` compiles one copy of it, and that copy finds
// the program's runfiles.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final path = Platform.environment['SELF']!;
  final found = Runfiles.create().rlocation(path);
  if (!File(found).existsSync()) {
    stderr.writeln('rlocation($path) gave $found, which does not exist');
    exit(1);
  }
}
