/// Builds the Gradle host app of add_to_app_host/android, offline, against
/// the repositories `flutter_android_aar` built for `plugin_app` in debug,
/// profile and release, and checks what each APK holds: the engine, the
/// module's AOT code or kernel, and the plugins' native libraries for each
/// ABI, all stripped; the plugins' and the module's classes dexed; and the
/// manifests of the host and the plugins merged.
///
/// Only the Android Gradle plugin consumes an AAR as a host app does: it maps
/// the host's `profile` build type to the module's `flutter_profile`, packages
/// each AAR's `jni/`, and merges every manifest.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/apk_contents.dart';
import 'package:rules_flutter_e2e_testing/archive.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/elf.dart';
import 'package:rules_flutter_e2e_testing/gradle_host.dart';

/// A class each of `plugin_app`'s plugins with Android code defines.
const _pluginClasses = [
  'Lcom/ryanheise/audio_session/AudioSessionPlugin;',
  'Lcom/github/dart_lang/jni/JniPlugin;',
  'Lcom/github/dart_lang/jni_flutter/JniFlutterPlugin;',
  'Lcom/example/kotlin_only_plugin/KotlinOnlyPlugin;',
  'Ldev/fluttercommunity/plus/packageinfo/PackageInfoPlugin;',
  'Lcom/llfbandit/record/RecordPlugin;',
  'Lio/flutter/plugins/sharedpreferences/SharedPreferencesPlugin;',
  'Lio/flutter/plugins/urllauncher/UrlLauncherPlugin;',
];

/// The classes of the host, the module and the engine's embedding.
const _hostAndModuleClasses = [
  'Lcom/example/add_to_app_host/MainActivity;',
  'Lio/flutter/plugins/GeneratedPluginRegistrant;',
  'Lio/flutter/embedding/android/FlutterActivity;',
];

/// The ABIs Flutter builds for, which the host's `abiFilters` keeps.
const _abis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: gradle_host_test <config runfile>');
    exitCode = 2;
    return;
  }
  final check = BundleCheck();
  final built = await buildGradleHostOffline(args.single, (host) {
    for (final variant in host.variants) {
      _verifyApk(check, variant, host.apk(variant));
    }
  });
  if (!built) {
    exitCode = 1;
    return;
  }
  check.finish(
    'The Gradle-built host app packages the module of every build mode.',
  );
}

void _verifyApk(BundleCheck check, String variant, File apk) {
  final aot = variant != 'debug';
  final archive = ExtractedArchive.fromPath(
    apk.path,
    prefix: 'gradle_host_$variant',
    extractor: Extractor.zipper,
  );
  try {
    final root = archive.path;
    final entries = {
      for (final f in archive.dir.listSync(recursive: true).whereType<File>())
        f.path.substring(root.length + 1).replaceAll(r'\', '/'),
    };
    final listed =
        entries
            .where((e) => e.startsWith('lib/') || e.endsWith('.dex'))
            .toList()
          ..sort();
    stdout.writeln(
      '$variant APK (${apk.lengthSync()} bytes): ${listed.join(', ')}',
    );

    final abis = {
      for (final e in entries.where((e) => e.startsWith('lib/')))
        e.split('/')[1],
    };
    check.expect(
      '$variant: native libraries for ${_abis.join(', ')} and no other ABI',
      condition: abis.length == _abis.length && abis.containsAll(_abis),
      detail: 'lib/ has $abis',
    );
    for (final abi in _abis) {
      final libraries = [
        'libflutter.so',
        // package:jni's, which its Dart side loads.
        'libdartjni.so',
        if (aot) 'libapp.so',
      ];
      for (final library in libraries) {
        final path = '$root/lib/$abi/$library';
        final problem = File(path).existsSync()
            ? ElfImage.fromFile(File(path)).validate(elfMachineForAbi[abi]!)
            : 'missing';
        check.expect(
          '$variant: lib/$abi/$library is an ELF library for $abi',
          condition: problem == null,
          detail: problem,
        );
      }
      // The Android Gradle plugin strips what it packages, with the NDK: the
      // engine Google publishes unstripped as well as the module's own.
      for (final library in entries.where(
        (e) => e.startsWith('lib/$abi/') && e.endsWith('.so'),
      )) {
        final problem = ElfImage.fromFile(
          File('$root/$library'),
        ).unstrippedSections();
        check.expect(
          '$variant: $library is stripped',
          condition: problem == null,
          detail: problem,
        );
      }
      if (!aot) {
        check.expect(
          '$variant: lib/$abi has no libapp.so, the module being kernel',
          condition: !entries.contains('lib/$abi/libapp.so'),
        );
      }
    }
    check.expect(
      '$variant: ${aot ? 'no' : 'the'} kernel in flutter_assets',
      condition:
          entries.contains('assets/flutter_assets/kernel_blob.bin') == !aot,
    );

    final dexFiles = entries.where(
      (e) => RegExp(r'^classes\d*\.dex$').hasMatch(e),
    );
    final classes = {
      for (final dex in dexFiles)
        ...definedClassDescriptors(File('$root/$dex')),
    };
    for (final descriptor in [..._hostAndModuleClasses, ..._pluginClasses]) {
      check.expect(
        '$variant: $descriptor is dexed',
        condition: classes.contains(descriptor),
      );
    }

    final manifest = manifestElements(
      File('$root/AndroidManifest.xml').readAsBytesSync(),
    );
    final activities = {
      for (final e in manifest.where((e) => e.name == 'activity'))
        e.attributes['name'],
    };
    for (final activity in [
      'com.example.add_to_app_host.MainActivity',
      'io.flutter.embedding.android.FlutterActivity',
      // url_launcher_android's, from its AAR's manifest.
      'io.flutter.plugins.urllauncher.WebViewActivity',
    ]) {
      check.expect(
        '$variant: the merged manifest declares $activity',
        condition: activities.contains(activity),
        detail: 'activities: $activities',
      );
    }
    final permissions = usesPermissions(
      File('$root/AndroidManifest.xml').readAsBytesSync(),
    );
    for (final (permission, from) in [
      ('android.permission.INTERNET', "the module's"),
      ('android.permission.RECORD_AUDIO', "record_android's"),
    ]) {
      check.expect(
        '$variant: the merged manifest has $from $permission',
        condition: permissions.contains(permission),
        detail: 'permissions: $permissions',
      );
    }
    final application = manifest.firstWhere((e) => e.name == 'application');
    check.expect(
      '$variant: the app is ${variant == 'release' ? 'not ' : ''}debuggable',
      condition:
          (application.attributes['debuggable'] == 'true') ==
          (variant != 'release'),
      detail: 'application: ${application.attributes}',
    );
  } finally {
    archive.dispose();
  }
}
