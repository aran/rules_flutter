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
///       [--file <archive>]... [--pom <group>:<artifact> <file>]...
///       [--artifacts <json>]
///
/// The spec is `{"engineVersion": ..., "artifacts": [...]}`, each artifact
/// with `group`, `artifact`, `version`, `packaging` (`aar` or `jar`, the
/// archive's extension) and `dependencies` (each `group`, `artifact`,
/// `version`, `scope`), in the order of the `--file` archives that are
/// theirs. An artifact or dependency with `"engine": true` in place of a
/// `version` is the engine's, at the engine's version: `engineVersion`'s
/// `version`, or, for an engine whose POM the repository carries, the
/// version of the `--pom` its `pom` names, as `flutter build aar
/// --local-engine` reads it from the out dir's POM.
///
/// An artifact given a `--pom` is published with that POM as it is, in place
/// of one written from its `dependencies`: an engine's embedding, whose own
/// POM names what it needs, as `flutter build aar --local-engine` links an
/// out dir's into its repository. The POM must name the artifact's group and
/// artifact.
///
/// `--artifacts` writes `[{"group", "artifact", "version"}, ...]`, the
/// coordinates of every artifact the repository holds.
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

/// The version of the engine whose artifacts [spec] names (its
/// `engineVersion`), reading a POM of [poms] when it names one.
String engineVersion(Map<String, Object?> spec, Map<String, String> poms) {
  final engine = spec['engineVersion']! as Map<String, Object?>;
  final version = engine['version'] as String?;
  if (version != null) return version;
  final coordinate = engine['pom']! as String;
  final path = poms[coordinate];
  if (path == null) {
    throw FormatException(
      'the engine version is that of the POM of $coordinate, which no '
      '--pom gives',
    );
  }
  final found = pomCoordinates(File(path).readAsStringSync()).$3;
  if (found == null || found.isEmpty) {
    throw FormatException('$path: the POM has no version');
  }
  return found;
}

/// Writes the repository of [spec] into [output], taking each artifact's
/// archive from [files], in order, and returns each artifact's
/// `(group, artifact, version)`.
List<(String, String, String)> layOut(
  Map<String, Object?> spec,
  List<String> files,
  String output, {
  Map<String, String> poms = const {},
}) {
  final artifacts = (spec['artifacts']! as List).cast<Map<String, Object?>>();
  if (artifacts.length != files.length) {
    throw FormatException(
      'the spec lists ${artifacts.length} artifacts and there are '
      '${files.length} archives',
    );
  }
  String? engine;
  String versionOf(Map<String, Object?> json) => json['engine'] == true
      ? engine ??= engineVersion(spec, poms)
      : json['version']! as String;
  final published = <(String, String, String)>[];
  for (var i = 0; i < artifacts.length; i++) {
    final a = artifacts[i];
    final group = a['group']! as String;
    final artifact = a['artifact']! as String;
    final version = versionOf(a);
    final packaging = a['packaging']! as String;
    if (packaging != 'aar' && packaging != 'jar') {
      throw FormatException('$group:$artifact has packaging $packaging');
    }
    published.add((group, artifact, version));
    final dir = '$output/${versionDirectory(group, artifact, version)}';
    final base = '$dir/$artifact-$version';
    writeWithChecksums('$base.$packaging', File(files[i]).readAsBytesSync());
    final given = poms['$group:$artifact'];
    if (given != null) {
      final bytes = File(given).readAsBytesSync();
      final problem = pomCoordinatesProblem(
        utf8.decode(bytes),
        group: group,
        artifact: artifact,
        version: version,
      );
      if (problem != null) {
        throw FormatException('$given: $problem');
      }
      writeWithChecksums('$base.pom', bytes);
      continue;
    }
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
              MavenDependency(
                group: (d as Map<String, Object?>)['group']! as String,
                artifact: d['artifact']! as String,
                version: versionOf(d),
                scope: d['scope']! as String,
              ),
          ],
        ),
      ),
    );
  }
  return published;
}

/// The project's own `groupId`, `artifactId` and `version` in [pom]: the
/// first of each outside its `<parent>`, `<dependencies>` and
/// `<dependencyManagement>`.
(String?, String?, String?) pomCoordinates(String pom) {
  var own = pom;
  for (final name in ['parent', 'dependencyManagement', 'dependencies']) {
    own = own.replaceAll(RegExp('<$name>[\\s\\S]*?</$name>'), '');
  }
  String? element(String name) =>
      RegExp('<$name>\\s*([^<]*?)\\s*</$name>').firstMatch(own)?.group(1);
  return (element('groupId'), element('artifactId'), element('version'));
}

/// Why [pom] is not the POM of [group]:[artifact] at [version], or null when
/// it is.
String? pomCoordinatesProblem(
  String pom, {
  required String group,
  required String artifact,
  required String version,
}) {
  final found = pomCoordinates(pom);
  if (found != (group, artifact, version)) {
    return 'it is the POM of ${found.$1}:${found.$2}:${found.$3}, and the '
        'repository publishes it as $group:$artifact:$version. An engine '
        "source's `embedding_pom` is the POM of the embedding of its slice's "
        'mode: `io.flutter:flutter_embedding_<mode>`.';
  }
  return null;
}

void main(List<String> args) {
  String? specPath;
  String? output;
  final files = <String>[];
  final poms = <String, String>{};
  String? artifactsPath;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--spec':
        specPath = args[++i];
      case '--output':
        output = args[++i];
      case '--file':
        files.add(args[++i]);
      case '--artifacts':
        artifactsPath = args[++i];
      case '--pom':
        final coordinate = args[++i];
        poms[coordinate] = args[++i];
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
    final published = layOut(
      jsonDecode(File(specPath).readAsStringSync()) as Map<String, Object?>,
      files,
      output,
      poms: poms,
    );
    if (artifactsPath != null) {
      File(artifactsPath).writeAsStringSync(
        jsonEncode([
          for (final (group, artifact, version) in published)
            {'group': group, 'artifact': artifact, 'version': version},
        ]),
      );
    }
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  }
}
