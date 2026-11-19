/// Records the lock of the Maven repository an e2e workspace's add-to-app host
/// app builds offline from (`gradle_offline_repository`), as
/// `gradle_repository.json` beside the host's settings.gradle.
///
/// A workspace's `record_gradle_host_repository` runs it:
/// `bazel run --config=deep //:record_gradle_host_repository`. It builds the
/// host app's variants as its `gradle_host_test` does, but against the remote
/// repositories and with an empty Gradle user home, then locks every file
/// Gradle downloaded: its URL, the first of the repositories that has it, and
/// its SHA-256. Run it after changing the
/// host app's build, its Android Gradle plugin, or the Flutter version (which
/// names the `io.flutter` artifacts).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'gradle_host.dart';

/// The classifiers of an artifact the Android Gradle Plugin downloads for the
/// machine it runs on (aapt2): a recording on one locks all of them, so the
/// lock serves every machine.
const _hostClassifiers = ['linux', 'osx', 'windows'];

/// Records the lock of the host whose `gradle_host_config` the runfile
/// `args.single` is, in the workspace `bazel run` was run in. Returns the
/// process's exit code.
Future<int> recordGradleHostRepository(List<String> args) async {
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (args.length != 1 || workspace == null) {
    stderr.writeln(
      'usage: bazel run --config=deep //:record_gradle_host_repository '
      '(it writes the lock in the workspace)',
    );
    return 2;
  }
  final work = Directory.systemTemp.createTempSync('gradle_host_record');
  final client = HttpClient();
  try {
    final host = GradleHost(args.single, work);
    final built = await host.run(host.assembleTasks, offline: false);
    if (built != 0) {
      stderr.writeln('The online build failed; nothing was recorded.');
      return 1;
    }

    final downloaded = _downloadedFiles(host.gradleUserHome);
    final paths = {
      ...downloaded.keys,
      for (final path in downloaded.keys) ..._otherHostClassifiers(path),
    }.toList()..sort();
    final remotes = [
      for (final r in host.repositories)
        if (r.startsWith('https:')) r,
    ];

    final files = <String, Object>{};
    for (var i = 0; i < paths.length; i += 16) {
      final batch = paths.skip(i).take(16);
      final entries = await Future.wait([
        for (final path in batch)
          _lock(client, remotes, path, downloaded[path]),
      ]);
      for (final (path, entry) in entries) {
        files[path] = entry;
      }
    }
    File('$workspace/${host.lock}').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'files': files})}\n',
    );
    stdout.writeln('Wrote ${host.lock}: ${files.length} files.');
    return 0;
  } finally {
    client.close();
    work.deleteSync(recursive: true);
  }
}

String _cacheRoot(Directory gradleUserHome) =>
    '${gradleUserHome.path}/caches/modules-2/files-2.1';

/// The `group`, `module`, `version` and file name of a file in Gradle's
/// download cache, which lays one out as
/// `caches/modules-2/files-2.1/<group>/<module>/<version>/<sha1>/<file>`.
List<String> _cacheParts(Directory gradleUserHome, File file) {
  final cache = _cacheRoot(gradleUserHome);
  final parts = file.path.substring(cache.length + 1).split(RegExp(r'[\\/]'));
  if (parts.length != 5) {
    throw FormatException('unexpected file in Gradle cache: ${file.path}');
  }
  final [group, module, version, _, name] = parts;
  return [group, module, version, name];
}

/// Every file in Gradle's download cache, by its path in a Maven repository.
///
/// A component's Gradle module metadata gives each of its files' `url` in the
/// repository, relative to the component's directory, which may differ from
/// its name in the cache (`datastore-core.aar` is at
/// `datastore-core-android-1.2.1.aar`) or be another version's directory
/// (Guava's `-jre` component points at its `-android` jar).
Map<String, File> _downloadedFiles(Directory gradleUserHome) {
  final cache = Directory(_cacheRoot(gradleUserHome));
  final byComponent = <String, List<File>>{};
  for (final file in cache.listSync(recursive: true).whereType<File>()) {
    final [group, module, version, _] = _cacheParts(gradleUserHome, file);
    (byComponent['${group.replaceAll('.', '/')}/$module/$version'] ??= []).add(
      file,
    );
  }
  final files = <String, File>{};
  for (final MapEntry(key: directory, value: componentFiles)
      in byComponent.entries) {
    final urls = <String, String>{};
    for (final file in componentFiles.where(
      (f) => f.path.endsWith('.module'),
    )) {
      final metadata =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      for (final variant in metadata['variants'] as List<Object?>? ?? []) {
        for (final f in (variant! as Map)['files'] as List<Object?>? ?? []) {
          final {'name': String name, 'url': String url} = f! as Map;
          final path = Uri(path: '$directory/').resolve(url).path;
          if (urls[name] case final other? when other != path) {
            throw FormatException('$directory: $name is at $other and $path');
          }
          urls[name] = path;
        }
      }
    }
    for (final file in componentFiles) {
      final name = file.uri.pathSegments.last;
      files[urls[name] ?? '$directory/$name'] = file;
    }
  }
  return files;
}

/// For a file of one host's classifier, the paths of the others' files.
Iterable<String> _otherHostClassifiers(String path) sync* {
  for (final classifier in _hostClassifiers) {
    final suffix = '-$classifier.jar';
    if (!path.endsWith(suffix)) continue;
    final base = path.substring(0, path.length - suffix.length);
    for (final other in _hostClassifiers) {
      if (other != classifier) yield '$base-$other.jar';
    }
  }
}

/// The lock entry of [path]: the first of [remotes] that serves it, and the
/// SHA-256 of [cached], or of what that remote serves if nothing is cached.
Future<(String, Object)> _lock(
  HttpClient client,
  List<String> remotes,
  String path,
  File? cached,
) async {
  for (final remote in remotes) {
    final url = '$remote/$path';
    final request = await client.headUrl(Uri.parse(url));
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode == HttpStatus.notFound) continue;
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HEAD $url: ${response.statusCode}');
    }
    final Digest digest;
    if (cached != null) {
      digest = sha256.convert(cached.readAsBytesSync());
    } else {
      final get = await (await client.getUrl(Uri.parse(url))).close();
      if (get.statusCode != HttpStatus.ok) {
        throw HttpException('GET $url: ${get.statusCode}');
      }
      digest = await sha256.bind(get).single;
    }
    return (path, {'sha256': digest.toString(), 'url': url});
  }
  throw StateError('no repository of $remotes has $path');
}
