/// `bazel run @<hub>//swift:packages`: prints what the root module declares
/// for the remote Swift packages a lock's Apple plugins depend on.
///
/// The root module owns those packages: its `Package.swift` lists them, its
/// rules_swift_package_manager declares a repository per pin of its
/// `Package.resolved`, and `inject_repo` hands each repository a plugin names
/// to rules_flutter's pub extension. This prints the `Package.swift` lines,
/// one per package with a requirement every plugin accepts, and the
/// `MODULE.bazel` lines, and marks the packages the root's `Package.resolved`
/// is missing or pins at a version some plugin does not accept.
///
/// It reads what each plugin's Apple repository recorded of its manifest
/// (`swift_requirements.json`), so it runs no Swift tooling.
library;

import 'dart:convert';
import 'dart:io';

import 'pub_runfiles.dart';

const _config = String.fromEnvironment('rules_flutter.swift_packages.config');

/// The rules_swift_package_manager version rules_flutter's own tests build
/// plugins' Swift packages with (`e2e/ios_example/MODULE.bazel`).
const rulesSwiftPackageManagerVersion = '1.25.0';

/// What a manifest's `.package(url:, ...)` requires of a package, as
/// `swift package dump-package` writes it.
sealed class Requirement {
  const Requirement();

  /// The requirement of a `dump-package` dependency's `requirement` value.
  factory Requirement.fromJson(Map<String, dynamic> json) {
    if (json['exact'] case [final String version]) return Exact(version);
    if (json['range'] case [
      {'lowerBound': final String lower, 'upperBound': final String upper},
    ]) {
      return Range(lower, upper);
    }
    if (json['branch'] case [final String branch]) return Branch(branch);
    if (json['revision'] case [final String revision])
      return Revision(revision);
    throw FormatException(
      'unknown Swift package requirement ${jsonEncode(json)}',
    );
  }

  /// How `Package.swift` writes it after the URL.
  String get swift;

  /// Whether [pin] meets it.
  bool accepts(Pin pin);
}

final class Exact extends Requirement {
  const Exact(this.version);
  final String version;

  @override
  String get swift => 'exact: "$version"';

  @override
  bool accepts(Pin pin) =>
      pin.version != null && compareVersions(pin.version!, version) == 0;

  @override
  String toString() => 'exact $version';

  @override
  bool operator ==(Object other) => other is Exact && other.version == version;

  @override
  int get hashCode => version.hashCode;
}

/// Versions from [lower] up to, and not including, [upper].
final class Range extends Requirement {
  const Range(this.lower, this.upper);
  final String lower;
  final String upper;

  @override
  String get swift {
    final parts = _parse(lower);
    if (parts != null && parts.prerelease.isEmpty) {
      final [major, minor, _] = parts.numbers;
      if (upper == '${major + 1}.0.0') return 'from: "$lower"';
      if (upper == '$major.${minor + 1}.0') {
        return '.upToNextMinor(from: "$lower")';
      }
    }
    return '"$lower"..<"$upper"';
  }

  @override
  bool accepts(Pin pin) =>
      pin.version != null &&
      compareVersions(pin.version!, lower) >= 0 &&
      compareVersions(pin.version!, upper) < 0;

  @override
  String toString() => '$lower to below $upper';

  @override
  bool operator ==(Object other) =>
      other is Range && other.lower == lower && other.upper == upper;

  @override
  int get hashCode => Object.hash(lower, upper);
}

final class Branch extends Requirement {
  const Branch(this.branch);
  final String branch;

  @override
  String get swift => 'branch: "$branch"';

  @override
  bool accepts(Pin pin) => pin.branch == branch;

  @override
  String toString() => 'branch $branch';

  @override
  bool operator ==(Object other) => other is Branch && other.branch == branch;

  @override
  int get hashCode => branch.hashCode;
}

final class Revision extends Requirement {
  const Revision(this.revision);
  final String revision;

  @override
  String get swift => 'revision: "$revision"';

  @override
  bool accepts(Pin pin) => pin.revision == revision;

  @override
  String toString() => 'revision $revision';

  @override
  bool operator ==(Object other) =>
      other is Revision && other.revision == revision;

  @override
  int get hashCode => revision.hashCode;
}

/// What a `Package.resolved` records for a package.
typedef Pin = ({String? version, String? branch, String revision});

String _pinText(Pin pin) =>
    pin.version ??
    (pin.branch != null
        ? 'branch ${pin.branch} (${pin.revision})'
        : 'revision ${pin.revision}');

/// The pins of a `Package.resolved` (version 1, 2 or 3), by identity.
Map<String, Pin> parsePackageResolved(String content) {
  final data = jsonDecode(content) as Map<String, dynamic>;
  Pin pin(Map<String, dynamic> state) => (
    version: state['version'] as String?,
    branch: state['branch'] as String?,
    revision: (state['revision'] as String?) ?? '',
  );
  if (data['version'] == 1) {
    return {
      for (final entry
          in ((data['object'] as Map)['pins'] as List)
              .cast<Map<String, dynamic>>())
        _identityOfUrl(entry['repositoryURL'] as String): pin(
          (entry['state'] as Map).cast<String, dynamic>(),
        ),
    };
  }
  return {
    for (final entry in (data['pins'] as List).cast<Map<String, dynamic>>())
      entry['identity'] as String: pin(
        (entry['state'] as Map).cast<String, dynamic>(),
      ),
  };
}

String _identityOfUrl(String url) {
  var identity = url.replaceAll(RegExp(r'/+$'), '').split('/').last;
  identity = identity.toLowerCase();
  return identity.endsWith('.git')
      ? identity.substring(0, identity.length - 4)
      : identity;
}

/// One plugin's requirement of a package.
typedef Need = ({String plugin, String url, Requirement requirement});

/// The requirement that meets every one of [needs], or null when none does.
///
/// Every version requirement is a range of versions (an exact one is a range
/// of one), and the answer is their overlap. A branch or a revision meets
/// only the same branch or revision.
Requirement? combine(List<Requirement> needs) {
  final distinct = needs.toSet();
  if (distinct.length == 1) return distinct.single;
  if (distinct.any((r) => r is Branch || r is Revision)) return null;
  final exact = distinct.whereType<Exact>().map((e) => e.version).toSet();
  final ranges = distinct.whereType<Range>().toList();
  if (exact.length > 1) return null;
  if (exact.length == 1) {
    final version = exact.single;
    final pin = (version: version, branch: null, revision: '');
    return ranges.every((r) => r.accepts(pin)) ? Exact(version) : null;
  }
  var lower = ranges.first.lower;
  var upper = ranges.first.upper;
  for (final range in ranges.skip(1)) {
    if (compareVersions(range.lower, lower) > 0) lower = range.lower;
    if (compareVersions(range.upper, upper) < 0) upper = range.upper;
  }
  return compareVersions(lower, upper) < 0 ? Range(lower, upper) : null;
}

/// The repository rules_swift_package_manager declares for [identity].
String repositoryOf(String identity) =>
    'swiftpkg_${identity.replaceAll('-', '_')}';

/// The text the program prints, and whether the plugins' requirements of
/// some package conflict.
///
/// [needs] are each package's plugins' requirements, by identity. [pins] is
/// the root's `Package.resolved`, null when no tag names one; [resolved] is
/// its path as the tag names it.
({String text, bool conflict}) formatReport({
  required String hub,
  required Map<String, List<Need>> needs,
  required Map<String, Pin>? pins,
  required String? resolved,
}) {
  if (needs.isEmpty) {
    return (
      text:
          '// No Apple plugin of @$hub depends on a remote Swift package: '
          'the root module declares none for them.\n',
      conflict: false,
    );
  }
  final resolvedName = resolved ?? 'Package.resolved';
  final packageLines = <String>[];
  var conflict = false;
  var marked = 0;
  final identities = needs.keys.toList()..sort();
  for (final identity in identities) {
    final list = needs[identity]!;
    final by = list.map((n) => n.plugin).toSet().join(', ');
    final requirement = combine([for (final n in list) n.requirement]);
    final url = list.first.url;
    if (requirement == null) {
      conflict = true;
      packageLines.add(
        '// .package(url: "$url", ...),  // no version meets every plugin: '
        '${list.map((n) => '${n.plugin} requires ${n.requirement}').toSet().join('; ')}',
      );
      continue;
    }
    final notes = [by];
    final pin = pins?[identity];
    if (pins == null) {
      // Nothing to compare against.
    } else if (pin == null) {
      notes.add('missing from $resolvedName');
      marked++;
    } else if (!requirement.accepts(pin)) {
      notes.add('$resolvedName pins ${_pinText(pin)}');
      marked++;
    }
    packageLines.add(
      '.package(url: "$url", ${requirement.swift}),  // ${notes.join('; ')}',
    );
  }
  final repos = identities.map((i) => '"${repositoryOf(i)}"').join(', ');
  final out = <String>[
    '// The remote Swift packages the Apple plugins of @$hub depend on.',
    if (pins == null)
      '// No `flutter_pub.from_lock` of @$hub names the root\'s '
          '`Package.resolved` in `swift_package_resolved`, so none is checked.'
    else if (marked > 0)
      '// $marked of ${identities.length} are missing from $resolvedName '
          'or pinned at a version a plugin does not accept (marked).'
    else if (!conflict)
      '// $resolvedName pins all ${identities.length} at versions the plugins accept.',
    if (conflict)
      '// The plugins\' requirements of some package conflict (marked): '
          'no version meets them all, so no build has every plugin.',
    '',
    '// In the `dependencies` of the root module\'s Package.swift:',
    '',
    ...packageLines.map((line) => '    $line'),
    '',
    '# In the root MODULE.bazel (`bazel mod tidy` keeps the `use_repo`):',
    '',
    '    bazel_dep(name = "rules_swift_package_manager", '
        'version = "$rulesSwiftPackageManagerVersion")',
    '',
    '    swift_deps = use_extension("@rules_swift_package_manager//:extensions.bzl", "swift_deps")',
    '    swift_deps.from_package(',
    '        resolved = "${resolved ?? '//:Package.resolved'}",',
    '        swift = "//:Package.swift",',
    '    )',
    '    use_repo(swift_deps, "swift_package", $repos)',
    '',
    '    # flutter_pub being your use_extension of rules_flutter\'s pub extension:',
    '    inject_repo(flutter_pub, $repos)',
    if (pins == null)
      '    # and in flutter_pub.from_lock(name = "$hub", ...): '
          'swift_package_resolved = "//:Package.resolved",',
    '',
    '# Then pin them: bazel run @swift_package//:update',
  ];
  return (text: '${out.join('\n')}\n', conflict: conflict);
}

/// The plugins' needs, from their `swift_requirements.json` files' contents.
Map<String, List<Need>> needsOf(Iterable<String> listings) {
  final needs = <String, List<Need>>{};
  for (final listing in listings) {
    final info = jsonDecode(listing) as Map<String, dynamic>;
    final plugin = 'package:${info['package']} ${info['version']}';
    final platforms = (info['platforms'] as Map).cast<String, List>();
    for (final platform in platforms.keys.toList()..sort()) {
      for (final entry in platforms[platform]!.cast<Map<String, dynamic>>()) {
        final need = (
          plugin: plugin,
          url: entry['url'] as String,
          requirement: Requirement.fromJson(
            (entry['requirement'] as Map).cast<String, dynamic>(),
          ),
        );
        final list = needs.putIfAbsent(entry['identity'] as String, () => []);
        if (!list.contains(need)) list.add(need);
      }
    }
  }
  return needs;
}

Never _fail(String message) {
  stderr.writeln('swift:packages: $message');
  exit(1);
}

Future<void> main(List<String> args) async {
  final runfiles = Runfiles.discover(
    Platform.environment,
    Platform.resolvedExecutable,
  );
  String find(String path) =>
      runfiles.rlocation(path) ?? _fail('missing runfile $path');
  final config = jsonDecode(
    File(find(_config)).readAsStringSync(),
  ) as Map<String, dynamic>;
  final hub = config['hub'] as String;
  final needs = needsOf([
    for (final path in (config['requirements'] as List).cast<String>())
      File(find(path)).readAsStringSync(),
  ]);

  final resolved = config['resolved'] as String;
  Map<String, Pin>? pins;
  if (resolved.isNotEmpty) {
    if (resolved.startsWith('@')) {
      _fail(
        'the `swift_package_resolved` of `flutter_pub.from_lock(name = '
        '"$hub")` is $resolved, a file of another repository. The root '
        'module declares the Swift packages; name its own Package.resolved.',
      );
    }
    final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
    if (workspace == null || workspace.isEmpty) {
      _fail('BUILD_WORKSPACE_DIRECTORY is not set. Use `bazel run`.');
    }
    final file = File('$workspace/$resolved');
    pins = file.existsSync()
        ? parsePackageResolved(file.readAsStringSync())
        : <String, Pin>{};
  }
  final report = formatReport(
    hub: hub,
    needs: needs,
    pins: pins,
    resolved: resolved.isEmpty ? null : '//${_asLabelPath(resolved)}',
  );
  stdout.write(report.text);
  if (report.conflict) exit(1);
}

/// `dir/Package.resolved` as the label `//dir:Package.resolved` writes it,
/// less the leading `//`.
String _asLabelPath(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0
      ? ':$path'
      : '${path.substring(0, slash)}:${path.substring(slash + 1)}';
}

/// -1, 0 or 1 as semantic version [a] is below, equal to or above [b], as
/// SwiftPM orders them: build metadata is ignored, and a prerelease is below
/// its release.
int compareVersions(String a, String b) {
  final pa = _parse(a), pb = _parse(b);
  if (pa == null || pb == null) {
    throw FormatException('not a semantic version: ${pa == null ? a : b}');
  }
  for (var i = 0; i < 3; i++) {
    final c = pa.numbers[i].compareTo(pb.numbers[i]);
    if (c != 0) return c.sign;
  }
  final ra = pa.prerelease, rb = pb.prerelease;
  if (ra.isEmpty || rb.isEmpty) {
    return ra.isEmpty == rb.isEmpty ? 0 : (ra.isEmpty ? 1 : -1);
  }
  for (var i = 0; i < ra.length && i < rb.length; i++) {
    final x = ra[i], y = rb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = switch ((nx, ny)) {
      (final int p, final int q) => p.compareTo(q),
      (int(), null) => -1,
      (null, int()) => 1,
      _ => x.compareTo(y),
    };
    if (c != 0) return c.sign;
  }
  return ra.length.compareTo(rb.length).sign;
}

({List<int> numbers, List<String> prerelease})? _parse(String version) {
  final match = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  ).firstMatch(version);
  if (match == null) return null;
  return (
    numbers: [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)],
    prerelease: match.group(4)?.split('.') ?? const [],
  );
}
