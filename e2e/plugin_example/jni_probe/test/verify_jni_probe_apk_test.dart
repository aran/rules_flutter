/// Verifies that a shared library a plugin's Android library builds from
/// source reaches the APK, stripped as a Gradle build strips it, and that
/// every native library there is aligned for 16 KB pages: the Android C/C++
/// toolchain links the plugin's code, and rules_flutter keeps its alignment.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/elf.dart';

void main() {
  final apk = Apk.fromRunfiles(
    'jni_probe/jni_probe_android_app.apk',
    prefix: 'jni_probe_apk_',
  );
  final library = File('${apk.path}/lib/arm64-v8a/libjni_probe.so');
  apk.check.exists(
    'the plugin builds libjni_probe.so (arm64-v8a)',
    library.path,
  );
  if (library.existsSync()) {
    final problem = ElfImage.fromFile(library).unstrippedSections();
    apk.check.expect(
      'libjni_probe.so is stripped, as a Gradle build strips what it packages',
      condition: problem == null,
      detail: problem,
    );
  }
  apk
    ..checkNativeLibraries()
    ..finish('All jni_probe APK checks passed.');
}
