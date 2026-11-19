/// Verifies the Maven repositories `flutter_android_aar` builds against the
/// layout `flutter build aar` writes (upstream's devicelab
/// `build_aar_module_test`): the paths, the POMs, and the AARs' entries, for
/// the release and debug repositories of `plugin_app` and the release one of
/// `annotated_app`, built for arm64 alone.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/archive.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/elf.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

/// The Android package of both modules.
const _module = 'com.example.plugin_example.module';

/// `plugin_app`'s plugins with Android code, by the Maven group each one's
/// Gradle build sets, and a class each one's own code defines.
const _plugins = <String, (String, String)>{
  'audio_session': (
    'com.ryanheise.audio_session',
    'com/ryanheise/audio_session/AudioSessionPlugin.class',
  ),
  'jni': (
    'com.github.dart_lang.jni',
    'com/github/dart_lang/jni/JniPlugin.class',
  ),
  'jni_flutter': (
    'com.github.dart_lang.jni_flutter',
    'com/github/dart_lang/jni_flutter/JniFlutterPlugin.class',
  ),
  'kotlin_only_plugin': (
    'com.example.kotlin_only_plugin',
    'com/example/kotlin_only_plugin/KotlinOnlyPlugin.class',
  ),
  'package_info_plus': (
    'dev.fluttercommunity.plus.packageinfo',
    'dev/fluttercommunity/plus/packageinfo/PackageInfoPlugin.class',
  ),
  'record_android': (
    'com.llfbandit.record',
    'com/llfbandit/record/RecordPlugin.class',
  ),
  'shared_preferences_android': (
    'io.flutter.plugins.sharedpreferences',
    'io/flutter/plugins/sharedpreferences/SharedPreferencesPlugin.class',
  ),
  'url_launcher_android': (
    'io.flutter.plugins.urllauncher',
    'io/flutter/plugins/urllauncher/UrlLauncherPlugin.class',
  ),
};

/// The plugin written in the workspace, whose Maven group is the `group` of its
/// Android `flutter_plugin_platform`, and a class its own code defines.
const _workspacePlugins = <String, (String, String)>{
  'glass_plugin': (
    'com.example.glass_plugin',
    'com/example/glass_plugin/GlassPlugin.class',
  ),
};

/// What each plugin's POM lists beyond the Kotlin standard library: the
/// Maven artifacts its Gradle build declares, with the scope Gradle publishes
/// them at (`implementation` is runtime).
const _pluginDependencies = {
  'audio_session': ['androidx.media:media:1.7.0:runtime'],
  'shared_preferences_android': [
    'androidx.datastore:datastore:1.2.1:runtime',
    'androidx.datastore:datastore-preferences:1.2.1:runtime',
    'androidx.preference:preference:1.2.1:runtime',
  ],
  'url_launcher_android': [
    'androidx.core:core:1.17.0:runtime',
    'androidx.annotation:annotation:1.10.0:runtime',
    'androidx.browser:browser:1.9.0:runtime',
  ],
};

/// The native libraries of each plugin whose Android library links any from
/// its own package: none of these does.
const _pluginNativeLibraries = <String, List<String>>{};

/// The plugins written in Kotlin, whose POMs name the standard library.
const _kotlin = {
  'glass_plugin',
  'kotlin_only_plugin',
  'package_info_plus',
  'record_android',
  'shared_preferences_android',
  'url_launcher_android',
};

const _abis = {
  'armeabi-v7a': 'armeabi_v7a',
  'arm64-v8a': 'arm64_v8a',
  'x86_64': 'x86_64',
};

final _checksum = {
  'sha1': RegExp(r'^[0-9a-f]{40}$'),
  'md5': RegExp(r'^[0-9a-f]{32}$'),
};

void main() {
  final check = BundleCheck();
  final scratch = Directory.systemTemp.createTempSync('android_aar_test');
  try {
    for (final mode in ['release', 'debug']) {
      _verifyRepo(
        check,
        scratch,
        requireRunfile('plugin_module_repo_$mode', what: 'Repository'),
        mode: mode,
        abis: _abis.keys.toList(),
        plugins: _plugins.keys.toList(),
      );
    }
    _verifyRepo(
      check,
      scratch,
      requireRunfile('annotated_module_aar_repo', what: 'Repository'),
      mode: 'release',
      abis: ['arm64-v8a'],
      plugins: ['annotated_plugin'],
    );

    // A plugin written in the workspace: the Maven group is the `group` of its
    // Android `flutter_plugin_platform`, there being no Gradle build to read.
    _verifyRepo(
      check,
      scratch,
      requireRunfile('glass_app/glass_module_aar_repo', what: 'Repository'),
      mode: 'release',
      abis: ['arm64-v8a'],
      plugins: ['glass_plugin'],
      modulePackage: 'com.example.glass_app.module',
    );
  } finally {
    scratch.deleteSync(recursive: true);
  }
  check.finish(
    '\nThe repositories are laid out as `flutter build aar` lays one out.',
  );
}

String _path(String group, String artifact, String version) =>
    '${group.replaceAll('.', '/')}/$artifact/$version/$artifact-$version';

/// `group:artifact:version:scope` of each dependency of [pom], in order.
List<String> _dependencies(String pom) => [
  for (final m in RegExp(
    r'<dependency>\s*<groupId>([^<]*)</groupId>\s*<artifactId>([^<]*)</artifactId>'
    r'\s*<version>([^<]*)</version>\s*<scope>([^<]*)</scope>\s*</dependency>',
  ).allMatches(pom))
    '${m[1]}:${m[2]}:${m[3]}:${m[4]}',
];

String? _one(String xml, String tag) =>
    RegExp('<$tag>([^<]*)</$tag>').firstMatch(xml)?.group(1);

/// The entries of the archive at [path], extracted under [scratch].
Directory _extract(Directory scratch, String path) => ExtractedArchive.fromPath(
  path,
  prefix: 'android_aar_test',
  extractor: Extractor.zipper,
).dir;

Set<String> _files(Directory dir) => {
  for (final f in dir.listSync(recursive: true))
    if (f is File) f.path.substring(dir.path.length + 1).replaceAll(r'\', '/'),
};

void _verifyRepo(
  BundleCheck check,
  Directory scratch,
  String repo, {
  required String mode,
  required List<String> abis,
  required List<String> plugins,
  String modulePackage = _module,
}) {
  final label = '$mode ${abis.join('+')}';
  final module = _path(modulePackage, 'flutter_$mode', '1.0');

  // Every artifact, and nothing else: an AAR and a POM, with their checksums.
  final expected = {
    module,
    for (final p in plugins) _path(_pluginGroup(p), '${p}_$mode', '1.0'),
  };
  final files = _files(Directory(repo));
  final wanted = {
    for (final base in expected)
      for (final ext in ['aar', 'pom'])
        for (final suffix in ['', '.sha1', '.md5']) '$base.$ext$suffix',
  };
  check.expect(
    '$label: the repository holds the module and each plugin, with .sha1 '
    'and .md5 files',
    condition: files.length == wanted.length && files.containsAll(wanted),
    detail:
        'missing ${wanted.difference(files).toList()..sort()}, '
        'unexpected ${files.difference(wanted).toList()..sort()}',
  );
  for (final f in files.where(
    (f) => f.endsWith('.sha1') || f.endsWith('.md5'),
  )) {
    final kind = f.split('.').last;
    final text = File('$repo/$f').readAsStringSync();
    if (!_checksum[kind]!.hasMatch(text)) {
      check.fail('$label: $f is not a $kind checksum: "$text"');
    }
  }

  // The module's POM: upstream's coordinates and dependencies.
  final pomFile = File('$repo/$module.pom');
  if (!pomFile.existsSync()) return;
  final pom = pomFile.readAsStringSync();
  check.expect(
    '$label: the module is $modulePackage:flutter_$mode:1.0, an aar',
    condition:
        _one(pom, 'groupId') == modulePackage &&
        _one(pom, 'artifactId') == 'flutter_$mode' &&
        _one(pom, 'version') == '1.0' &&
        _one(pom, 'packaging') == 'aar',
  );
  final dependencies = _dependencies(pom);
  final engine = RegExp(
    r'^io\.flutter:flutter_embedding_\w+:(1\.0\.0-[0-9a-f]{40}):compile$',
  ).firstMatch(dependencies.isEmpty ? '' : dependencies.first)?.group(1);
  check.expect(
    '$label: the module depends on io.flutter:flutter_embedding_$mode '
    'first, at 1.0.0-<engine revision>',
    condition:
        engine != null &&
        dependencies.first.startsWith('io.flutter:flutter_embedding_$mode:'),
    detail: 'dependencies: $dependencies',
  );
  final wantedDependencies = [
    'io.flutter:flutter_embedding_$mode:$engine:compile',
    for (final MapEntry(:key, :value) in _abis.entries)
      if (abis.contains(key)) 'io.flutter:${value}_$mode:$engine:compile',
    for (final p in plugins) '${_pluginGroup(p)}:${p}_$mode:1.0:compile',
  ];
  check.expect(
    '$label: the module depends on the engine of each ABI and on every plugin',
    condition:
        dependencies.length == wantedDependencies.length &&
        dependencies.toSet().containsAll(wantedDependencies),
    detail: 'expected $wantedDependencies, got $dependencies',
  );

  // The module's AAR.
  final aarFile = '$repo/$module.aar';
  if (!File(aarFile).existsSync()) return;
  final aar = _extract(scratch, aarFile);
  final entries = _files(aar);
  for (final entry in [
    'AndroidManifest.xml',
    'classes.jar',
    'R.txt',
    'assets/flutter_assets/AssetManifest.bin',
    'assets/flutter_assets/NOTICES.Z',
  ]) {
    check.expect(
      '$label: the module AAR has $entry',
      condition: entries.contains(entry),
    );
  }
  final debugEntries = [
    'assets/flutter_assets/kernel_blob.bin',
    'assets/flutter_assets/vm_snapshot_data',
    'assets/flutter_assets/isolate_snapshot_data',
  ];
  for (final entry in debugEntries) {
    check.expect(
      '$label: the module AAR ${mode == 'debug' ? 'has' : 'has no'} $entry',
      condition: entries.contains(entry) == (mode == 'debug'),
    );
  }
  final jniAbis = {
    for (final e in entries.where((e) => e.startsWith('jni/'))) e.split('/')[1],
  };
  check.expect(
    '$label: the module AAR has native libraries for ${abis.join(', ')} '
    'and no other ABI',
    condition: jniAbis.length == abis.length && jniAbis.containsAll(abis),
    detail: 'jni/ has $jniAbis',
  );
  for (final abi in abis) {
    check.expect(
      '$label: the module AAR ${mode == 'debug' ? 'has no' : 'has'} jni/$abi/libapp.so',
      condition: entries.contains('jni/$abi/libapp.so') == (mode != 'debug'),
    );
  }
  _checkStripped(check, '$label: the module AAR', aar, entries);
  final manifest = File('${aar.path}/AndroidManifest.xml').readAsStringSync();
  check
    ..expect(
      "$label: the module manifest's package is $modulePackage",
      condition: manifest.contains('package="$modulePackage"'),
      detail: manifest,
    )
    // As upstream's module template has it: a debug build's Dart VM service
    // listens on a socket.
    ..expect(
      '$label: the module manifest asks for INTERNET',
      condition: manifest.contains(
        '<uses-permission android:name="android.permission.INTERNET" />',
      ),
      detail: manifest,
    );
  final classes = _files(_extract(scratch, '${aar.path}/classes.jar'));
  const registrant = 'io/flutter/plugins/GeneratedPluginRegistrant.class';
  check.expect(
    '$label: classes.jar holds the plugin registrant and nothing but it',
    condition:
        classes.where((c) => c.endsWith('.class')).toList().join() ==
        registrant,
    detail: 'classes.jar has ${classes.toList()..sort()}',
  );

  for (final plugin in plugins) {
    _verifyPlugin(check, scratch, repo, label, mode, abis, plugin);
  }
}

/// Checks that every native library of the AAR extracted to [aar] is
/// stripped, as a Gradle build strips what it packages into an AAR, in every
/// build type.
void _checkStripped(
  BundleCheck check,
  String what,
  Directory aar,
  Set<String> entries,
) {
  for (final library in entries.where(
    (e) => e.startsWith('jni/') && e.endsWith('.so'),
  )) {
    final problem = ElfImage.fromFile(
      File('${aar.path}/$library'),
    ).unstrippedSections();
    check.expect(
      '$what has $library stripped',
      condition: problem == null,
      detail: problem,
    );
  }
}

String _pluginGroup(String plugin) => plugin == 'annotated_plugin'
    ? 'com.example.annotated_plugin'
    : (_plugins[plugin] ?? _workspacePlugins[plugin])!.$1;

void _verifyPlugin(
  BundleCheck check,
  Directory scratch,
  String repo,
  String label,
  String mode,
  List<String> abis,
  String plugin,
) {
  final group = _pluginGroup(plugin);
  final base = _path(group, '${plugin}_$mode', '1.0');
  final pomFile = File('$repo/$base.pom');
  if (!pomFile.existsSync()) return;
  final pom = pomFile.readAsStringSync();
  final dependencies = _dependencies(pom);
  final kotlinStdlib = RegExp(
    r'^org\.jetbrains\.kotlin:kotlin-stdlib:[^:]+:compile$',
  );
  final kotlin = plugin == 'annotated_plugin' || _kotlin.contains(plugin);
  final declared = plugin == 'annotated_plugin'
      // What `flutter_pub.annotation` in MODULE.bazel says its version catalog
      // declaration stands for, at the version the build resolves.
      ? ['androidx.browser:browser:1.9.0:runtime']
      : _pluginDependencies[plugin] ?? const <String>[];
  check
    ..expect(
      '$label: $plugin is $group:${plugin}_$mode:1.0 and its POM lists what '
      'its Gradle build declares',
      condition:
          _one(pom, 'groupId') == group &&
          _one(pom, 'artifactId') == '${plugin}_$mode' &&
          dependencies.where((d) => !kotlinStdlib.hasMatch(d)).join(',') ==
              declared.join(',') &&
          dependencies.where(kotlinStdlib.hasMatch).length == (kotlin ? 1 : 0),
      detail: 'dependencies: $dependencies',
    )
    ..expect(
      "$label: $plugin's POM does not list the embedding, which a plugin "
      'compiles against only',
      condition: !dependencies.any((d) => d.startsWith('io.flutter:')),
    );

  final aarFile = '$repo/$base.aar';
  if (!File(aarFile).existsSync()) return;
  final aar = _extract(scratch, aarFile);
  final entries = _files(aar);
  check.expect(
    "$label: $plugin's AAR has a manifest, classes.jar and R.txt",
    condition: entries.containsAll([
      'AndroidManifest.xml',
      'classes.jar',
      'R.txt',
    ]),
    detail: 'entries: $entries',
  );
  final jni = entries.where((e) => e.startsWith('jni/')).toSet();
  final wantedJni = {
    for (final abi in abis)
      for (final library in _pluginNativeLibraries[plugin] ?? const [])
        'jni/$abi/$library',
  };
  check.expect(
    "$label: $plugin's AAR has its own native libraries for each ABI, and "
    'no others',
    condition: jni.length == wantedJni.length && jni.containsAll(wantedJni),
    detail: 'expected $wantedJni, got $jni',
  );
  _checkStripped(check, "$label: $plugin's AAR", aar, entries);
  final classes = _files(_extract(scratch, '${aar.path}/classes.jar'))
      .where((c) => c.endsWith('.class'))
      .toSet();
  final own = plugin == 'annotated_plugin'
      ? 'com/example/annotated_plugin/AnnotatedPlugin.class'
      : (_plugins[plugin] ?? _workspacePlugins[plugin])!.$2;
  check.expect(
    "$label: $plugin's classes.jar has $own",
    condition: classes.contains(own),
  );
  final foreign = classes.where(
    (c) =>
        c.startsWith('androidx/') ||
        c.startsWith('io/flutter/embedding/') ||
        c.startsWith('kotlin/'),
  );
  check.expect(
    "$label: $plugin's classes.jar holds its own classes, not its "
    "dependencies'",
    condition: foreign.isEmpty,
    detail: 'it has ${foreign.take(5).toList()}',
  );
  if (plugin == 'record_android') {
    final manifest = File('${aar.path}/AndroidManifest.xml').readAsStringSync();
    check
      ..expect(
        "$label: record_android's AAR has its resource and the permission its "
        'manifest asks for',
        condition:
            entries.contains('res/drawable/ic_mic.xml') &&
            manifest.contains('android.permission.RECORD_AUDIO'),
        detail: manifest,
      )
      ..expect(
        "$label: record_android's classes.jar has its BuildConfig",
        condition: classes.contains('com/llfbandit/record/BuildConfig.class'),
      );
  }
}
