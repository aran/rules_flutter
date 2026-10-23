/// Fail-closed download guard: no fetch in flutter/** runs without a digest.
///
/// Every network fetch under `flutter/` runs through the `pinned_download` /
/// `pinned_download_and_extract` helpers in `flutter/private/download.bzl`,
/// which fail the fetch unless `sha256` is exactly 64 lowercase hex
/// characters and which hand the digest to Bazel's own checksum comparison.
/// That runtime check is the guarantee; this test is the tripwire that keeps
/// it wired up. It fails on:
///
/// * any `.download` / `.download_and_extract` attribute use on a context
///   outside `flutter/private/download.bzl` — a direct call, an alias such
///   as `fetch = ctx.download_and_extract`, or a `getattr` lookup. Comments
///   and string literals are ignored, so docs that name the methods stay
///   green while code that reaches them turns red;
/// * any `http_archive` / `http_file` / `http_jar` instantiation, in a
///   `.bzl` file or a `MODULE.bazel`, without a non-empty literal `sha256`
///   or `integrity` — whether called by its canonical name, through a
///   `use_repo_rule` proxy or `load` alias bound to any name, or through a
///   plain rebinding — and whether the checksum is absent or an empty
///   literal.
///
/// The test discovers its inputs at runtime from the workspace root (the
/// test's own source file in `data`, or `BUILD_WORKSPACE_DIRECTORY` when
/// set): every `.bzl` file under `flutter/` and every `MODULE.bazel` in the
/// repo (root, e2e, anywhere else). There is no file list to maintain — a
/// `.bzl` added in a new package, or a `MODULE.bazel` added anywhere, is
/// checked with no other change. Reading undeclared files means Bazel cannot know when to re-run, so the target
/// is tagged `external`: the guard re-runs on every invocation and is
/// never served a stale pass.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Whether [root] is the rules_flutter workspace root.
bool _looksLikeRoot(String root) =>
    Directory('$root/flutter').existsSync() &&
    File('$root/MODULE.bazel').existsSync();

/// Workspace root the test walks: `BUILD_WORKSPACE_DIRECTORY` when set,
/// otherwise the source file behind the test's own anchor in `data` (an
/// unsandboxed runfiles tree symlinks it into the source tree; the root is
/// the first ancestor that looks like the workspace). Null when neither
/// resolves, so the test fails loudly instead of scanning the wrong tree
/// or silently passing.
String? _workspaceRoot() {
  final fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty && _looksLikeRoot(fromEnv)) {
    return fromEnv;
  }
  final anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor != null && anchor.isNotEmpty && srcdir != null) {
    try {
      var dir = File(
        File('$srcdir/$anchor').resolveSymbolicLinksSync(),
      ).parent;
      for (var i = 0; i < 8; i++) {
        if (_looksLikeRoot(dir.path)) return dir.path;
        dir = dir.parent;
      }
    } on FileSystemException {
      // Fall through to the loud failure below.
    }
  }
  return null;
}

/// Relative paths of every file named [fileName] under [dir], recursively
/// (never following symlinks, skipping `node_modules` and hidden
/// directories such as `.git`), sorted. An empty [dir] walks the whole
/// workspace root.
List<String> _findNamed(String root, String dir, String fileName) {
  final base = dir.isEmpty ? Directory(root) : Directory('$root/$dir');
  if (!base.existsSync()) return <String>[];
  final found = <String>[];
  final stack = <Directory>[base];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    List<FileSystemEntity> children;
    try {
      children = current.listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    for (final child in children) {
      final name = child.path.split(Platform.pathSeparator).last;
      if (child is Directory) {
        if (name == 'node_modules' || name.startsWith('.')) {
          continue;
        }
        stack.add(child);
      } else if (child is File && name == fileName) {
        var rel = child.path;
        if (rel.startsWith('$root/')) rel = rel.substring(root.length + 1);
        found.add(rel);
      }
    }
  }
  found.sort();
  return found;
}

/// Relative paths of every `.bzl` file under `flutter/`, sorted.
List<String> _findBzl(String root) {
  final base = Directory('$root/flutter');
  final found = <String>[];
  final stack = <Directory>[base];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    List<FileSystemEntity> children;
    try {
      children = current.listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    for (final child in children) {
      if (child is Directory) {
        stack.add(child);
      } else if (child is File && child.path.endsWith('.bzl')) {
        found.add(child.path.substring(root.length + 1));
      }
    }
  }
  found.sort();
  return found;
}

/// [text] with every `#` comment and every string literal replaced by
/// spaces. When [blankStrings] is false, strings are kept. Newlines are
/// kept, so offsets (and therefore line numbers) match the original.
String _blankNonCode(String text, {required bool blankStrings}) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    if (ch == '#') {
      while (i < text.length && text[i] != '\n') {
        out.write(' ');
        i++;
      }
    } else if (ch == '"' || ch == "'") {
      final triple =
          i + 2 < text.length && text[i + 1] == ch && text[i + 2] == ch;
      final quote = triple ? ch + ch + ch : ch;
      out.write(blankStrings ? ' ' * quote.length : quote);
      i += quote.length;
      while (i < text.length) {
        if (triple &&
            i + 2 < text.length &&
            text[i] == ch &&
            text[i + 1] == ch &&
            text[i + 2] == ch) {
          out.write(blankStrings ? '   ' : quote);
          i += 3;
          break;
        }
        if (!triple && text[i] == ch) {
          out.write(blankStrings ? ' ' : ch);
          i++;
          break;
        }
        if (text[i] == r'\' && i + 1 < text.length) {
          out.write(blankStrings ? '  ' : text.substring(i, i + 2));
          i += 2;
          continue;
        }
        if (text[i] == '\n') {
          out.write('\n');
          i++;
          continue;
        }
        out.write(blankStrings ? ' ' : text[i]);
        i++;
      }
    } else {
      out.write(ch);
      i++;
    }
  }
  return out.toString();
}

/// End index of the balanced-`)` closing the `(` at [openParen] in
/// comment- and string-blanked text, or null when the call never closes.
int? _callEnd(String blanked, int openParen) {
  var depth = 0;
  for (var i = openParen; i < blanked.length; i++) {
    if (blanked[i] == '(') {
      depth++;
    } else if (blanked[i] == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}

/// 1-based line number of [offset] in [text].
int _lineOf(String text, int offset) =>
    '\n'.allMatches(text.substring(0, offset)).length + 1;

final RegExp _rawDownloadUse = RegExp(
  r'\.download(_and_extract)?(?![A-Za-z0-9_])',
);
final RegExp _getattrDownload = RegExp(
  r'''getattr\s*\([^()]*['"]download(_and_extract)?['"]''',
);
const _httpRuleNames = {'http_archive', 'http_file', 'http_jar'};
final RegExp _useRepoRuleBinding = RegExp(
  r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*use_repo_rule\s*\(',
);
final RegExp _loadCall = RegExp(
  r'(^|[^A-Za-z0-9_.])load\s*\(',
);
final RegExp _loadAliasArg = RegExp(
  r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*',
);
final RegExp _plainRebinding = RegExp(
  r'(?:^|[\n;:])[ \t]*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])',
);
final RegExp _stringLiteral = RegExp("\"([^\"]*)\"|'([^']*)'");
final RegExp _literalChecksum = RegExp(
  '''(sha256|integrity)\\s*=\\s*(?:"([^"]*)"|'([^']*)')''',
);

/// Error strings for raw context downloads in one `.bzl` file. The helpers
/// in `flutter/private/download.bzl` are the only code allowed to touch
/// `ctx.download` / `ctx.download_and_extract`.
List<String> _checkNoRawDownload(String rel, String text) {
  if (rel == 'flutter/private/download.bzl') return <String>[];
  final errors = <String>[];
  final code = _blankNonCode(text, blankStrings: true);
  for (final match in _rawDownloadUse.allMatches(code)) {
    errors.add(
      '$rel:${_lineOf(text, match.start)}: raw ctx.${match.group(0)!.substring(1)} '
      'outside flutter/private/download.bzl; fetch through '
      'pinned_download / pinned_download_and_extract',
    );
  }
  final codeWithStrings = _blankNonCode(text, blankStrings: false);
  for (final match in _getattrDownload.allMatches(codeWithStrings)) {
    errors.add(
      '$rel:${_lineOf(text, match.start)}: getattr lookup of a ctx download '
      'method outside flutter/private/download.bzl; fetch through '
      'pinned_download / pinned_download_and_extract',
    );
  }
  return errors;
}

/// Names bound to an `http_*` rule in blanked [code], mapped to
/// `(rule, kind)` where `kind` is how the name was bound: `use_repo_rule`,
/// `load` (a `load(..., alias = "http_archive")` alias), or `alias` (a
/// plain `name = http_archive` rebinding, chained through other proxies).
/// String values are read from the original [text] at the same offsets
/// (blanking preserves every offset). A binding whose rule name is not a
/// string literal cannot be resolved and is ignored.
Map<String, ({String rule, String kind})> _httpProxies(
  String code,
  String text,
) {
  final proxies = <String, ({String rule, String kind})>{};
  for (final match in _useRepoRuleBinding.allMatches(code)) {
    final openParen = code.indexOf('(', match.start);
    final end = _callEnd(code, openParen);
    if (end == null) continue;
    final literals = _stringLiteral
        .allMatches(text.substring(openParen, end))
        .map((m) => m.group(1) ?? m.group(2) ?? '')
        .toList();
    if (literals.length >= 2 && _httpRuleNames.contains(literals[1])) {
      proxies[match.group(1)!] = (rule: literals[1], kind: 'use_repo_rule');
    }
  }
  for (final match in _loadCall.allMatches(code)) {
    final openParen = code.indexOf('(', match.start);
    final end = _callEnd(code, openParen);
    if (end == null) continue;
    // Top-level comma-separated args; the first is the label.
    final args = <String>[];
    var depth = 0;
    var argStart = openParen + 1;
    for (var i = openParen + 1; i < end; i++) {
      if (code[i] == '(') {
        depth++;
      } else if (code[i] == ')') {
        depth--;
      } else if (code[i] == ',' && depth == 0) {
        args.add(text.substring(argStart, i));
        argStart = i + 1;
      }
    }
    args.add(text.substring(argStart, end));
    for (final arg in args.skip(1)) {
      final aliasMatch = _loadAliasArg.firstMatch(arg);
      final literal = _stringLiteral.firstMatch(
        aliasMatch == null ? arg : arg.substring(aliasMatch.end),
      );
      final orig = literal == null
          ? ''
          : (literal.group(1) ?? literal.group(2) ?? '');
      if (!_httpRuleNames.contains(orig)) continue;
      final alias = aliasMatch?.group(1) ?? orig;
      if (alias == orig) continue; // Canonical name; matched directly.
      proxies[alias] = (rule: orig, kind: 'load');
    }
  }
  // Plain `name = http_archive` rebindings at statement level (never a
  // keyword argument: those sit inside a call, after `(` or `,`). Chains
  // through known proxies resolve to a fixpoint.
  final rebindingArgs = _plainRebinding
      .allMatches(code)
      .map((m) => (lhs: m.group(1)!, rhs: m.group(2)!))
      .toList();
  for (var i = 0; i <= rebindingArgs.length; i++) {
    var changed = false;
    for (final binding in rebindingArgs) {
      if (proxies.containsKey(binding.lhs)) continue;
      if (_httpRuleNames.contains(binding.rhs)) {
        proxies[binding.lhs] = (rule: binding.rhs, kind: 'alias');
        changed = true;
      } else if (proxies.containsKey(binding.rhs)) {
        proxies[binding.lhs] = proxies[binding.rhs]!;
        changed = true;
      }
    }
    if (!changed) break;
  }
  return proxies;
}

/// Error strings for `http_*` rules without a non-empty literal checksum.
/// Matches the canonical `http_archive` / `http_file` / `http_jar` names
/// and any name bound to one of them — through `use_repo_rule`, through a
/// `load(..., alias = "...")` alias, or through a plain `name = ...`
/// rebinding — whatever the binding is called.
List<String> _checkHttpChecksums(String rel, String text) {
  final errors = <String>[];
  final code = _blankNonCode(text, blankStrings: true);
  final proxies = _httpProxies(code, text);
  final names = <String>{..._httpRuleNames, ...proxies.keys}.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final callRule = RegExp('(^|[^A-Za-z0-9_.])(${names.join('|')})\\s*\\(');
  for (final match in callRule.allMatches(code)) {
    final name = match.group(2)!;
    final nameStart = match.start + match.group(0)!.indexOf(name);
    final openParen = code.indexOf('(', nameStart);
    final end = _callEnd(code, openParen);
    if (end == null) {
      errors.add('$rel:${_lineOf(text, nameStart)}: cannot parse $name call');
      continue;
    }
    final body = text.substring(openParen, end);
    var pinned = false;
    for (final checksum in _literalChecksum.allMatches(body)) {
      final value = checksum.group(2) ?? checksum.group(3) ?? '';
      if (value.isNotEmpty) {
        pinned = true;
        break;
      }
    }
    if (!pinned) {
      final proxy = proxies[name];
      final via = proxy == null ? '' : ' (${proxy.rule} via ${proxy.kind})';
      errors.add(
        '$rel:${_lineOf(text, nameStart)}: $name()$via without a '
        'non-empty literal sha256 = or integrity =; pin the digest',
      );
    }
  }
  return errors;
}

void main() {
  group('http checksum parsing (unit)', () {
    test('use_repo_rule proxy without checksum fails with file:line', () {
      const probe = '''
_dl = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

_dl(
    name = "probe_unpinned",
    urls = ["https://example.invalid/probe.zip"],
)
''';
      final errors = _checkHttpChecksums('e2e/hello_world/MODULE.bazel', probe);
      expect(errors, hasLength(1));
      expect(errors.single, startsWith('e2e/hello_world/MODULE.bazel:3:'));
      expect(errors.single, contains('http_archive via use_repo_rule'));
    });

    test('use_repo_rule proxy with empty integrity fails with file:line', () {
      const probe = '''
_f = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

_f(
    name = "probe_empty_integrity",
    urls = ["https://example.invalid/probe.dat"],
    integrity = "",
)
''';
      final errors = _checkHttpChecksums('e2e/hello_world/MODULE.bazel', probe);
      expect(errors, hasLength(1));
      expect(errors.single, startsWith('e2e/hello_world/MODULE.bazel:3:'));
      expect(errors.single, contains('integrity'));
    });

    test('use_repo_rule proxy with a pinned digest passes', () {
      const probe = '''
_dl = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

_dl(
    name = "probe_pinned",
    urls = ["https://example.invalid/probe.zip"],
    sha256 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
)
''';
      expect(
        _checkHttpChecksums('e2e/hello_world/MODULE.bazel', probe),
        isEmpty,
      );
    });

    test('use_repo_rule proxy of another rule is ignored', () {
      const probe = '''
sky = use_repo_rule("@rules_flutter//flutter/private:flutter_sky_engine_repo.bzl", "flutter_sky_engine_repo")

sky(
    name = "sky_engine",
    engine_revision = "deb287481e3ce9468f3434937ced4240a70539ca",
    sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
)
''';
      expect(
        _checkHttpChecksums('e2e/digest_mismatch/MODULE.bazel', probe),
        isEmpty,
      );
    });

    test('canonically named proxy rebinding is still checked', () {
      const probe = '''
http_archive = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

http_archive(
    name = "probe_rebound",
    urls = ["https://example.invalid/probe.dat"],
)
''';
      final errors = _checkHttpChecksums('MODULE.bazel', probe);
      expect(errors, hasLength(1));
      expect(errors.single, startsWith('MODULE.bazel:3:'));
      expect(errors.single, contains('http_file via use_repo_rule'));
    });

    test('a longer identifier ending in a proxy name is ignored', () {
      const probe = '''
dl = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def my_dl(name):
    return name
''';
      expect(_checkHttpChecksums('MODULE.bazel', probe), isEmpty);
    });

    test('direct http_archive without checksum fails', () {
      const probe = '''
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "probe_direct",
    urls = ["https://example.invalid/probe.zip"],
)
''';
      final errors = _checkHttpChecksums('flutter/guardprobe.bzl', probe);
      expect(errors, hasLength(1));
      expect(errors.single, startsWith('flutter/guardprobe.bzl:3:'));
    });

    test(
      'load alias of http_archive without checksum fails with file:line',
      () {
        const probe = '''
load("@bazel_tools//tools/build_defs/repo:http.bzl", _zz_http_archive = "http_archive")

def zz_unpinned():
    _zz_http_archive(name = "zz_unpinned", urls = ["https://example.invalid/x.tgz"])
''';
        final errors = _checkHttpChecksums(
          'flutter/private/zz_unpinned_http.bzl',
          probe,
        );
        expect(errors, hasLength(1));
        expect(
          errors.single,
          startsWith('flutter/private/zz_unpinned_http.bzl:4:'),
        );
        expect(errors.single, contains('http_archive via load'));
      },
    );

    test('plain rebinding of http_archive without checksum fails', () {
      const probe = '''
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

x = http_archive

x(name = "rebound", urls = ["https://example.invalid/x.tgz"])
''';
      final errors = _checkHttpChecksums('flutter/guardprobe.bzl', probe);
      expect(errors, hasLength(1));
      expect(errors.single, startsWith('flutter/guardprobe.bzl:5:'));
      expect(errors.single, contains('http_archive via alias'));
    });

    test('load alias with a pinned digest passes', () {
      const probe = '''
load("@bazel_tools//tools/build_defs/repo:http.bzl", _zz_http_archive = "http_archive")

def zz_pinned():
    _zz_http_archive(
        name = "zz_pinned",
        urls = ["https://example.invalid/x.tgz"],
        sha256 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    )
''';
      expect(
        _checkHttpChecksums('flutter/private/zz_unpinned_http.bzl', probe),
        isEmpty,
      );
    });
  });

  final root = _workspaceRoot();
  if (root == null) {
    test('download guard discovers the workspace', () {
      fail(
        'BUILD_WORKSPACE_DIRECTORY does not point at the rules_flutter '
        'workspace; run this test unsandboxed (it is tagged no-sandbox) via '
        'bazel test //flutter/tests:download_digest_guard_test',
      );
    });
    return;
  }
  final bzlFiles = _findBzl(root);
  // Every MODULE.bazel in the repo: root, e2e, anywhere else.
  final moduleFiles = _findNamed(root, '', 'MODULE.bazel');

  test('download guard discovers its inputs (no file list)', () {
    expect(
      bzlFiles,
      contains('flutter/private/download.bzl'),
      reason: 'the walk under flutter/ missed the helper itself',
    );
    expect(
      moduleFiles,
      contains('MODULE.bazel'),
      reason: 'the root MODULE.bazel is not scanned',
    );
    expect(
      moduleFiles.any((path) => path.startsWith('e2e/')),
      isTrue,
      reason: 'no MODULE.bazel under e2e/ was discovered',
    );
  });

  for (final rel in bzlFiles) {
    test('$rel fetches only through the pinned helpers', () {
      final text = File('$root/$rel').readAsStringSync();
      final problems = [
        ..._checkNoRawDownload(rel, text),
        ..._checkHttpChecksums(rel, text),
      ];
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  for (final rel in moduleFiles) {
    test('$rel pins every http checksum', () {
      final text = File('$root/$rel').readAsStringSync();
      final problems = _checkHttpChecksums(rel, text);
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }
}
