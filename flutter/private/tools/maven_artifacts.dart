/// Prints the Maven artifacts an Android build needs, as the lines to paste
/// into `maven.install(name = "rules_flutter_maven", artifacts = [...])`,
/// and the BoMs that give the versions of those that name none, for its
/// `boms = [...]`.
///
/// Two kinds of artifact line:
///
/// * The artifacts the Android plugins' Gradle builds declare, at the highest
///   version any of them declares, as Gradle gives a plugin.
/// * Artifacts the install resolves that Gradle would raise. A library
///   published with Gradle module metadata can constrain the versions of
///   its companions: androidx `activity` 1.9.0 requires `activity-ktx`, if
///   present, to be 1.9.0 too, because classes moved between them. Gradle
///   honours those constraints; rules_jvm_external reads only POMs and
///   leaves an old `-ktx` artifact beside a new main one, whose classes then
///   conflict. So this reads the `.module` file of every artifact the
///   install resolves, from the install's repositories, as rules_jvm_external's
///   own `outdated` does, and raises what a constraint asks to raise, until
///   nothing changes.
///
/// Usage: `maven_artifacts <runfiles path of the report's JSON> [options]`.
/// `flutter_android_maven` (every plugin of the build) and
/// `flutter_android_maven_report` (an application's) write that JSON:
/// `app` (or null), `requirements` and `boms` (coordinate to `version`,
/// `managed`, `declared_by` and `exclusions`), `resolved` and
/// `resolved_boms` (coordinate to version), `listed` (coordinate to the
/// coordinate the install's `artifacts` list it as), `locked`,
/// `repositories` and `unread`, the plugins' Gradle lines the reader could
/// not read.
///
/// After the lines to paste it prints, as a suggestion, the buildozer command
/// that makes the same changes to `artifacts` and `boms`, and the command
/// that regenerates the install's lock file.
///
/// Options, each a file path (relative to the directory `bazel run` was
/// started in):
///
/// * `--metadata=<file>` reads the metadata from a snapshot that
///   `--record` wrote instead of from the repositories, and fails if the
///   snapshot lacks an artifact it needs. The output does not depend on the
///   network then.
/// * `--record=<file>` reads the metadata from the repositories, as without
///   options, and adds what it read to the snapshot in the file, creating it
///   if there is none. Recording several reports into one file that did not
///   exist before gives the snapshot of them all.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// What the plugins declare for one artifact or BoM.
class Requirement {
  Requirement(
    this.version,
    this.declaredBy, {
    this.managed = false,
    this.exclusions = const [],
  });

  /// The highest version declared, or null when none names one.
  final String? version;
  final List<String> declaredBy;

  /// Whether a plugin leaves the version to a BoM.
  final bool managed;

  /// The `group:artifact`s every declaration excludes from what it brings.
  final List<String> exclusions;
}

/// A line of a plugin's Gradle build that the reader could not read, such
/// as a `platform(...)` BoM or an artifact with no version. It may declare
/// a dependency the requirements lack.
typedef UnreadLine = ({
  String package,
  String script,
  int lineNumber,
  String line,
});

/// An artifact raised by another's Gradle module metadata.
class Alignment {
  Alignment(this.version, this.by);

  final String version;

  /// The `group:artifact version` whose constraint asks for [version].
  final String by;
}

/// A dependency constraint of a module's Gradle metadata.
typedef Constraint = ({String coordinate, String version});

/// The dependency constraints of the Gradle module metadata [json], of
/// every variant.
///
/// A constraint that names no single version (`rejects` alone, or a range)
/// raises nothing, and is left out.
List<Constraint> constraintsOf(String json) {
  final metadata = jsonDecode(json) as Map<String, Object?>;
  final constraints = <Constraint>{};
  for (final variant in (metadata['variants'] as List? ?? const [])) {
    for (final constraint
        in ((variant as Map)['dependencyConstraints'] as List? ?? const [])) {
      final c = constraint as Map;
      final version = c['version'] as Map? ?? const {};
      final wanted = (version['strictly'] ?? version['requires']) as String?;
      if (wanted == null || _isRange(wanted)) continue;
      constraints.add((
        coordinate: '${c['group']}:${c['module']}',
        version: wanted,
      ));
    }
  }
  return constraints.toList();
}

bool _isRange(String version) =>
    version.contains(RegExp(r'[\[\](),+]')) || version.startsWith('latest.');

/// Raises the artifacts of [start] (coordinate to version) as the
/// constraints of their Gradle module metadata ask, until nothing changes.
///
/// [constraints] gives the constraints of one version of one artifact. A
/// constraint on an artifact [start] lacks adds nothing, as in Gradle.
Future<Map<String, Alignment>> align(
  Map<String, String> start,
  Future<List<Constraint>> Function(String coordinate, String version)
  constraints,
) async {
  final versions = Map.of(start);
  final aligned = <String, Alignment>{};
  var pending = versions.entries.map((e) => (e.key, e.value)).toList();
  while (pending.isNotEmpty) {
    final found = await Future.wait([
      for (final (coordinate, version) in pending)
        constraints(
          coordinate,
          version,
        ).then((list) => (coordinate, version, list)),
    ]);
    final raised = <String>{};
    for (final (coordinate, version, list) in found) {
      for (final constraint in list) {
        final have = versions[constraint.coordinate];
        if (have == null || compareVersions(have, constraint.version) >= 0) {
          continue;
        }
        versions[constraint.coordinate] = constraint.version;
        aligned[constraint.coordinate] = Alignment(
          constraint.version,
          '$coordinate $version',
        );
        raised.add(constraint.coordinate);
      }
    }
    pending = [for (final c in raised) (c, versions[c]!)];
  }
  return aligned;
}

/// The text the program prints.
///
/// [requirements] are the plugins' declarations, [resolved] what the install
/// resolves, [aligned] the result of [align] over both, and [unread] the lines
/// of the plugins' Gradle builds the reader could not read. [boms] are the
/// plugins' BoMs and [resolvedBoms] the install's. [listed] maps each
/// artifact the install's `artifacts` list to the coordinate it lists, and
/// [locked] says whether the install has a lock file.
String formatReport({
  required String? app,
  required Map<String, Requirement> requirements,
  required Map<String, String> resolved,
  required Map<String, Alignment> aligned,
  List<UnreadLine> unread = const [],
  Map<String, Requirement> boms = const {},
  Map<String, String> resolvedBoms = const {},
  Map<String, String> listed = const {},
  bool locked = true,
}) {
  final lines = <String>[];
  final excluding = <String>[];
  final edits = _Edits();
  var changed = 0;
  for (final coordinate in requirements.keys.toList()..sort()) {
    final req = requirements[coordinate]!;
    final alignment = aligned[coordinate];
    var version = req.version;
    final notes = <String>[];
    if (alignment != null &&
        (version == null || compareVersions(alignment.version, version) > 0)) {
      version = alignment.version;
      notes.add('aligned with ${alignment.by}');
    }
    final have = resolved[coordinate];
    if (have == null) {
      notes.add('missing');
    } else if (version != null && compareVersions(have, version) < 0) {
      notes.add('resolves $have');
    }
    if (have == null || notes.isNotEmpty) changed++;
    final allNotes = ['declared by ${req.declaredBy.join(', ')}', ...notes];
    if (req.exclusions.isNotEmpty) {
      // `artifacts` cannot say what an artifact excludes; `maven.artifact` can.
      excluding.add(
        _artifactTag(coordinate, version, req.exclusions, allNotes),
      );
      continue;
    }
    lines.add(_line(coordinate, version, allNotes, managed: req.managed));
    if (have == null || notes.isNotEmpty) {
      edits.change('artifacts', coordinate, version, listed[coordinate]);
    }
  }
  final alignedOnly = [
    for (final coordinate in aligned.keys.toList()..sort())
      if (!requirements.containsKey(coordinate)) coordinate,
  ];
  for (final coordinate in alignedOnly) {
    final alignment = aligned[coordinate]!;
    lines.add(
      _line(coordinate, alignment.version, [
        'aligned with ${alignment.by}',
        'resolves ${resolved[coordinate]}',
      ]),
    );
    edits.change(
      'artifacts',
      coordinate,
      alignment.version,
      listed[coordinate],
    );
  }
  final bomLines = <String>[];
  for (final coordinate in boms.keys.toList()..sort()) {
    final req = boms[coordinate]!;
    final have = resolvedBoms[coordinate];
    final notes = ['declared by ${req.declaredBy.join(', ')}'];
    if (have == null) {
      notes.add('missing');
    } else if (req.version != null && compareVersions(have, req.version!) < 0) {
      notes.add('resolves $have');
    }
    if (notes.length > 1) {
      changed++;
      edits.change(
        'boms',
        coordinate,
        req.version,
        have == null ? null : '$coordinate:$have',
      );
    }
    bomLines.add(_line(coordinate, req.version, notes));
  }

  final out = <String>[
    app == null
        ? '# Maven artifacts the Android plugins of the build declare.'
        : '# Maven artifacts the Android plugins that $app links declare.',
  ];
  final declared = requirements.length + boms.length;
  if (declared == 0) {
    out.add('# The plugins declare none.');
  } else if (changed > 0) {
    out.add(
      '# $changed of $declared are missing or too low in '
      '@rules_flutter_maven (marked).',
    );
  } else {
    out.add('# All $declared are provided by @rules_flutter_maven.');
  }
  if (alignedOnly.isNotEmpty) {
    out.add(
      '# ${alignedOnly.length} more '
      '${alignedOnly.length == 1 ? 'resolves' : 'resolve'} lower than the '
      'Gradle module metadata of another artifact asks for: Gradle would '
      'raise ${alignedOnly.length == 1 ? 'it' : 'them'} (marked).',
    );
  }
  if (lines.isEmpty && bomLines.isEmpty && excluding.isEmpty) {
    out.add('# None.');
  }
  if (lines.isNotEmpty) {
    out
      ..add(
        '# Paste into maven.install(name = "rules_flutter_maven", '
        'artifacts = [...]):',
      )
      ..add('')
      ..addAll(lines.map((line) => '        $line'));
  }
  if (bomLines.isNotEmpty) {
    if (lines.isNotEmpty) out.add('');
    out
      ..add(
        '# Paste into maven.install(name = "rules_flutter_maven", '
        'boms = [...]), which gives',
      )
      ..add('# the versions of the artifacts above that name none:')
      ..add('')
      ..addAll(bomLines.map((line) => '        $line'));
  }
  if (excluding.isNotEmpty) {
    if (lines.isNotEmpty || bomLines.isNotEmpty) out.add('');
    out
      ..add(
        '# Add to MODULE.bazel, in place of these artifacts\' lines in '
        '`artifacts`: the plugins',
      )
      ..add('# exclude part of what they bring.')
      ..add('')
      ..addAll(excluding);
  }
  final command = edits.command(locked: locked);
  if (command.isNotEmpty) {
    out
      ..add('')
      ..add(
        '# Or, when that maven.install is in the root MODULE.bazel itself '
        '(not in a file it',
      )
      ..add(
        '# include()s), buildozer can make the changes to `artifacts` and '
        '`boms`:',
      )
      ..add('#')
      ..addAll(command.map((line) => '#   $line'));
  }
  if (unread.isNotEmpty) {
    out
      ..add('')
      ..add(
        '# These lines of the plugins\' Gradle builds are in a form '
        'rules_flutter does not read,',
      )
      ..add(
        '# so what they declare is not above. Add the artifacts a plugin '
        'needs, and state them',
      )
      ..add(
        '# for it with flutter_pub.annotation(package = ..., '
        'android_deps = [...]):',
      )
      ..add('')
      ..addAll([
        for (final u in unread)
          '#   ${u.package}, ${u.script}:${u.lineNumber}: ${u.line}',
      ]);
  }
  return '${out.join('\n')}\n';
}

String _line(
  String coordinate,
  String? version,
  List<String> notes, {
  bool managed = false,
}) =>
    '"${_coordinate(coordinate, version, managed: managed)}",  '
    '# ${notes.join('; ')}';

/// `group:artifact:version`, or `group:artifact` for one whose version a BoM
/// gives.
String _coordinate(
  String coordinate,
  String? version, {
  bool managed = false,
}) => version == null && managed
    ? coordinate
    : '$coordinate:${version ?? '<version>'}';

String _artifactTag(
  String coordinate,
  String? version,
  List<String> exclusions,
  List<String> notes,
) {
  final [group, artifact] = coordinate.split(':');
  return [
    '# ${notes.join('; ')}',
    'maven.artifact(',
    '    name = "rules_flutter_maven",',
    '    artifact = "$artifact",',
    '    exclusions = [${exclusions.map((e) => '"$e"').join(', ')}],',
    '    group = "$group",',
    if (version != null) '    version = "$version",',
    ')',
  ].join('\n');
}

/// The changes to an install's `artifacts` and `boms`, as one buildozer
/// command.
class _Edits {
  final _added = <String, List<String>>{};
  final _replaced = <String>[];

  /// Sets [coordinate] of [attribute] to [version]: replaces [listed], the
  /// coordinate the install lists it as, or adds it when it lists none.
  /// One with no version a BoM gives is added as `group:artifact`.
  void change(
    String attribute,
    String coordinate,
    String? version,
    String? listed,
  ) {
    if (listed != null) {
      if (version == null) return;
      _replaced.add("'replace $attribute $listed $coordinate:$version'");
    } else {
      _added
          .putIfAbsent(attribute, () => [])
          .add(version == null ? coordinate : '$coordinate:$version');
    }
  }

  /// The lines to run, none when there is nothing to change.
  List<String> command({required bool locked}) {
    final commands = [
      for (final MapEntry(:key, :value) in _added.entries)
        "'add $key ${value.join(' ')}'",
      ..._replaced,
    ];
    if (commands.isEmpty) return const [];
    return [
      'buildozer ${commands.join(' ')} //MODULE.bazel:rules_flutter_maven',
      if (locked) 'REPIN=1 bazel run @rules_flutter_maven//:pin',
    ];
  }
}

/// The Gradle module metadata of [coordinate] at [version], from the first of
/// [repositories] that has it, or null when none does: the artifact was
/// published without it.
///
/// [get] returns a URL's body, or null for a 404.
Future<String?> moduleMetadata(
  String coordinate,
  String version,
  List<String> repositories,
  Future<String?> Function(Uri url) get,
) async {
  final [group, artifact] = coordinate.split(':');
  final path =
      '${group.replaceAll('.', '/')}/$artifact/$version/'
      '$artifact-$version.module';
  for (final repository in repositories) {
    final base = repository.endsWith('/') ? repository : '$repository/';
    final body = await get(Uri.parse('$base$path'));
    if (body != null) return body;
  }
  return null;
}

/// Gradle module metadata recorded from the repositories: `group:artifact:
/// version` to the constraints of that version's metadata (see
/// [constraintsOf]), or to null when it was published without metadata.
typedef Snapshot = Map<String, List<Constraint>?>;

/// The [Snapshot] that [formatSnapshot] wrote as [json].
Snapshot parseSnapshot(String json) => {
  for (final MapEntry(:key, :value)
      in (jsonDecode(json) as Map<String, Object?>).entries)
    key: value == null
        ? null
        : [
            for (final line in (value as List).cast<String>())
              (
                coordinate: line.substring(0, line.lastIndexOf(':')),
                version: line.substring(line.lastIndexOf(':') + 1),
              ),
          ],
};

/// [snapshot] as JSON, sorted, each constraint as `group:artifact:version`.
///
/// The layout is the one prettier, which formats this repository's JSON,
/// gives it: an array on its key's line when that fits in 80 columns, one
/// element a line when it does not.
String formatSnapshot(Snapshot snapshot) {
  final keys = snapshot.keys.toList()..sort();
  final entries = <String>[];
  for (final (i, key) in keys.indexed) {
    final comma = i == keys.length - 1 ? '' : ',';
    final constraints = snapshot[key];
    final head = '  ${jsonEncode(key)}: ';
    if (constraints == null) {
      entries.add('${head}null$comma');
      continue;
    }
    final items = [
      for (final c in constraints) jsonEncode('${c.coordinate}:${c.version}'),
    ]..sort();
    final inline = '$head[${items.join(', ')}]$comma';
    entries.add(
      inline.length <= 80
          ? inline
          : '$head[\n${items.map((item) => '    $item').join(',\n')}\n  ]$comma',
    );
  }
  return entries.isEmpty ? '{}\n' : '{\n${entries.join('\n')}\n}\n';
}

/// An artifact whose metadata a snapshot does not hold.
class NotInSnapshot implements Exception {
  NotInSnapshot(this.snapshotPath, this.artifact);

  final String snapshotPath;
  final String artifact;

  @override
  String toString() =>
      '$snapshotPath has no Gradle module metadata of $artifact. Record the '
      'snapshot again with --record.';
}

/// Fetches [url] with [client]: the body, or null for a 404.
///
/// Anything else (another status, no connection) throws: a report that left
/// an artifact out because a repository did not answer would be wrong
/// without saying so.
Future<String?> _get(HttpClient client, Uri url) async {
  final request = await client.getUrl(url);
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode == 404) return null;
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}', uri: url);
  }
  return body;
}

/// Runs tasks at most [limit] at a time.
class _Pool {
  _Pool(this.limit);

  final int limit;
  var _running = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}

/// Compares Maven versions as Maven's ComparableVersion does, simplified:
/// tokens split on `.`, `-` and digit/letter transitions; numbers compare
/// numerically with missing ones as 0; qualifiers order alpha < beta <
/// milestone < rc < snapshot < release < sp, unknown ones after, lexically.
int compareVersions(String a, String b) {
  final ta = _tokens(a);
  final tb = _tokens(b);
  for (var i = 0; i < ta.length || i < tb.length; i++) {
    final c = _compareTokens(
      i < ta.length ? ta[i] : null,
      i < tb.length ? tb[i] : null,
    );
    if (c != 0) return c;
  }
  return 0;
}

const _qualifierRank = {
  'alpha': 0,
  'a': 0,
  'beta': 1,
  'b': 1,
  'milestone': 2,
  'm': 2,
  'rc': 3,
  'cr': 3,
  'snapshot': 4,
  '': 5,
  'ga': 5,
  'final': 5,
  'release': 5,
  'sp': 6,
};
const _releaseRank = 5;
const _unknownRank = 7;

List<Object> _tokens(String version) {
  final tokens = <Object>[];
  final current = StringBuffer();
  bool? numeric;
  void flush() {
    if (current.isEmpty) return;
    final text = current.toString();
    tokens.add(numeric! ? int.parse(text) : text);
    current.clear();
  }

  for (final c in version.toLowerCase().split('')) {
    if (c == '.' || c == '-' || c == '_') {
      flush();
      continue;
    }
    final digit = c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
    if (current.isNotEmpty && digit != numeric) flush();
    current.write(c);
    numeric = digit;
  }
  flush();
  return tokens;
}

(int, String) _qualifierKey(String qualifier) {
  final rank = _qualifierRank[qualifier];
  return rank == null ? (_unknownRank, qualifier) : (rank, '');
}

int _compareKeys((int, String) a, (int, String) b) =>
    a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2).sign;

int _comparePresent(Object a, Object? b) {
  if (a is int) {
    if (b == null) return a == 0 ? 0 : 1;
    if (b is int) return a.compareTo(b).sign;
    return 1;
  }
  final ka = _qualifierKey(a as String);
  if (b == null) return _compareKeys(ka, (_releaseRank, ''));
  if (b is int) return -1;
  return _compareKeys(ka, _qualifierKey(b as String));
}

int _compareTokens(Object? a, Object? b) {
  if (a == null && b == null) return 0;
  if (a == null) return -_comparePresent(b!, null);
  return _comparePresent(a, b);
}

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  final positional = <String>[];
  for (final arg in args) {
    final option = RegExp(r'^--(metadata|record)=(.+)$').firstMatch(arg);
    if (option != null) {
      options[option.group(1)!] = _fromWorkingDirectory(option.group(2)!);
    } else {
      positional.add(arg);
    }
  }
  if (positional.length != 1 || options.length > 1) {
    stderr.writeln(
      'usage: maven_artifacts <runfiles path of the report> '
      '[--metadata=<snapshot> | --record=<snapshot>]',
    );
    exit(2);
  }
  final data = jsonDecode(
    File(Runfiles.create().rlocation(positional.single)).readAsStringSync(),
  ) as Map<String, Object?>;
  Map<String, Requirement> requirementsOf(Object? json) => {
    for (final MapEntry(:key, :value)
        in (json as Map<String, Object?>? ?? const {}).entries)
      key: Requirement(
        (value as Map)['version'] as String?,
        (value['declared_by'] as List).cast<String>(),
        managed: value['managed'] as bool? ?? false,
        exclusions: (value['exclusions'] as List? ?? const []).cast<String>(),
      ),
  };
  final requirements = requirementsOf(data['requirements']);
  final boms = requirementsOf(data['boms']);
  final resolved = (data['resolved'] as Map).cast<String, String>();
  final repositories = (data['repositories'] as List).cast<String>();
  final unread = <UnreadLine>[
    for (final u in (data['unread'] as List? ?? const []))
      (
        package: (u as Map)['package'] as String,
        script: u['script'] as String,
        lineNumber: u['line_number'] as int,
        line: u['line'] as String,
      ),
  ];

  // What the install would resolve once the plugins' lines are pasted in.
  final start = Map.of(resolved);
  for (final MapEntry(:key, value: req) in requirements.entries) {
    final have = start[key];
    if (have != null &&
        req.version != null &&
        compareVersions(have, req.version!) < 0) {
      start[key] = req.version!;
    }
  }

  final snapshotPath = options['metadata'];
  final recordPath = options['record'];
  final snapshot = snapshotPath == null
      ? null
      : parseSnapshot(File(snapshotPath).readAsStringSync());
  final recorded = <String, List<Constraint>?>{};
  final client = HttpClient();
  final pool = _Pool(16);
  try {
    final aligned = await align(start, (coordinate, version) async {
      final artifact = '$coordinate:$version';
      if (snapshot != null) {
        if (!snapshot.containsKey(artifact)) {
          throw NotInSnapshot(snapshotPath!, artifact);
        }
        return snapshot[artifact] ?? const [];
      }
      final json = await pool.run(
        () => moduleMetadata(
          coordinate,
          version,
          repositories,
          (url) => _get(client, url),
        ),
      );
      final constraints = json == null ? null : constraintsOf(json);
      recorded[artifact] = constraints;
      return constraints ?? const [];
    });
    if (recordPath != null) {
      final file = File(recordPath);
      final before = file.existsSync()
          ? parseSnapshot(file.readAsStringSync())
          : const <String, List<Constraint>?>{};
      file.writeAsStringSync(formatSnapshot({...before, ...recorded}));
    }
    stdout.write(
      formatReport(
        app: data['app'] as String?,
        requirements: requirements,
        resolved: resolved,
        aligned: aligned,
        unread: unread,
        boms: boms,
        resolvedBoms: (data['resolved_boms'] as Map? ?? const {})
            .cast<String, String>(),
        listed: (data['listed'] as Map? ?? const {}).cast<String, String>(),
        locked: data['locked'] as bool? ?? true,
      ),
    );
  } on NotInSnapshot catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  } on Exception catch (e) {
    stderr.writeln(
      'Could not read the Gradle module metadata of the artifacts '
      '@rules_flutter_maven resolves from ${repositories.join(', ')}: $e',
    );
    exitCode = 1;
  } finally {
    client.close(force: true);
  }
}

/// [path] as `bazel run` users mean it: relative to the directory they ran
/// it in, not to the runfiles tree the program starts in.
String _fromWorkingDirectory(String path) {
  final base = Platform.environment['BUILD_WORKING_DIRECTORY'];
  return base == null || File(path).isAbsolute ? path : '$base/$path';
}
