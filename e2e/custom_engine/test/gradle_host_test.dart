/// Builds the Gradle host app of add_to_app_host/android, offline, against
/// `:module_aar`, the module of the stand-in checkout's engine, and checks that
/// the engine in its APK is the one the module's repository carries.
///
/// The engine's `io.flutter` artifacts are named at the release's version, as
/// the stand-in lays the release engine out as a checkout's, so their
/// coordinates are Google's too. The offline repository the build resolves
/// everything else from holds no `io.flutter` artifact, so a build that finds
/// the engine finds it in the module's repository; and the APK's
/// `libflutter.so` is that repository's, byte for byte.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/archive.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/elf.dart';
import 'package:rules_flutter_e2e_testing/gradle_host.dart';

const _abi = 'arm64-v8a';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: gradle_host_test <config runfile>');
    exitCode = 2;
    return;
  }
  final check = BundleCheck();
  final built = await buildGradleHostOffline(args.single, (host) {
    // The module's repository first, then the offline one.
    final [moduleRepository, ...others] = host.repositories;
    final module = Directory.fromUri(Uri.parse(moduleRepository));
    for (final repository in others) {
      final directory = Directory.fromUri(Uri.parse(repository));
      check.expect(
        '$repository, not the module, has no io.flutter artifact',
        condition: !Directory('${directory.path}/io/flutter').existsSync(),
      );
    }
    _verifyEngine(check, host.apk('release'), module);
  });
  if (!built) {
    exitCode = 1;
    return;
  }
  check.finish(
    "The Gradle-built host app packages the engine of the module's repository.",
  );
}

void _verifyEngine(BundleCheck check, File apk, Directory module) {
  final jars = module
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => RegExp(r'arm64_v8a_release-[^/\\]*\.jar$').hasMatch(f.path))
      .toList();
  check.expect(
    "the module's repository carries one io.flutter:arm64_v8a_release jar",
    condition: jars.length == 1,
    detail: '$jars',
  );
  if (jars.length != 1) return;
  final engineJar = ExtractedArchive.fromPath(
    jars.single.path,
    prefix: 'gradle_host_engine',
    extractor: Extractor.zipper,
  );
  final archive = ExtractedArchive.fromPath(
    apk.path,
    prefix: 'gradle_host_release',
    extractor: Extractor.zipper,
  );
  try {
    final packaged = File('${archive.path}/lib/$_abi/libflutter.so');
    final carried = File('${engineJar.path}/lib/$_abi/libflutter.so');
    if (!packaged.existsSync() || !carried.existsSync()) {
      check.fail(
        'libflutter.so: in the APK ${packaged.existsSync()}, '
        'in the module repository ${carried.existsSync()}',
      );
      return;
    }
    final problem = ElfImage.fromFile(
      packaged,
    ).validate(elfMachineForAbi[_abi]!);
    check.expect(
      'release: lib/$_abi/libflutter.so is an ELF library for $_abi',
      condition: problem == null,
      detail: problem,
    );
    final bytes = packaged.readAsBytesSync();
    final expected = carried.readAsBytesSync();
    var same = bytes.length == expected.length;
    for (var i = 0; same && i < bytes.length; i++) {
      same = bytes[i] == expected[i];
    }
    check.expect(
      "release: lib/$_abi/libflutter.so is the module repository's engine",
      condition: same,
      detail: 'the APK has ${bytes.length} bytes, the repository '
          '${expected.length}',
    );
    stdout.writeln(
      'APK libflutter.so: ${bytes.length} bytes, '
      "the module repository's: ${expected.length}.",
    );
  } finally {
    archive.dispose();
    engineJar.dispose();
  }
}
