// Checks commit messages against the commit policy in AGENTS.md: a
// conventional-commit subject, and the `Changelog:` trailer rules.
//
//   bazel run //tools/changelog:check -- <message-file>   (commit-msg hook)
//   bazel run //tools/changelog:check -- --range A..B     (CI)
//
// Identical in rules_dart, rules_dart_proto, rules_flutter and frustrate.
import 'dart:convert';
import 'dart:io';

const _maxEntryLength = 100;

final _conventional = RegExp(
  r'^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)'
  r'(\([^)]+\))?(!)?: \S',
);
final _userVisibleType = RegExp(r'^(feat|fix|perf)[(!:]');
final _exempt = RegExp(r'^(fixup!|squash!|amend!|Merge |Revert ")');
final _entryStart = RegExp(r'^[A-Z`]');
final _anyChangelogLine = RegExp(
  r'^changelog:',
  caseSensitive: false,
  multiLine: true,
);

final _repo =
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path;

Future<void> main(List<String> args) async {
  if (args.length == 2 && args[0] == '--range') {
    exit(await _checkRange(args[1]));
  }
  if (args.length == 1) {
    exit(await _checkFile(args[0]));
  }
  stderr.writeln('usage: check (<message-file> | --range <rev-range>)');
  exit(2);
}

Future<int> _checkFile(String path) async {
  final base = Platform.environment['BUILD_WORKING_DIRECTORY'] ?? _repo;
  final file = File(path).isAbsolute ? File(path) : File('$base/$path');
  final message = await _git([
    'stripspace',
    '--strip-comments',
  ], stdin: file.readAsStringSync());
  final problems = await check(message);
  problems.forEach(stderr.writeln);
  return problems.isEmpty ? 0 : 1;
}

Future<int> _checkRange(String range) async {
  // A push that creates the branch reports an all-zeros `before`.
  final allZerosBefore = RegExp(r'^0+\.\.(.+)$').firstMatch(range);
  if (allZerosBefore != null) range = '${allZerosBefore[1]}^!';
  var status = 0;
  final shas = (await _git(['rev-list', '--no-merges', range]))
      .split('\n')
      .where((s) => s.isNotEmpty);
  for (final sha in shas) {
    final message = await _git(['log', '-1', '--format=%B', sha]);
    final problems = await check(message);
    if (problems.isEmpty) continue;
    status = 1;
    stdout.writeln('${sha.substring(0, 12)} ${message.split('\n').first}');
    for (final p in problems) {
      stdout.writeln('  $p');
    }
  }
  return status;
}

/// Returns the policy violations in [message]; empty when it is valid.
Future<List<String>> check(String message) async {
  final subject = message.split('\n').first;
  if (_exempt.hasMatch(subject)) return const [];

  final problems = <String>[];
  final conventional = _conventional.firstMatch(subject);
  if (conventional == null) {
    problems.add(
      'subject is not a conventional commit: '
      '"type(scope): description" with type one of build, chore, ci, docs, '
      'feat, fix, perf, refactor, revert, style, test',
    );
  }

  final trailers = await _git([
    'interpret-trailers',
    '--parse',
  ], stdin: message);
  final entries = [
    for (final line in trailers.split('\n'))
      if (line.startsWith('Changelog:')) line.substring(10).trim(),
  ];

  if (entries.isEmpty) {
    final userVisible =
        conventional?.group(3) != null || _userVisibleType.hasMatch(subject);
    if (_anyChangelogLine.hasMatch(message)) {
      problems.add(
        "'Changelog:' must be in the final trailer block "
        '(last paragraph, no blank line inside it)',
      );
    } else if (userVisible) {
      problems.add(
        "feat/fix/perf/breaking commits need a 'Changelog: <entry>' "
        "trailer, or 'Changelog: skip' if users cannot notice the change",
      );
    }
  }

  for (final entry in entries) {
    if (entry == 'skip') continue;
    if (entry.length > _maxEntryLength) {
      problems.add('Changelog entry over $_maxEntryLength chars: $entry');
    }
    if (entry.endsWith('.')) {
      problems.add('Changelog entry ends with a period: $entry');
    }
    if (!_entryStart.hasMatch(entry)) {
      problems.add(
        'Changelog entry must start with a capital letter or `code`: $entry',
      );
    }
  }
  return problems;
}

/// Runs git in the repo; [stdin] is piped in for the subcommands that read the
/// message from standard input (`stripspace`, `interpret-trailers`).
Future<String> _git(List<String> args, {String? stdin}) async {
  final process = await Process.start('git', args, workingDirectory: _repo);
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  if (stdin != null) process.stdin.write(stdin);
  await process.stdin.close();
  if (await process.exitCode != 0) {
    stderr.write(await err);
    exit(2);
  }
  return out;
}
