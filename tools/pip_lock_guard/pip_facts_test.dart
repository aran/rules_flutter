/// Guards that `MODULE.bazel.lock`'s pip extension facts are still the facts a
/// Linux host computes.
///
/// ## Why this test exists at all
///
/// `.bazelrc` enforces `--lockfile_mode=error`, but a developer here loses it
/// the moment they add the `--override_module` line for a sibling rules_dart
/// checkout, since an override forces `--lockfile_mode` off — and every
/// checkout has that line.
///
/// A `bazel test` is immune to that. This one runs inside `bazel test //...`
/// on every host, reads the committed lock as data, and re-derives what the
/// facts must contain from checked-in inputs. It needs no network, no nested
/// Bazel, and no particular host.
///
/// ## What makes the derivation exact
///
/// The pip extension records, for every package it resolves, the sha256 of each
/// distribution file it found on the index. Three requirements files account
/// for every package in the recording:
///
///  * `//tools/ios_screenshot:requirements_lock.txt` — the one hub this module
///    declares. It passes explicit `target_platforms`, so what it contributes
///    is the same on every host.
///  * `rules_python_publish_requirements_{linux,darwin,windows}.txt` —
///    verbatim copies of rules_python's own `tools/publish/requirements_*.txt`.
///    Its (non-dev) `pip.parse` for `rules_python_publish_deps` names all three
///    through `requirements_by_platform` and passes no `target_platforms`.
///
///    **All three contribute, on every host.** Under facts `v1` (rules_python
///    2.0.0 and earlier) `hub_builder.bzl` fell back to `"{os}_{arch}"` and
///    read only the file matching the resolving host, so no single recording
///    could satisfy every host. Under `v2` the union is recorded instead: a
///    cold ubuntu-24.04 x86_64 VM and macOS arm64 produce byte-identical locks,
///    including the Linux-only `jeepney`/`secretstorage` and the Windows-only
///    `pywin32-ctypes`. That is what lets `.bazelrc` carry plain
///    `--lockfile_mode=error` on every host.
///
/// The copies are vendored rather than depended on because
/// `@rules_python//tools/publish` exports nothing: its only filegroup is
/// visible to `//tools:__subpackages__` within rules_python, and naming the
/// source files from this module fails analysis with a visibility error. The
/// version assertion below is what keeps them honest — a rules_python bump
/// fails this test rather than silently validating against stale copies.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Canonical repo name of this test, threaded in by the BUILD target so
/// `package:runfiles` can translate the apparent repo names used as keys below.
const String _sourceRepository = String.fromEnvironment('RUNFILES_SOURCE_REPO');

/// Runfiles keys for every file this test reads. Each is a `-D` define set from
/// the matching `data` entry in BUILD.bazel, so a file can never be located by
/// guessing or by walking the tree.
const String _lockKey = String.fromEnvironment('PIP_FACTS_LOCK');
const String _moduleKey = String.fromEnvironment('PIP_FACTS_MODULE');
const String _iosRequirementsKey = String.fromEnvironment(
  'PIP_FACTS_IOS_REQUIREMENTS',
);
const String _publishLinuxKey = String.fromEnvironment(
  'PIP_FACTS_PUBLISH_LINUX',
);
const String _publishDarwinKey = String.fromEnvironment(
  'PIP_FACTS_PUBLISH_DARWIN',
);
const String _publishWindowsKey = String.fromEnvironment(
  'PIP_FACTS_PUBLISH_WINDOWS',
);

/// The rules_python release the vendored publish requirements were copied from.
///
/// A bump means the three vendored `tools/publish/requirements_*.txt` copies
/// must be refreshed, and the facts schema re-checked — see
/// [_expectedFactVersion].
const String _expectedRulesPythonVersion = '2.3.2';

/// The facts schema the derivation below is written against.
///
/// Asserted rather than left to fail obscurely: `v1` carried a second
/// `index_urls` map beside `dist_hashes` and recorded only the resolving host's
/// requirements file, `v2` drops `index_urls` and records the union of all of
/// them. A guard written for one shape reads the other as an empty or
/// half-missing recording, which is a confusing way to learn the schema moved.
const String _expectedFactVersion = 'v2';

/// The `requirements_lock` labels this test knows how to derive from. If
/// MODULE.bazel grows another pip hub, the derivation silently stops covering
/// the whole recording, so the list is asserted rather than assumed.
const Set<String> _knownRequirementsLabels = {
  '//tools/ios_screenshot:requirements_lock.txt',
};

/// How many `pip.parse` calls MODULE.bazel makes: one hub x two Python
/// versions. Counted as well as matched by label because `pip.parse` can name
/// its requirements through `requirements_by_platform` or the per-OS
/// `requirements_linux`/`_darwin`/`_windows` attributes, none of which the
/// label scan above would see — a hub declared that way would otherwise slip
/// past this guard entirely.
const int _expectedPipParseCount = 2;

/// The pip extension's id in the lock's `facts` map, minus the canonical repo
/// name prefix that varies with how rules_python is resolved.
const String _pipExtensionSuffix = '//python/extensions:pip.bzl%pip';

void main() {
  final runfiles = Runfiles.create(sourceRepository: _sourceRepository);
  String read(String key) => File(runfiles.rlocation(key)).readAsStringSync();

  // `late final` locals are evaluated on first read, which keeps the tests
  // independent: a lock whose *shape* this guard no longer understands throws
  // from `_pipFacts` in the tests that read the recording, while the version
  // test below — the one carrying the "refresh the vendored copy" procedure —
  // still runs and still reports. A rules_python bump is the likeliest way both
  // happen at once, and that is exactly when its message needs to be visible.
  late final Map<String, dynamic> lock =
      jsonDecode(read(_lockKey)) as Map<String, dynamic>;
  late final _PipFacts facts = _pipFacts(lock);
  late final Map<String, Set<String>> expected = _expectedDistHashes({
    'ios_screenshot': read(_iosRequirementsKey),
    'rules_python publish (linux)': read(_publishLinuxKey),
    'rules_python publish (darwin)': read(_publishDarwinKey),
    'rules_python publish (windows)': read(_publishWindowsKey),
  });

  test(
    'the lock still selects the rules_python this guard was written for',
    () {
      expect(
        _selectedRulesPythonVersion(lock),
        _expectedRulesPythonVersion,
        reason:
            'rules_python moved. Refresh all three '
            'tools/pip_lock_guard/rules_python_publish_requirements_*.txt '
            'copies from the new release\'s tools/publish/requirements_*.txt, '
            'then update _expectedRulesPythonVersion.',
      );
    },
  );

  test('the recorded facts still use the schema this guard reads', () {
    expect(
      facts.factVersion,
      _expectedFactVersion,
      reason:
          'The pip extension changed how it records facts. Re-read what the '
          'new schema contains before touching the expectations below: the '
          'v1 -> v2 move dropped the index_urls map and, more importantly, '
          'went from recording only the resolving host\'s requirements file to '
          'recording the union of all of them — which is what makes the lock '
          'host-independent and .bazelrc\'s plain --lockfile_mode=error safe. '
          'A schema that goes back to per-host recording needs that relaxation '
          'back.',
    );
  });

  test('MODULE.bazel declares only the pip hubs this guard derives from', () {
    final module = read(_moduleKey);
    expect(
      _requirementsLabels(module),
      _knownRequirementsLabels,
      reason:
          'MODULE.bazel changed which requirements files feed the pip '
          'extension. Update _knownRequirementsLabels and this test\'s data '
          'deps, or the derivation below stops covering the whole recording.',
    );
    expect(
      _pipParseCount(module),
      _expectedPipParseCount,
      reason:
          'MODULE.bazel gained or lost a pip.parse call. If a new one '
          'names its requirements through requirements_by_platform or the '
          'per-OS attributes, the label check above cannot see it — add its '
          'requirements file to this test\'s data deps and derivation.',
    );
  });

  test('recorded pip facts cover exactly the expected packages', () {
    expect(
      _sorted(facts.distHashes.keys),
      _sorted(expected.keys),
      reason:
          'MODULE.bazel.lock\'s pip facts do not match the packages the '
          'checked-in requirements files imply. Read the diff before reaching '
          'for a diagnosis: losing exactly the Linux-only packages (jeepney, '
          'secretstorage) means the lock was regenerated on macOS and gaining '
          'pywin32-ctypes means Windows, but any change to the requirements '
          'files themselves lands here too. In every case the lock must be '
          'regenerated on Linux — see .bazelrc.',
    );
  });

  test('recorded pip facts record exactly the expected hashes', () {
    final problems = <String>[];
    for (final package in _sorted(expected.keys)) {
      final recorded = facts.distHashes[package];
      if (recorded == null) continue; // Reported by the package-set test.
      final recordedHashes = _sorted(recorded.values);
      final expectedHashes = _sorted(expected[package]!);
      if (!_listEquals(recordedHashes, expectedHashes)) {
        problems.add(
          '$package:\n'
          '  recorded: ${recordedHashes.join(', ')}\n'
          '  expected: ${expectedHashes.join(', ')}',
        );
      }
    }
    expect(
      problems,
      isEmpty,
      reason:
          'The sha256 set recorded for these packages differs from the '
          '--hash= lines in the checked-in requirements files. A requirements '
          'bump landed without regenerating MODULE.bazel.lock on Linux.',
    );
  });
}

/// The pip extension's facts entry, as far as this guard reads it.
class _PipFacts {
  /// package name -> {distribution url: sha256}.
  final Map<String, Map<String, String>> distHashes;

  /// The recording's own schema tag, checked against [_expectedFactVersion]
  /// before anything derived from [distHashes] is believed.
  final String factVersion;

  _PipFacts(this.distHashes, this.factVersion);
}

_PipFacts _pipFacts(Map<String, dynamic> lock) {
  final allFacts = lock['facts'] as Map<String, dynamic>?;
  if (allFacts == null) {
    throw StateError(
      'MODULE.bazel.lock has no top-level "facts" map. The '
      'lock format changed; this guard needs updating.',
    );
  }
  final ids = allFacts.keys.where((k) => k.endsWith(_pipExtensionSuffix));
  if (ids.length != 1) {
    throw StateError(
      'expected exactly one pip extension in MODULE.bazel.lock '
      'facts, found ${ids.length}: ${ids.join(', ')}',
    );
  }
  final entry = allFacts[ids.single] as Map<String, dynamic>;
  return _PipFacts(
    _singleIndex(entry, 'dist_hashes').map(
      (k, v) => MapEntry(
        _normalize(k),
        (v as Map).cast<String, String>().map(
          (url, hash) => MapEntry(url, _bareSha256(hash)),
        ),
      ),
    ),
    entry['fact_version'] as String? ?? '(absent)',
  );
}

/// A recorded hash as bare hex.
///
/// Facts `v2` spells them `sha256:<hex>`; `v1` recorded the hex alone, and the
/// `--hash=sha256:<hex>` lines the expectation is derived from are parsed down
/// to the hex too. Stripping here keeps one vocabulary on both sides of the
/// comparison rather than teaching the derivation a second one.
String _bareSha256(String recorded) => recorded.startsWith('sha256:')
    ? recorded.substring('sha256:'.length)
    : recorded;

/// Reads `entry[field]`, which is keyed by index url, and returns the sole
/// index's map. More than one index would mean MODULE.bazel started using a
/// second package source and this guard no longer describes the recording.
Map<String, dynamic> _singleIndex(Map<String, dynamic> entry, String field) {
  final byIndex = entry[field] as Map<String, dynamic>?;
  if (byIndex == null || byIndex.length != 1) {
    throw StateError(
      'expected exactly one package index in facts["$field"], '
      'found ${byIndex?.keys.join(', ') ?? 'nothing'}',
    );
  }
  return byIndex.values.single as Map<String, dynamic>;
}

/// The rules_python version bzlmod selected, read from the lock.
///
/// Every candidate version contributes a `MODULE.bazel` entry to
/// `registryFileHashes`, but only the selected one contributes a `source.json`.
String _selectedRulesPythonVersion(Map<String, dynamic> lock) {
  final hashes = lock['registryFileHashes'] as Map<String, dynamic>;
  final pattern = RegExp(r'/modules/rules_python/([^/]+)/source\.json$');
  final versions = hashes.keys
      .map(pattern.firstMatch)
      .nonNulls
      .map((m) => m.group(1)!)
      .toSet();
  if (versions.length != 1) {
    throw StateError(
      'expected exactly one selected rules_python version in '
      'registryFileHashes, found ${versions.length}: ${versions.join(', ')}',
    );
  }
  return versions.single;
}

/// Every `requirements_lock = "..."` label in MODULE.bazel.
Set<String> _requirementsLabels(String moduleBazel) => RegExp(
  r'requirements_lock\s*=\s*"([^"]+)"',
).allMatches(moduleBazel).map((m) => m.group(1)!).toSet();

/// How many times MODULE.bazel calls `pip.parse`, however it spells its
/// requirements attribute.
int _pipParseCount(String moduleBazel) =>
    RegExp(r'\bpip\.parse\s*\(').allMatches(moduleBazel).length;

/// package name -> the union of its `--hash=sha256:` values across [sources].
///
/// A package pinned at different versions by two files (cffi, cryptography and
/// pycparser are pinned by both our requirements and rules_python's) is
/// recorded by the extension with the distributions of both pins, so the union
/// is what the recording holds.
Map<String, Set<String>> _expectedDistHashes(Map<String, String> sources) {
  final result = <String, Set<String>>{};
  final pin = RegExp(r'^([A-Za-z0-9._-]+)==');
  final hash = RegExp(r'--hash=sha256:([0-9a-f]{64})');
  for (final contents in sources.values) {
    String? package;
    for (final line in const LineSplitter().convert(contents)) {
      final match = pin.firstMatch(line);
      if (match != null) package = _normalize(match.group(1)!);
      if (package == null) continue;
      for (final h in hash.allMatches(line)) {
        (result[package] ??= <String>{}).add(h.group(1)!);
      }
    }
  }
  return result;
}

/// PyPI's canonical package spelling: lowercase, underscores as hyphens.
String _normalize(String name) => name.toLowerCase().replaceAll('_', '-');

List<String> _sorted(Iterable<String> values) => values.toList()..sort();

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
