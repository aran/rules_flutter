/// Fail-closed guard: no `.format()` call leaves a `{placeholder}` unfilled.
///
/// In Starlark `"a{x}" + "b".format(x = ...)` binds `.format()` to the last
/// literal only, so `{x}` prints literally — and `fail("a{x}" + "b",).format(...)`
/// never runs `.format()` at all (`fail` raises first), with the same raw
/// output. The repo style parenthesizes the whole concatenation and formats
/// it directly (see `missing_local_file_message` in
/// `flutter/private/local_sdk.bzl`), which this test enforces: it walks the
/// `+`-joined literal chain ending at each `.format()` receiver and fails
/// when a placeholder in it would print literally. A bare grouping paren
/// stays benign; so do single formatted literals and a placeholder-free base
/// joined to one formatted literal (`_BASE + "name-{}.zip".format(...)`).
///
/// Like the download digest guard, this test discovers its inputs at runtime
/// from the workspace root (the test's own source file in `data`, or
/// `BUILD_WORKSPACE_DIRECTORY` when set) and is tagged `external`, so a new
/// `.bzl` file is checked with no other change and never hidden behind a
/// stale pass.
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

/// [line] with any `#` comment removed. A `#` inside a string literal does
/// not start a comment; quote state (including triple-quoted strings, which
/// never appear in a `.format()` statement but keep the scanner honest)
/// is tracked so message text keeps its `#`.
String _stripComment(String line) {
  final out = StringBuffer();
  String? quote;
  var triple = false;
  var i = 0;
  while (i < line.length) {
    final ch = line[i];
    if (quote == null) {
      if (ch == '#') break;
      if (ch == '"' || ch == "'") {
        triple = i + 2 < line.length && line[i + 1] == ch && line[i + 2] == ch;
        quote = ch;
        out.write(ch);
        i++;
        continue;
      }
      out.write(ch);
      i++;
      continue;
    }
    if (ch == r'\' && i + 1 < line.length) {
      out.write(ch);
      out.write(line[i + 1]);
      i += 2;
      continue;
    }
    if (triple) {
      if (i + 2 < line.length &&
          line[i] == quote &&
          line[i + 1] == quote &&
          line[i + 2] == quote) {
        out.write(quote * 3);
        i += 3;
        quote = null;
        triple = false;
        continue;
      }
      out.write(ch);
      i++;
      continue;
    }
    out.write(ch);
    if (ch == quote) quote = null;
    i++;
  }
  return out.toString();
}

final RegExp _placeholder = RegExp(r'\{[^{}]*\}');

/// [i] moved past whitespace backwards.
int _skipWsBack(String w, int i) {
  while (i >= 0 && (w[i] == ' ' || w[i] == '\t' || w[i] == '\n')) i--;
  return i;
}

/// Whether the character at [i] is escaped by an odd run of backslashes.
bool _isEscaped(String w, int i) {
  var bs = 0;
  var k = i - 1;
  while (k >= 0 && w[k] == r'\') {
    bs++;
    k--;
  }
  return bs % 2 == 1;
}

/// Opener index of the string literal closing at [close], or -1.
///
/// [close] must be a quote. Triple-quoted literals are handled; a raw
/// newline ends the search, since a single-quoted literal cannot span lines.
int _literalOpener(String w, int close) {
  final q = w[close];
  if (q != '"' && q != "'") return -1;
  final triple =
      close >= 2 &&
      w[close - 1] == q &&
      w[close - 2] == q &&
      !_isEscaped(w, close - 1);
  var i = close - (triple ? 3 : 1);
  while (i >= 0) {
    if (triple) {
      if (w[i] == q &&
          i >= 2 &&
          w[i - 1] == q &&
          w[i - 2] == q &&
          !_isEscaped(w, i - 2)) {
        return i - 2;
      }
      i--;
      continue;
    }
    if (w[i] == '\n') return -1;
    if (w[i] == q && !_isEscaped(w, i)) return i;
    i--;
  }
  return -1;
}

/// The `+`-joined string literals ending at [close] (a closing quote),
/// receiver first. Stops at anything but `literal + literal`, so an
/// assignment, a call boundary, or `+=` ends the chain — only literals one
/// `+` expression actually joins are collected.
List<String> _literalChain(String w, int close) {
  final chain = <String>[];
  var end = close;
  while (true) {
    final open = _literalOpener(w, end);
    if (open < 0) break;
    chain.add(w.substring(open, end + 1));
    var i = _skipWsBack(w, open - 1);
    if (i < 0 || w[i] != '+') break;
    i = _skipWsBack(w, i - 1);
    if (i < 0) break;
    final q = w[i];
    if (q != '"' && q != "'") break;
    end = i;
  }
  return chain;
}

/// The literal chain of a call receiver's last argument: [close] is the
/// call's `)` and [open] its `(`. Unwraps grouping parens around the last
/// argument; bails (not a literal message) on a nested call, a non-literal
/// tail, or anything unmatched.
List<String> _lastArgChain(String w, int close, int open) {
  var end = _skipWsBack(w, close - 1);
  while (end >= 0 && w[end] == ')') {
    final inner = _matchOpen(w, end);
    if (inner < 0 || inner <= open) return const [];
    final k = _skipWsBack(w, inner - 1);
    if (k < 0 || _isIdentChar(w[k])) return const [];
    end = _skipWsBack(w, end - 1);
  }
  if (end >= 0 && w[end] == ',') {
    end = _skipWsBack(w, end - 1);
  }
  if (end >= 0 && (w[end] == '"' || w[end] == "'")) {
    return _literalChain(w, end);
  }
  return const [];
}

/// 1-based line number of [offset] in [text].
int _lineOf(String text, int offset) =>
    '\n'.allMatches(text.substring(0, offset)).length + 1;

/// Whether [ch] can end an identifier (so `(` after it opens a call).
bool _isIdentChar(String ch) =>
    (ch.compareTo('a') >= 0 && ch.compareTo('z') <= 0) ||
    (ch.compareTo('A') >= 0 && ch.compareTo('Z') <= 0) ||
    (ch.compareTo('0') >= 0 && ch.compareTo('9') <= 0) ||
    ch == '_' ||
    ch == '.';

/// Starlark keywords: a `(` after one opens a grouping, not a call
/// (`return (...)` formats the join — benign, unlike `fail(...)`).
const _keywords = {
  'and',
  'break',
  'continue',
  'def',
  'elif',
  'else',
  'for',
  'if',
  'in',
  'lambda',
  'load',
  'not',
  'or',
  'pass',
  'return',
  'while',
};

/// The identifier token ending at [i] (already past whitespace), or "".
String _tokenBefore(String w, int i) {
  var end = i;
  while (end >= 0 && _isIdentChar(w[end]) && w[end] != '.') end--;
  if (end == i) return '';
  return w.substring(end + 1, i + 1);
}

/// Index of the `(` matching the `)` at [close] in [code], or -1.
///
/// Scans backwards quote-aware (a `)` inside a string literal does not
/// count): a quote closes going backwards unless an odd number of
/// backslashes precedes it. Triple-quoted receivers never reach this path
/// (they end in a quote, handled below), so `"""` runs inside other strings
/// are the only rough edge, and `.format()` statements do not nest those.
int _matchOpen(String code, int close) {
  var depth = 0;
  String? quote;
  var i = close;
  while (i >= 0) {
    final ch = code[i];
    if (quote != null) {
      if (ch == quote) {
        var bs = 0;
        var k = i - 1;
        while (k >= 0 && code[k] == r'\') {
          bs++;
          k--;
        }
        if (bs % 2 == 0) quote = null;
      }
      i--;
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      i--;
      continue;
    }
    if (ch == ')') depth++;
    if (ch == '(') {
      depth--;
      if (depth == 0) return i;
    }
    i--;
  }
  return -1;
}

/// [text] with prose blanked: `#` comments and triple-quoted strings become
/// spaces (newlines kept, so offsets and `file:line` reporting still line
/// up). A `.format(` inside prose is text, never a call — without this, a
/// docstring spelling out the `"a{x}" + "b".format(...)` anti-pattern flags
/// itself. Single-quoted strings are kept verbatim (the scan needs their
/// quotes and placeholders); only a `#` inside one is text, so the skip
/// jumps to the closing quote.
String _maskProse(String text) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    if (ch == '#') {
      while (i < text.length && text[i] != '\n') {
        out.write(' ');
        i++;
      }
      continue;
    }
    if ((ch == '"' || ch == "'") &&
        i + 2 < text.length &&
        text[i + 1] == ch &&
        text[i + 2] == ch) {
      for (var k = 0; k < 3; k++) {
        out.write(' ');
        i++;
      }
      while (i < text.length &&
          !(text[i] == ch &&
              i + 2 < text.length &&
              text[i + 1] == ch &&
              text[i + 2] == ch)) {
        out.write(text[i] == '\n' ? '\n' : ' ');
        i++;
      }
      for (var k = 0; k < 3 && i < text.length; k++) {
        out.write(' ');
        i++;
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      final q = ch;
      out.write(ch);
      i++;
      while (i < text.length && text[i] != q) {
        if (text[i] == r'\' && i + 1 < text.length) {
          out.write(text[i]);
          out.write(text[i + 1]);
          i += 2;
          continue;
        }
        if (text[i] == '\n') break; // Unterminated: never swallow the file.
        out.write(text[i]);
        i++;
      }
      if (i < text.length && text[i] != '\n') {
        out.write(text[i]);
        i++;
      }
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

/// Error strings for misbound `.format()` calls in one `.bzl` file.
///
/// A `.format()` call is reported when a `{placeholder}` would print
/// literally. That happens in two shapes: the call binds to the last literal
/// of a `+` join (`"a{x}" + "b".format(...)`), or the receiver is a call
/// whose last argument is the message (`fail("a{x}" + "b",\n).format(...)`
/// — `fail` raises before `.format` runs, so the message prints raw; the
/// same holds for a lone literal last argument carrying placeholders).
/// The check walks the `+`-joined literal chain ending at the receiver and
/// flags placeholders in it — everywhere for a call receiver (nothing
/// formats that string), everywhere but the receiver itself for a literal
/// receiver (the receiver's own placeholders do get filled). A bare grouping
/// paren (`x = ("a" + "b").format(`, `fail(("a" + "b").format(...))`) stays
/// benign: `.format` applies to the join. Single literals with no `+`, and a
/// placeholder-free base joined to one formatted literal
/// (`_BASE + "name-{}.zip".format(...)`), all pass.
List<String> _checkMisboundFormat(String rel, String text) {
  final errors = <String>[];
  // Prose first: docstring/comment `.format(` text is never a call.
  // Masking preserves length and newlines, so offsets still line up.
  final lines = _maskProse(text).split('\n');
  // Character offset of each line start, for file:line reporting.
  final offsets = <int>[0];
  for (final line in lines) {
    offsets.add(offsets.last + line.length + 1);
  }
  for (var i = 0; i < lines.length; i++) {
    final code = _stripComment(lines[i]);
    var searchFrom = 0;
    while (true) {
      final idx = code.indexOf('.format(', searchFrom);
      if (idx < 0) break;
      searchFrom = idx + 1;
      // The statement so far: context lines plus this line up to the
      // `.format(` call. Eight lines cover a `fail(` opener above a long
      // join; the chain walk below only follows `literal + literal`
      // anyway, so wider context cannot pull in other statements.
      final window = [
        for (var k = i - 8 < 0 ? 0 : i - 8; k < i; k++) _stripComment(lines[k]),
        code.substring(0, idx),
      ].join('\n');
      var j = _skipWsBack(window, window.length - 1);
      if (j < 0) continue;
      // The suspect literals: a literal receiver fills its own
      // placeholders, so only earlier join members count; a call receiver
      // never formats anything, so the whole last-argument chain counts.
      List<String> suspects = const [];
      if (window[j] == '"' || window[j] == "'") {
        final chain = _literalChain(window, j);
        suspects = chain.length > 1 ? chain.sublist(1) : const [];
      } else if (window[j] == ')') {
        final open = _matchOpen(window, j);
        if (open < 0) continue;
        final k = _skipWsBack(window, open - 1);
        if (k < 0 || !_isIdentChar(window[k])) continue;
        // `return (...)` and friends group the join itself: `.format`
        // applies to it, so the placeholders fill — unlike `fail(...)`.
        if (_keywords.contains(_tokenBefore(window, k))) continue;
        suspects = _lastArgChain(window, j, open);
      } else {
        continue;
      }
      if (suspects.any(_placeholder.hasMatch)) {
        errors.add(
          '$rel:${_lineOf(text, offsets[i] + idx)}: `.format()` leaves a '
          '`{placeholder}` unfilled: it binds to one literal of a `+` join, '
          'or never runs on a call\'s message argument; parenthesize the '
          'join and format it directly',
        );
      }
    }
  }
  return errors;
}

void main() {
  group('misbound .format() detection (unit)', () {
    test('a placeholder in an earlier +-joined literal fails', () {
      const probe = '''
        fail(
            "flutter local SDK: listed no files under {what} ({src}); " +
            "refusing to ship an empty package".format(what = what, src = src),
        )
''';
      final errors = _checkMisboundFormat('flutter/probe.bzl', probe);
      expect(errors, hasLength(1));
      expect(errors.single, startsWith('flutter/probe.bzl:3:'));
    });

    test('a parenthesized join passes', () {
      const probe = '''
        fail((
            "flutter local SDK: listed no files under {what} ({src}); " +
            "refusing to ship an empty package"
        ).format(what = what, src = src))
''';
      expect(_checkMisboundFormat('flutter/probe.bzl', probe), isEmpty);
    });

    test('a single formatted literal passes', () {
      const probe = '''
    return "flutter local SDK: could not stage {what} ({src}); {err}".format(
        what = what,
        src = src,
        err = err,
    )
''';
      expect(_checkMisboundFormat('flutter/probe.bzl', probe), isEmpty);
    });

    test('a placeholder-free base joined to one formatted literal passes', () {
      const probe = '''
    return _ANDROID_REPOSITORY_BASE_URL + "emulator-linux_x64-{}.zip".format(build_id)
''';
      expect(_checkMisboundFormat('flutter/probe.bzl', probe), isEmpty);
    });

    test('a same-line +-join with an earlier placeholder fails', () {
      const probe = 'fail("oops {x}" + "tail".format(x = x))\n';
      expect(
        _checkMisboundFormat('flutter/probe.bzl', probe),
        hasLength(1),
      );
    });

    test('a multiline fail() join with a trailing comma fails', () {
      const probe = '''
        if not root:
            fail(
                "compile_package_config: extra_roots[{package}] is {root}: " +
                "extra_roots values must be exec-root-relative directories " +
                "(e.g. \\"flutter/tests\\"), never absolute, empty, or " +
                "escaping with \\"..\\"",
            ).format(package = repr(package), root = repr(root))
''';
      final errors = _checkMisboundFormat('flutter/probe.bzl', probe);
      expect(errors, hasLength(1));
      expect(errors.single, startsWith('flutter/probe.bzl:7:'));
    });

    test('a call with no placeholder in the join passes', () {
      const probe = '''
        fail(
            "plain message " +
            "tail",
        ).format()
''';
      expect(_checkMisboundFormat('flutter/probe.bzl', probe), isEmpty);
    });

    test('a lone literal message with a placeholder fails', () {
      const probe = 'fail("oops {x}").format(x = x)\n';
      expect(
        _checkMisboundFormat('flutter/probe.bzl', probe),
        hasLength(1),
      );
    });

    test('a grouped join assigned then formatted passes', () {
      const probe = 'x = ("a{x}" + "b").format(x = x)\n';
      expect(_checkMisboundFormat('flutter/probe.bzl', probe), isEmpty);
    });

    test('an augmented assignment before a formatted literal passes', () {
      const probe = '''
    block = ""
    if code_assets:
        lines = ['        "{}"'.format(a) for a in code_assets]
        block += "    code_assets = [\\n{}\\n    ],\\n".format("\\n".join(lines))
''';
      expect(_checkMisboundFormat('flutter/probe.bzl', probe), isEmpty);
    });

    test('a parenthesized join inside a call passes', () {
      const probe = '''
        fail((
            "oops {x} " +
            "tail"
        ).format(x = x))
''';
      expect(_checkMisboundFormat('flutter/probe.bzl', probe), isEmpty);
    });

    test('a .format() in a comment is ignored', () {
      const probe = '# "a{x}" + "b".format(x = x)\n    x = 1\n';
      expect(_checkMisboundFormat('flutter/probe.bzl', probe), isEmpty);
    });

    test('a docstring spelling out the anti-pattern is ignored', () {
      const probe = '''
def missing_local_file_message(src, what):
    """Renders the failure for an absent file.

    The whole concatenation is parenthesized before `.format()`, so every
    placeholder renders (an unparenthesized `"a{x}" + "b".format(...)`
    binds `.format()` to the last literal only).
    """
    return (
        "flutter local SDK: expected {src} ({what}), but it does not " +
        "exist; point local_path at a complete pre-extracted Flutter SDK"
    ).format(src = src, what = what)
''';
      expect(_checkMisboundFormat('flutter/probe.bzl', probe), isEmpty);
    });

    test('a hash inside a string is not a comment', () {
      const probe = 'fail("oops {x} # not a comment").format(x = x)\n';
      final errors = _checkMisboundFormat('flutter/probe.bzl', probe);
      expect(errors, hasLength(1));
    });
  });

  final root = _workspaceRoot();
  if (root == null) {
    test('format guard discovers the workspace', () {
      fail(
        'BUILD_WORKSPACE_DIRECTORY does not point at the rules_flutter '
        'workspace; run this test unsandboxed (it is tagged no-sandbox) via '
        'bazel test //flutter/tests:format_string_guard_test',
      );
    });
    return;
  }
  final bzlFiles = _findBzl(root);

  test('format guard discovers its inputs (no file list)', () {
    expect(
      bzlFiles,
      contains('flutter/private/local_sdk.bzl'),
      reason: 'the walk under flutter/ missed a known file',
    );
  });

  for (final rel in bzlFiles) {
    test('$rel binds every .format() to the whole message', () {
      final text = File('$root/$rel').readAsStringSync();
      final problems = _checkMisboundFormat(rel, text);
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }
}
