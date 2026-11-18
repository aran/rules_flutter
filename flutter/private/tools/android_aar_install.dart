/// The program behind `bazel run` of a `flutter_android_aar` target: writes
/// the Flutter module's Maven repository where `flutter build aar` writes it,
/// and prints how a Gradle-built host app consumes it.
///
/// A build makes the repository of one mode, the configuration's. This adds
/// it to the repository on disk, keeping what runs in other modes wrote, so
/// three runs (`-c dbg`, `-c opt --@rules_flutter//flutter:profile`, `-c opt`)
/// give the host the `flutter_debug`, `flutter_profile` and `flutter_release`
/// artifacts it depends on. Each artifact's `maven-metadata.xml` lists every
/// version (build number) published to the repository, as Gradle's
/// `maven-publish` records them; an engine the repository carries, that of
/// an SDK whose engine is not the release's, is at the engine's version.
///
/// Environment:
///   RULES_FLUTTER_ANDROID_AAR_CONFIG  runfiles path of the JSON file the rule
///       writes: `label`, `package`, `packageName`, `buildNumber`, `mode`,
///       `artifacts` (each `group`, `artifact` and `version`), and `repo`, the runfiles
///       path of the built repository.
///   BUILD_WORKSPACE_DIRECTORY, BUILD_WORKING_DIRECTORY  set by `bazel run`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'maven_repo.dart';

const configEnv = 'RULES_FLUTTER_ANDROID_AAR_CONFIG';

/// A failure the user can act on, reported as `error: <message>`.
class InstallException implements Exception {
  InstallException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The rule's JSON.
class AarConfig {
  AarConfig({
    required this.label,
    required this.package,
    required this.packageName,
    required this.buildNumber,
    required this.mode,
    required this.artifacts,
    required this.repo,
  });

  factory AarConfig.fromJson(Map<String, Object?> json, String repo) =>
      AarConfig(
        label: json['label']! as String,
        package: json['package']! as String,
        packageName: json['packageName']! as String,
        buildNumber: json['buildNumber']! as String,
        mode: json['mode']! as String,
        artifacts: [
          for (final a in json['artifacts']! as List)
            (
              (a as Map<String, Object?>)['group']! as String,
              a['artifact']! as String,
              a['version']! as String,
            ),
        ],
        repo: repo,
      );

  final String label;
  final String package;

  /// The module's Android package: the Maven group of `flutter_<mode>`.
  final String packageName;
  final String buildNumber;
  final String mode;

  /// `(group, artifact, version)` of each artifact the built repository holds.
  final List<(String, String, String)> artifacts;

  /// The built repository, a directory.
  final String repo;
}

/// Copies every file under [from] to the same place under [to], replacing
/// what is there.
void copyTree(String from, String to) {
  final root = Directory(from);
  final prefix = root.path.endsWith('/') ? root.path : '${root.path}/';
  for (final entity in root.listSync(recursive: true, followLinks: true)) {
    if (entity is! File) continue;
    final relative = entity.path.substring(prefix.length);
    final target = File('$to/$relative');
    target.parent.createSync(recursive: true);
    if (target.existsSync()) target.deleteSync();
    // Written rather than copied, so it takes the user's permissions, not the
    // read-only ones of Bazel's outputs.
    target.writeAsBytesSync(entity.readAsBytesSync());
  }
}

/// Records each `(group, artifact, version)` of [artifacts] as published to
/// [repo] at [time], in the artifact's `maven-metadata.xml` (and that file's
/// `.sha1` and `.md5`).
void publishMetadata(
  String repo,
  List<(String, String, String)> artifacts,
  DateTime time,
) {
  for (final (group, artifact, version) in artifacts) {
    final file = File(
      '$repo/${artifactDirectory(group, artifact)}/maven-metadata.xml',
    );
    var metadata = MavenMetadata(
      group: group,
      artifact: artifact,
      versions: const [],
      latest: null,
      release: null,
      lastUpdated: null,
    );
    if (file.existsSync()) {
      final existing = MavenMetadata.parse(file.readAsStringSync());
      if (existing.group != group || existing.artifact != artifact) {
        throw InstallException(
          '${file.path} is the metadata of '
          '${existing.group}:${existing.artifact}, not $group:$artifact',
        );
      }
      metadata = existing;
    }
    file.parent.createSync(recursive: true);
    final bytes = utf8.encode(metadata.publish(version, time).toXml());
    for (final (path, contents) in [
      (file.path, null),
      ('${file.path}.sha1', sha1Hex(bytes)),
      ('${file.path}.md5', md5Hex(bytes)),
    ]) {
      final out = File(path);
      if (out.existsSync()) out.deleteSync();
      if (contents == null) {
        out.writeAsBytesSync(bytes);
      } else {
        out.writeAsStringSync(contents);
      }
    }
  }
}

/// The modes whose module artifact [repo] holds at [buildNumber].
List<String> modesIn(String repo, String packageName, String buildNumber) => [
  for (final mode in const ['debug', 'profile', 'release'])
    if (File(
      '$repo/${versionDirectory(packageName, 'flutter_$mode', buildNumber)}/'
      'flutter_$mode-$buildNumber.aar',
    ).existsSync())
      mode,
];

/// What `flutter build aar` prints after building (`printHowToConsumeAar`),
/// for the modes [modes] the repository holds.
String howToConsume({
  required List<String> modes,
  required String packageName,
  required String repo,
  required String buildNumber,
}) {
  final out = StringBuffer()
    ..writeln()
    ..writeln('Consuming the Module')
    ..writeln('  1. Open <host>/app/build.gradle')
    ..writeln(
      '  2. Ensure you have the repositories configured, otherwise add them:',
    )
    ..writeln()
    ..writeln(
      '      String storageUrl = System.env.FLUTTER_STORAGE_BASE_URL ?: '
      '"https://storage.googleapis.com"',
    )
    ..writeln('      repositories {')
    ..writeln('        maven {')
    ..writeln("            url '$repo'")
    ..writeln('        }')
    ..writeln('        maven {')
    ..writeln(r'            url "$storageUrl/download.flutter.io"')
    ..writeln('        }')
    ..writeln('      }')
    ..writeln()
    ..writeln('  3. Make the host app depend on the Flutter module:')
    ..writeln()
    ..writeln('    dependencies {');
  for (final mode in modes) {
    out.writeln(
      "      ${mode}Implementation '$packageName:flutter_$mode:$buildNumber'",
    );
  }
  out
    ..writeln('    }')
    ..writeln();
  if (modes.contains('profile')) {
    out
      ..writeln()
      ..writeln('  4. Add the `profile` build type:')
      ..writeln()
      ..writeln('    android {')
      ..writeln('      buildTypes {')
      ..writeln('        profile {')
      ..writeln('          initWith debug')
      ..writeln('        }')
      ..writeln('      }')
      ..writeln('    }')
      ..writeln();
  }
  out.writeln(
    'To learn more, visit https://flutter.dev/to/integrate-android-archive',
  );
  return out.toString();
}

/// The modes a host may need that [modes] lacks, and how to add each.
String missingModes(List<String> modes, String label) {
  const flags = {
    'debug': '-c dbg',
    'profile': '-c opt --@rules_flutter//flutter:profile',
    'release': '-c opt',
  };
  final missing = [
    for (final MapEntry(:key, :value) in flags.entries)
      if (!modes.contains(key)) '  bazel run $value $label   # flutter_$key',
  ];
  if (missing.isEmpty) return '';
  return 'The repository has no ${missing.length == 1 ? 'artifact' : 'artifacts'} '
      'for the other modes yet. To add them:\n${missing.join('\n')}\n';
}

String _env(String name) {
  final value = Platform.environment[name];
  return value == null || value.isEmpty ? '' : value;
}

void main(List<String> args) {
  try {
    String? output;
    for (final arg in args) {
      final match = RegExp(r'^--output=(.+)$').firstMatch(arg);
      if (match == null) {
        stderr
          ..writeln('unknown argument: $arg')
          ..writeln(
            'Usage: bazel run <flutter_android_aar target> -- [--output=<dir>]',
          );
        exit(64);
      }
      output = match.group(1);
    }
    final configPath = _env(configEnv);
    if (configPath.isEmpty) {
      throw InstallException(
        'run this through `bazel run` of a flutter_android_aar target',
      );
    }
    final runfiles = Runfiles.create();
    final json = jsonDecode(
      File(runfiles.rlocation(configPath)).readAsStringSync(),
    ) as Map<String, Object?>;
    final config = AarConfig.fromJson(
      json,
      runfiles.rlocation(json['repo']! as String),
    );

    final workspace = _env('BUILD_WORKSPACE_DIRECTORY');
    final workingDirectory = _env('BUILD_WORKING_DIRECTORY');
    final String repo;
    if (output != null) {
      repo = output.startsWith('/')
          ? output
          : '${workingDirectory.isEmpty ? Directory.current.path : workingDirectory}/$output';
    } else {
      if (workspace.isEmpty) {
        throw InstallException(
          'pass --output=<dir>: outside `bazel run` there is no workspace to '
          'write build/host/outputs/repo into',
        );
      }
      repo = [
        workspace,
        if (config.package.isNotEmpty) config.package,
        'build/host/outputs/repo',
      ].join('/');
    }

    copyTree(config.repo, repo);
    publishMetadata(repo, config.artifacts, DateTime.now());

    final modes = modesIn(repo, config.packageName, config.buildNumber);
    stdout
      ..writeln(
        'Wrote the ${config.mode} artifacts of ${config.label} to $repo',
      )
      ..write(
        howToConsume(
          modes: modes,
          packageName: config.packageName,
          repo: repo,
          buildNumber: config.buildNumber,
        ),
      )
      ..write(missingModes(modes, config.label));
  } on InstallException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  }
}
