/// A throwaway Bazel workspace that fetches rules_flutter's repositories one at
/// a time, for tests of what a fetch does with the digest it is given.
///
/// ## The contract
///
/// **Input:** a list of [ProbeRepo]s — a repository rule of rules_flutter (or
/// the function that declares one) and the attributes to declare it with — and
/// the bytes of the archives the fetches may use.
///
/// **Output:** a [Probe] whose [Probe.fetch] runs `bazel fetch --repo=@name`
/// and reports the exit code and Bazel's output.
///
/// ## How a fetch gets bytes without the network
///
/// rules_flutter's engine URLs are fixed to Google Cloud Storage and GitHub, so
/// no test can point them at a local file. What Bazel does offer is `--distdir`:
/// a download that names a `sha256` is served from a file of the same name in
/// the distdir, if its digest matches, before any request is made. A fetch with
/// a *correct* digest therefore succeeds offline, and a fetch with *no* digest
/// cannot be served from there and goes to the network, where the test's fake
/// engine revision answers 404. That asymmetry is what lets a test tell "the
/// bytes were checked" from "the bytes were not asked about".
///
/// A hosted pub package takes a `base_url`, so it is served from `file://`
/// instead, and an unpinned fetch of it succeeds — which is the case that
/// shows plainly what an empty digest lets through.
///
/// Names in the generated workspace avoid the words a failing digest check
/// would print (`sha256`, `digest`, `checksum`), so a test can look for those
/// words in Bazel's output and mean it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart' show addTearDown;

import 'editable_workspace.dart';

/// An engine revision no bucket has: an unpinned fetch of it is a 404, fast.
const fakeEngineRevision = '0000000000000000000000000000000000000000';

/// A Flutter version no tag has, for the same reason.
const fakeFlutterVersion = '0.0.0';

/// One repository to declare in the generated workspace.
class ProbeRepo {
  const ProbeRepo(this.name, this.rule, this.attrs, {String? bzl})
    : bzl = bzl ?? rule;

  /// The apparent name, as given to `--repo=@name`.
  final String name;

  /// The symbol that declares the repository: a repository rule, or a
  /// function that calls one.
  final String rule;

  /// The file under `//flutter/private` that defines [rule], without `.bzl`,
  /// or the label of another module's file (`@rules_dart//...`).
  final String bzl;

  /// The label of the file defining [rule].
  String get bzlLabel =>
      bzl.startsWith('@') ? bzl : '@rules_flutter//flutter/private:$bzl.bzl';

  /// Starlark source of each attribute's value.
  final Map<String, String> attrs;
}

/// A hosted pub package's source repository [name] and the repository its
/// files are fetched into, from [baseUrl] and checked against [sha256], as
/// `flutter_pub.from_lock()` declares the two.
List<ProbeRepo> hostedPubPackage(
  String name, {
  required String package,
  required String version,
  required String sha256,
  required String baseUrl,
}) => [
  ProbeRepo(
    '${name}_files',
    'pub_archive_files',
    {
      'package_name': str(package),
      'version': str(version),
      'sha256': str(sha256),
      'base_url': str(baseUrl),
    },
    bzl: '@rules_dart//dart/pub:pub_lock_package.bzl',
  ),
  ProbeRepo(name, 'flutter_pub_package', {
    'files': str('@${name}_files//:BUILD.bazel'),
    'package_name': str(package),
  }),
];

/// A Flutter SDK package's source repository [name] and the repository its
/// files are extracted into from the Flutter source tarball of
/// [fakeFlutterVersion], checked against [sha256], as `flutter_pub.from_lock()`
/// declares the two. [packages] are those the release's source has.
List<ProbeRepo> sdkSourcePackage(
  String name, {
  required String package,
  required String sha256,
  required List<String> packages,
}) => [
  ProbeRepo('${name}_files', 'flutter_source_files', {
    'package_name': str(package),
    'flutter_version': str(fakeFlutterVersion),
    'sha256': str(sha256),
    'packages': '[${packages.map(str).join(', ')}]',
  }),
  ProbeRepo(name, 'flutter_pub_package', {
    'files': str('@${name}_files//:BUILD.bazel'),
    'package_name': str(package),
    'version': str('0.0.0'),
  }),
];

/// A Starlark string literal.
String str(String value) => jsonEncode(value);

/// A Starlark dict literal of strings.
String strDict(Map<String, String> entries) =>
    '{${entries.entries.map((e) => '${str(e.key)}: ${str(e.value)}').join(', ')}}';

/// The result of one `bazel fetch`.
class FetchResult {
  FetchResult(this.exitCode, this.output);

  final int exitCode;

  /// Bazel's stdout and stderr, together.
  final String output;

  bool get succeeded => exitCode == 0;

  /// True if Bazel's output speaks of a digest being required, missing or
  /// wrong: what a refusal to fetch unverified bytes would say.
  bool get namesTheDigest => RegExp(
    r'sha-?256|digest|checksum|integrity|pinned',
    caseSensitive: false,
  ).hasMatch(output);

  @override
  String toString() => 'exit $exitCode\n$output';
}

/// A generated workspace that can fetch the repositories it was given.
class Probe {
  Probe._(this._workspace);

  final EditableWorkspace _workspace;

  /// The workspace's root.
  String get root => _workspace.root;

  /// Where `--distdir` points; each archive is a file here.
  String get distdir => p.join(_workspace.root, 'distdir');

  /// Runs `bazel [args]` in the workspace.
  Future<FetchResult> bazel(List<String> args) async {
    final result = await Process.run(
      'bazel',
      args,
      workingDirectory: _workspace.root,
    );
    return FetchResult(result.exitCode, '${result.stdout}\n${result.stderr}');
  }

  /// Fetch repository [name], and nothing else.
  ///
  /// No retries: an unpinned fetch of a revision that does not exist is a 404,
  /// which is not retried, but a host without a network would otherwise spend
  /// minutes failing the same way.
  Future<FetchResult> fetch(String name) async {
    final result = await Process.run('bazel', [
      'fetch',
      '--repo=@$name',
      '--experimental_repository_downloader_retries=0',
    ], workingDirectory: _workspace.root);
    return FetchResult(result.exitCode, '${result.stdout}\n${result.stderr}');
  }
}

/// Generate a workspace declaring [repos], with [archives] (file name to bytes)
/// in its distdir.
///
/// Call from `setUpAll`: the workspace is disposed after the group.
///
/// Repositories that find each other by name through one module extension (a
/// hub's, `flutter_pub_index.bzl`) can only be declared by one: [extension] is
/// the source of a module extension named `probe` that declares them, and
/// [extensionRepos] the names it makes, which are `use_repo`d into the probe.
Future<Probe> probe({
  required List<ProbeRepo> repos,
  Map<String, List<int>> archives = const {},
  String? extension,
  List<String> extensionRepos = const [],
}) async {
  final repoRoot = p.normalize(p.join(Directory.current.path, '..', '..'));
  final rulesDart = RegExp(
    r'bazel_dep\(name = "rules_dart", version = "([^"]+)"\)',
  ).firstMatch(File(p.join(repoRoot, 'MODULE.bazel')).readAsStringSync());
  if (rulesDart == null) {
    throw StateError('no bazel_dep on rules_dart in $repoRoot/MODULE.bazel');
  }

  final module = StringBuffer()
    ..writeln('module(name = "fetch_probe")')
    ..writeln('bazel_dep(name = "rules_flutter", version = "0.0.0")')
    ..writeln('bazel_dep(name = "rules_dart", version = "${rulesDart[1]}")');
  // Declared by an extension of the probe's own, which can call both a
  // repository rule and a function that declares one, as rules_flutter's own
  // extensions do.
  final declarations = StringBuffer();
  for (final repo in {for (final r in repos) r.rule: r}.values) {
    declarations.writeln('load("${repo.bzlLabel}", "${repo.rule}")');
  }
  declarations
    ..writeln('\ndef _declare(module_ctx):')
    ..writeln('    pass');
  for (final repo in repos) {
    final attrs = repo.attrs.entries.map((e) => '${e.key} = ${e.value}');
    declarations.writeln(
      '    ${repo.rule}(name = ${str(repo.name)}, ${attrs.join(', ')})',
    );
  }
  declarations.writeln('\nprobe_repos = module_extension(_declare)');
  module
    ..writeln(
      'probe_repos = use_extension("//:probe_repos.bzl", "probe_repos")',
    )
    ..writeln(
      'use_repo(probe_repos, ${repos.map((r) => str(r.name)).join(', ')})',
    );
  if (extension != null) {
    module
      ..writeln('probe = use_extension("//:probe_extension.bzl", "probe")')
      ..writeln('use_repo(probe, ${extensionRepos.map(str).join(', ')})');
  }

  // The repo's own .bazelrc.user carries a developer's overrides (on this
  // project, rules_dart from a sibling checkout), so the probe resolves the
  // same code the rest of the suite does. Absent in CI; try-import allows it.
  final userConfig = repositoryUserConfigFor(repoRoot, module.toString());
  final workspace = await generatedWorkspace('fetch_probe', {
    'MODULE.bazel': module.toString(),
    'BUILD.bazel': '',
    'probe_repos.bzl': declarations.toString(),
    if (extension != null) 'probe_extension.bzl': extension,
    if (userConfig != null) '.bazelrc.user': userConfig,
    '.bazelrc': [
      'try-import %workspace%/.bazelrc.user',
      'common --lockfile_mode=off',
      'common --override_module=rules_flutter=${_rc(repoRoot)}',
    ].join('\n'),
  });

  final probe = Probe._(workspace);
  final dist = Directory(probe.distdir)..createSync();
  File(p.join(workspace.root, '.bazelrc')).writeAsStringSync(
    '\ncommon --distdir=${_rc(dist.path)}\n',
    mode: FileMode.append,
  );
  for (final entry in archives.entries) {
    File(p.join(dist.path, entry.key)).writeAsBytesSync(entry.value);
  }
  return probe;
}

/// Serve a hosted pub package from a directory, returning the `base_url` that
/// reaches it: `file://` plus the layout pub.dev uses.
///
/// The directory is removed when the current test scope ends.
Future<String> servePubArchive(
  String package,
  String version,
  List<int> archive,
) async {
  final dir = await Directory.systemTemp.createTemp('pub_fixture_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File(p.join(dir.path, 'packages', package, 'versions', '$version.tar.gz'))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(archive);
  return Uri.file(dir.path).toString();
}

/// A path as a Bazel rc file reads it (backslashes are escapes there).
String _rc(String path) => path.replaceAll(r'\', '/');

/// The lowercase hex SHA-256 of [bytes].
String sha256Hex(List<int> bytes) {
  const k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2, //
  ];
  const mask = 0xffffffff;
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & mask;

  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  final bitLength = bytes.length * 8;
  final padded = <int>[...bytes, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLength >> (i * 8)) & 0xff);
  }

  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < padded.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final j = chunk + i * 4;
      w[i] =
          (padded[j] << 24) |
          (padded[j + 1] << 16) |
          (padded[j + 2] << 8) |
          padded[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & mask;
    }
    var [a, b, c, d, e, f, g, hh] = h;
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ (~e & mask & g);
      final t1 = (hh + s1 + ch + k[i] + w[i]) & mask;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & mask;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & mask;
    }
    final next = [a, b, c, d, e, f, g, hh];
    for (var i = 0; i < 8; i++) {
      h[i] = (h[i] + next[i]) & mask;
    }
  }
  return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
}

/// A zip archive (entries stored, not compressed) of [files].
List<int> zipOf(Map<String, String> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  int u16(int v) => v & 0xffff;
  void put16(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  void put32(BytesBuilder b, int v) =>
      b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final data = utf8.encode(entry.value);
    final crc = _crc32(data);
    final offset = out.length;

    out..add([0x50, 0x4b, 0x03, 0x04]);
    put16(out, 20); // version needed
    put16(out, 0); // flags
    put16(out, 0); // stored
    put16(out, 0); // time
    put16(out, 0x21); // date: 1980-01-01
    put32(out, crc);
    put32(out, data.length);
    put32(out, data.length);
    put16(out, u16(name.length));
    put16(out, 0);
    out
      ..add(name)
      ..add(data);

    central.add([0x50, 0x4b, 0x01, 0x02]);
    put16(central, 20);
    put16(central, 20);
    put16(central, 0);
    put16(central, 0);
    put16(central, 0);
    put16(central, 0x21);
    put32(central, crc);
    put32(central, data.length);
    put32(central, data.length);
    put16(central, u16(name.length));
    put16(central, 0);
    put16(central, 0);
    put16(central, 0);
    put16(central, 0);
    put32(central, 0);
    put32(central, offset);
    central.add(name);
  }

  final centralOffset = out.length;
  final centralBytes = central.toBytes();
  out
    ..add(centralBytes)
    ..add([0x50, 0x4b, 0x05, 0x06]);
  put16(out, 0);
  put16(out, 0);
  put16(out, u16(files.length));
  put16(out, u16(files.length));
  put32(out, centralBytes.length);
  put32(out, centralOffset);
  put16(out, 0);
  return out.toBytes();
}

/// A gzipped tar archive of [files], the shape of a pub.dev package download.
List<int> tarGzOf(Map<String, String> files) {
  final out = BytesBuilder();
  for (final entry in files.entries) {
    final data = utf8.encode(entry.value);
    final header = Uint8List(512);
    void field(int offset, String text) {
      final bytes = ascii.encode(text);
      header.setRange(offset, offset + bytes.length, bytes);
    }

    field(0, entry.key);
    field(100, '0000644\u0000');
    field(108, '0000000\u0000');
    field(116, '0000000\u0000');
    field(124, '${data.length.toRadixString(8).padLeft(11, '0')}\u0000');
    field(136, '${'0'.padLeft(11, '0')}\u0000');
    field(148, '        '); // checksum placeholder: eight spaces
    field(156, '0');
    field(257, 'ustar\u0000');
    field(263, '00');
    final sum = header.fold<int>(0, (a, b) => a + b);
    field(148, '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ');

    out
      ..add(header)
      ..add(data)
      ..add(Uint8List((512 - data.length % 512) % 512));
  }
  out.add(Uint8List(1024));
  return gzip.encode(out.toBytes());
}

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}
