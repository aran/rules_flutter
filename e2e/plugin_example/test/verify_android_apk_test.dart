/// Verifies the plugin_example Android APK packages every plugin's native
/// pieces — most importantly `libdartjni.so`, the C support library of
/// `package:jni` that jnigen-based plugins (path_provider_android >= 2.3)
/// load via `System.loadLibrary("dartjni")` in a static initializer. If the
/// library is missing, plugin registration aborts wholesale at startup with
/// an UnsatisfiedLinkError.
///
/// APK is a zip file — we extract it to a temp dir and verify contents.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/elf.dart';
import 'package:rules_flutter_e2e_testing/jar_library.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';
import 'package:rules_flutter_e2e_testing/zip_entries.dart';
import 'package:runfiles/runfiles.dart';

/// Classes the plugin closure requires at runtime, keyed by what ships them.
/// One representative class per source — if the class is not *defined* in
/// the APK's dex files, that piece is missing and the corresponding plugin
/// code path throws NoClassDefFoundError.
///
/// All listed classes are covered by keep rules (the registrant references
/// the plugin classes; package:jni's consumer-rules.pro keeps
/// com.github.dart_lang.jni.**), so their descriptors survive R8 renaming.
/// Dependencies without keep rules (e.g. kotlinx-coroutines) are
/// obfuscated by R8 and can't be asserted by name — R8 already fails the
/// build if a class referenced from a kept class is absent.
const _requiredDexClasses = <String, String>{
  'package:jni android/src (plugin class)':
      'Lcom/github/dart_lang/jni/JniPlugin;',
  'package:jni java/src (Gradle srcDirs — shared JNI support classes)':
      'Lcom/github/dart_lang/jni/PortContinuation;',
  'package:jni java/src (proxy support)':
      'Lcom/github/dart_lang/jni/PortProxyBuilder;',
  'package:jni_flutter android/src (plugin class)':
      'Lcom/github/dart_lang/jni_flutter/JniFlutterPlugin;',
};

/// Native libraries every plugin_example APK must carry for its ABI,
/// regardless of compilation mode.
const _requiredNativeLibs = <String, String>{
  'Flutter engine': 'libflutter.so',
  'package:jni C support library (System.loadLibrary("dartjni"))':
      'libdartjni.so',
  // shared_preferences_android depends on androidx.datastore, an AAR with a
  // library for each ABI. It is not Flutter's, so it reaches the APK by
  // rules_android's own handling of AARs, which the Flutter libraries must
  // agree with.
  "androidx.datastore's AAR library": 'libdatastore_shared_counter.so',
};

void main() {
  // Verify the ambient-configuration APK (release under a default
  // `bazel test`) and a copy force-built under `-c dbg` by the debug_apk
  // transition. Checking both in one default `bazel test //...` run exercises
  // the debug variant-manifest merge in both directions — INTERNET must be
  // absent from the release APK and present in the debug APK — without
  // building this test itself under `-c dbg`. The x86_64 APK must carry its
  // own engine and no other: the plugins compile against an arm64 one. The
  // fat APK, built for all three platforms at once, carries every native
  // library of each: the engine and libapp.so, package:jni's C library, and
  // the AAR's (androidx.datastore's, which ships a library per ABI).
  final cases = [
    ('arm64-v8a', 'plugin_android_arm64.apk', null, ['arm64-v8a']),
    ('-c dbg', 'plugin_android_dbg.apk', true, ['arm64-v8a']),
    ('x86_64', 'plugin_android_x86_64.apk', null, ['x86_64']),
    (
      'fat',
      'plugin_android_fat.apk',
      null,
      ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
    ),
  ];

  // One log across the APKs, so one run names every problem in all of them.
  final check = BundleCheck();
  for (final (label, apkName, mustBeDebug, abis) in cases) {
    print('\n=== Verifying $label APK ($apkName) ===');
    final apk = Apk.fromRunfiles(
      apkName,
      prefix: 'plugin_apk_test',
      check: check,
    );
    final failuresBefore = check.failures.length;
    try {
      _verifyApk(apk, mustBeDebug: mustBeDebug, abis: abis);
      if (check.failures.length > failuresBefore) apk.listContents();
    } finally {
      apk.dispose();
    }
  }

  // The app's classes before R8 renames them.
  final deployJarEntries = zipEntries(
    File(
      requireRunfile('plugin_android_deploy.jar', what: 'deploy jar'),
    ).readAsBytesSync(),
  );
  final deployJar = {for (final entry in deployJarEntries) entry.name};
  _verifyDatastoreVariant(check, deployJar);
  _verifyOneKotlinStdlib(check, deployJarEntries);
  check
    ..expect(
      'the app has the plugin class of kotlin_only_plugin, a `path` package '
      'built from its pubspec',
      condition: deployJar.contains(
        'com/example/kotlin_only_plugin/KotlinOnlyPlugin.class',
      ),
    )
    ..finish('\nAll plugin_example APK verification checks passed.');
}

/// Checks that the app carries one Kotlin standard library, as Gradle does:
/// the jar `org.jetbrains.kotlin:kotlin-stdlib` resolves to, and no class in
/// its packages that another kotlin-stdlib defines differently or adds. Kotlin
/// libraries also link rules_kotlin's own stdlib.
void _verifyOneKotlinStdlib(BundleCheck check, List<ZipEntry> deployJar) {
  final jars = Platform.environment['KOTLIN_STDLIB_RUNFILES']!
      .split(' ')
      .where((path) => path.endsWith('.jar') && !path.endsWith('-sources.jar'))
      .toList();
  if (jars.length != 1) {
    check.fail('kotlin-stdlib resolves to one jar, not $jars');
    return;
  }
  final stdlib = zipEntries(
    File(Runfiles.create().rlocation(jars.single)).readAsBytesSync(),
  );
  final foreign = classesNotFrom(deployJar, stdlib);
  check.expect(
    "the app's Kotlin standard library is all ${jars.single.split('/').last}",
    condition: foreign.isEmpty,
    detail:
        '${foreign.length} classes of another version, such as '
        '${foreign.take(3).join(', ')}',
  );
}

/// Checks that the app's classes, before R8 renames them, come from
/// androidx.datastore's Android variant, as Gradle resolves it, and not from
/// its JVM variant. datastore-core is a Kotlin Multiplatform library, and the
/// POM of datastore-preferences-core-jvm names datastore-core-jvm, whose
/// atomicMoveTo calls java.nio.file.Files.move unguarded: an API 26 class that
/// an app at minSdk 24 without core library desugaring cannot load. The
/// Android variant checks the API level and falls back to File.renameTo.
void _verifyDatastoreVariant(BundleCheck check, Set<String> names) {
  check
    ..expect(
      "the app has datastore-core's Android variant",
      condition: names.contains(
        'androidx/datastore/core/FileMoves_androidKt.class',
      ),
    )
    ..expect(
      "the app has no class of datastore-core's JVM variant",
      condition: !names.contains(
        'androidx/datastore/core/FileMoves_jvmKt.class',
      ),
    );
}

/// Verifies a single APK built for [abis], ABI directory names. [mustBeDebug]
/// asserts the detected compilation mode when non-null (the `-c dbg`
/// transition must yield a debug build); null accepts whatever the ambient
/// configuration produced.
void _verifyApk(
  Apk apk, {
  required bool? mustBeDebug,
  required List<String> abis,
}) {
  final check = apk.check;

  // --- Compilation mode detection ---
  // Debug APKs run Dart from kernel_blob.bin inside flutter_assets (JIT);
  // release APKs AOT-compile it into lib/<abi>/libapp.so. Exactly one of
  // the two ships.
  final hasKernelBlob = apk
      .file('assets/flutter_assets/kernel_blob.bin')
      .existsSync();
  final abisWithLibApp = [
    for (final abi in abis)
      if (apk.file('lib/$abi/libapp.so').existsSync()) abi,
  ];
  final hasLibApp = abisWithLibApp.isNotEmpty;
  if (hasKernelBlob == hasLibApp) {
    check.fail(
      'expected exactly one of kernel_blob.bin (debug) '
      'and libapp.so (release); found '
      '${hasKernelBlob ? "both" : "neither"}',
    );
  }
  final isDebug = hasKernelBlob;
  check.pass('APK is a ${isDebug ? "debug (JIT)" : "release (AOT)"} build');

  // --- AOT code, for every ABI ---
  // Each ABI needs the Dart code compiled for it; a missing one would install
  // and then crash at launch on a device of that ABI.
  if (!isDebug) {
    for (final abi in abis) {
      check.expect(
        'lib/$abi/libapp.so (AOT code for $abi)',
        condition: abisWithLibApp.contains(abi),
        detail: 'lib/$abi/libapp.so not found',
      );
    }
  }

  if (mustBeDebug != null && isDebug != mustBeDebug) {
    check.fail(
      'expected a ${mustBeDebug ? "debug" : "release"} '
      'APK but detected a ${isDebug ? "debug" : "release"} build — the '
      'compilation-mode transition did not apply',
    );
  }

  // --- INTERNET permission: present iff debug ---
  // flutter create declares android.permission.INTERNET only in
  // android/app/src/debug/AndroidManifest.xml; flutter_android_app merges
  // that variant manifest into -c dbg APKs (the Dart VM service cannot
  // bind without it) and must leave release APKs without it.
  final hasInternet = apk.fileHasText(
    'AndroidManifest.xml',
    'android.permission.INTERNET',
  );
  if (hasInternet == isDebug) {
    check.pass(
      'INTERNET permission '
      '${isDebug ? "present in debug" : "absent from release"} APK',
    );
  } else {
    check.fail(
      isDebug
          ? 'debug APK does not declare android.permission.INTERNET — '
                'the debug variant manifest did not merge'
          : 'release APK declares android.permission.INTERNET — the '
                'debug variant manifest leaked into a release build',
    );
  }

  // --- Native library presence ---
  for (final abi in abis) {
    _requiredNativeLibs.forEach((description, basename) {
      final path = 'lib/$abi/$basename';
      if (apk.file(path).existsSync()) {
        check.pass('$path ($description)');
      } else {
        check.fail('$path not found — $description');
      }
    });
  }

  // --- Binary format checks ---
  // A library under another ABI's directory makes Android choose that ABI
  // when the device supports it, and then the app's own code (libapp.so) is
  // missing and the engine crashes at launch.
  final found = apk.abis;
  if (found.join(',') == ([...abis]..sort()).join(',')) {
    check.pass('lib/ holds ${abis.join(', ')} only');
  } else {
    check.fail(
      'expected lib/{${abis.join(',')}} only; found lib/{${found.join(',')}}',
    );
  }
  apk.checkNativeLibraries();

  // --- Stripping ---
  // A Gradle build strips every native library it packages (llvm-strip
  // --strip-unneeded), in every build type: the engine Google ships with full
  // debug info (unstripped, the debug APK carries ~600 MB of symbols the
  // device never reads), the app's own, and those of the Maven AARs the
  // plugins depend on (androidx.datastore's).
  for (final library in [
    for (final abi in abis)
      if (Directory('${apk.path}/lib/$abi') case final dir
          when dir.existsSync())
        for (final f in dir.listSync())
          if (f is File && f.path.endsWith('.so')) f,
  ]) {
    final name = library.path
        .substring(apk.path.length + 1)
        .replaceAll(r'\', '/');
    final problem = ElfImage.fromFile(library).unstrippedSections();
    check.expect(
      '$name is stripped',
      condition: problem == null,
      detail: problem,
    );
  }

  // --- Plugin runtime class checks ---
  apk.checkDefinedClasses(_requiredDexClasses);

  // --- Plugin resource + manifest merge checks (record_android) ---
  // record_android ships android/src/main/res/drawable/ic_mic.xml and a
  // library manifest declaring RECORD_AUDIO. Both must survive into the
  // APK: the resource entry name lands in resources.arsc's key string
  // pool, and the permission lands in the merged binary
  // AndroidManifest.xml (strings there are UTF-16 in binary XML).
  check
    ..expect(
      "resources.arsc defines ic_mic (record_android's drawable merged)",
      condition: apk.fileHasText('resources.arsc', 'ic_mic'),
      detail:
          "ic_mic not found in resources.arsc — record_android's res/ was "
          'dropped',
    )
    ..expect(
      'merged AndroidManifest.xml declares RECORD_AUDIO '
      "(record_android's library manifest merged)",
      condition: apk.fileHasText(
        'AndroidManifest.xml',
        'android.permission.RECORD_AUDIO',
      ),
      detail:
          'RECORD_AUDIO not found in the merged AndroidManifest.xml — '
          "record_android's manifest did not merge",
    );
}
