/// Lays out the Maven repository of one build mode of a `flutter_android_aar`:
/// each artifact's archive (an `.aar`, or the `.jar` of an engine the
/// repository carries) and `.pom`, and a `.sha1` and `.md5` beside each,
/// at `<group as path>/<artifact>/<version>/`, as Gradle's `maven-publish`
/// writes them. `maven-metadata.xml` is not written here: it records every
/// version published to a repository, which the program `bazel run` starts
/// knows and a build action does not.
///
/// Usage:
///
///   dart android_maven_repo.dart --spec <json> --output <directory>
///       [--file <archive>]...
///
/// The spec is `{"artifacts": [...]}`, each with `group`, `artifact`,
/// `version`, `packaging` (`aar` or `jar`, the archive's extension) and
/// `dependencies` (each `group`, `artifact`, `version`, `scope`), in the order
/// of the `--file` archives that are theirs.
library;

import 'dart:convert';
import 'dart:io';

import 'maven_repo.dart';

/// Writes [bytes] to [path] and its `.sha1` and `.md5` beside it.
void writeWithChecksums(String path, List<int> bytes) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  File('$path.sha1').writeAsStringSync(sha1Hex(bytes));
  File('$path.md5').writeAsStringSync(md5Hex(bytes));
}

/// Writes the repository of [spec] into [output], taking each artifact's
/// archive from [files], in order.
void layOut(Map<String, Object?> spec, List<String> files, String output) {
  final artifacts = (spec['artifacts']! as List).cast<Map<String, Object?>>();
  if (artifacts.length != files.length) {
    throw FormatException(
      'the spec lists ${artifacts.length} artifacts and there are '
      '${files.length} archives',
    );
  }
  for (var i = 0; i < artifacts.length; i++) {
    final a = artifacts[i];
    final group = a['group']! as String;
    final artifact = a['artifact']! as String;
    final version = a['version']! as String;
    final packaging = a['packaging']! as String;
    if (packaging != 'aar' && packaging != 'jar') {
      throw FormatException('$group:$artifact has packaging $packaging');
    }
    final dir = '$output/${versionDirectory(group, artifact, version)}';
    final base = '$dir/$artifact-$version';
    writeWithChecksums('$base.$packaging', File(files[i]).readAsBytesSync());
    writeWithChecksums(
      '$base.pom',
      utf8.encode(
        pom(
          group: group,
          artifact: artifact,
          version: version,
          packaging: packaging,
          dependencies: [
            for (final d in (a['dependencies']! as List))
              MavenDependency.fromJson(d as Map<String, Object?>),
          ],
        ),
      ),
    );
  }
}

void main(List<String> args) {
  String? specPath;
  String? output;
  final files = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--spec':
        specPath = args[++i];
      case '--output':
        output = args[++i];
      case '--file':
        files.add(args[++i]);
      default:
        stderr.writeln('error: unknown argument: ${args[i]}');
        exit(64);
    }
  }
  if (specPath == null || output == null) {
    stderr.writeln('error: --spec and --output are required');
    exit(64);
  }
  try {
    layOut(
      jsonDecode(File(specPath).readAsStringSync()) as Map<String, Object?>,
      files,
      output,
    );
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  }
}
