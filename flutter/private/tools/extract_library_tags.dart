/// Library-level `@Tags` of a test entrypoint, for the test runners.
///
/// `package:test` reads a suite's `@Tags` off its source with the analyzer
/// (`test_core`'s `parseMetadata`, first directive's metadata only) and hands
/// them to the test isolate in the `RemoteListener` initial message, where
/// they become the root group's metadata and every test inherits them. Under
/// Bazel no analyzer runs at test time, so this tool runs at build time over
/// the test's `main` and writes the tags for the runner to send instead. Only
/// the entrypoint file's own annotations count, as upstream: `@Tags` on files
/// it imports applies to nothing.
///
/// Usage: `extract_library_tags <test.dart> <tags.json>`, writing
/// `{"tags": [...]}` (sorted, so the output bytes are deterministic).
library;

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'extract_library_tags: usage: extract_library_tags <test.dart> <tags.json>',
    );
    exit(64);
  }
  late final Set<String> tags;
  try {
    tags = extractLibraryTags(File(args[0]).readAsStringSync());
  } on TagsParseException catch (e) {
    stderr.writeln('extract_library_tags: ${args[0]}:${e.line}: ${e.message}');
    exit(1);
  }
  final sorted = tags.toList()..sort();
  File(args[1]).writeAsStringSync('${json.encode({'tags': sorted})}\n');
}

/// A `@Tags(...)` annotation holding something `test_core`'s `parseMetadata`
/// would not accept, with the 1-based line of the offending construct.
final class TagsParseException implements Exception {
  TagsParseException(this.line, this.message);

  final int line;
  final String message;

  @override
  String toString() => 'line $line: $message';
}

/// The `@Tags` string literals attached to [source]'s first directive, as
/// `test_core`'s `parseMetadata` reads `directives.first.metadata`.
///
/// A hand scanner rather than the analyzer: the tools here cannot import it,
/// and only string lists are of interest. It accepts exactly what upstream
/// accepts — a typed or untyped list literal of plain string literals, with an
/// optional `const`, adjacent and raw strings, trailing commas and comments —
/// and throws [TagsParseException] for anything else in a `@Tags(...)`, as
/// upstream throws `SourceSpanFormatException`: a non-list argument, a
/// non-string element (including one with interpolation, whose value is not
/// constant), an invalid tag name, or a second `@Tags` annotation.
///
/// Name resolution follows upstream's `_resolveConstructor`: a bare `@Tags`
/// always counts, and `@p.Tags` counts when `p` is an import prefix in the
/// file. The one narrowing is deliberate: upstream accepts any prefix (a
/// re-export could supply `Tags`), while this scanner accepts only prefixes
/// imported from `package:test` or `package:flutter_test`, the libraries
/// whose `Tags` `flutter test` reads. Anything else (`@visibleForTesting`,
/// `@p.Tags` for another library's `p`) is skipped over, strings and comments
/// included.
Set<String> extractLibraryTags(String source) {
  // A script tag (`#!/usr/bin/env dart`) may open the file; the analyzer's
  // scanner skips it before the first directive, so this scan does too.
  var i = 0;
  if (source.startsWith('#!')) {
    final newline = source.indexOf('\n');
    i = newline < 0 ? source.length : newline + 1;
  }
  // The annotations before the first directive: the only ones upstream reads.
  // Their arguments stay unparsed here — whether `@p.Tags` counts depends on
  // the imports below, which textually follow — so each is only skipped over.
  final candidates = <int>[];
  var directivesStart = source.length;
  while (true) {
    i = _skipTrivia(source, i);
    if (i >= source.length) return const {};
    if (source[i] == '@') {
      candidates.add(i);
      i = _skipAnnotationTail(source, i);
    } else if (_isDirective(source, i)) {
      directivesStart = i;
      break;
    } else {
      // A declaration before any directive: the file has no directives, so
      // upstream reads no annotations either.
      return const {};
    }
  }
  final testPrefixes = _testImportPrefixes(source, directivesStart);
  final found = <String>[];
  var seenTags = false;
  for (final at in candidates) {
    final name = _parseDottedName(source, at + 1);
    if (name.segments.isEmpty || name.segments.last != 'Tags') continue;
    if (name.segments.length == 1) {
      // A bare `@Tags`, as upstream resolves it with no import check.
    } else if (name.segments.length == 2 &&
        testPrefixes.contains(name.segments.first)) {
      // `@p.Tags` through a `package:test` / `package:flutter_test` prefix
      // import, the libraries whose `Tags` upstream reads.
    } else {
      continue;
    }
    // Upstream rejects a second `@Tags` before reading it.
    if (seenTags) {
      throw TagsParseException(
        _lineOf(source, at),
        'Only a single Tags may be used.',
      );
    }
    seenTags = true;
    found.addAll(_parseTagsAnnotation(source, at, name.end));
  }
  return found.toSet();
}

/// The tags in the `@Tags` annotation at [at] whose dotted name ends at
/// [nameEnd]: its argument list, strictly parsed.
///
/// Anything but `@Tags([...])` never reaches here (a bare `@Tags` with no
/// argument list cannot compile, so it is skipped, not reported): the caller
/// resolves the name first, and only a resolvable `Tags` is parsed.
List<String> _parseTagsAnnotation(String source, int at, int nameEnd) {
  var j = _skipTrivia(source, nameEnd);
  if (j < source.length && source[j] == '<') {
    j = _skipTrivia(source, _skipTypeArguments(source, j));
  }
  if (j >= source.length || source[j] != '(') return const [];
  return _parseTagsArgument(source, j).tags;
}

/// The `@Tags(...)` argument list opening at [i] (the `(`) and the tags in it.
///
/// After an optional `const` and optional type arguments (as in
/// `@Tags(<String>['a'])`, still a `ListLiteral` upstream) must come the list
/// of plain string literals. Anything else throws [TagsParseException] with
/// upstream's wording where upstream has words for it (`Expected a List.`,
/// `Expected only literal elements.`, `Expected a String literal.`).
({int end, List<String> tags}) _parseTagsArgument(String source, int i) {
  var j = _openTagList(source, i);
  final tags = <String>[];
  while (true) {
    j = _skipTrivia(source, j);
    if (j >= source.length) {
      throw TagsParseException(
        _lineOf(source, j),
        'Unterminated list in @Tags.',
      );
    }
    final closed = _closeTagList(source, j);
    if (closed != null) return (end: closed, tags: tags);
    final element = _readTagElement(source, j);
    tags.add(element.value);
    j = element.end;
  }
}

/// Past the `@Tags(` opener at [i] (the `(`): the optional `const`, the
/// optional type arguments and the opening `[` of the tag list.
///
/// Anything but a `[` throws [TagsParseException] with upstream's wording
/// (`Expected a List.`), as `@Tags(<String>['a'])` is still a `ListLiteral`
/// upstream.
int _openTagList(String source, int i) {
  var j = _skipTrivia(source, i + 1);
  if (_readsKeyword(source, j, 'const')) j = _skipTrivia(source, j + 5);
  if (j < source.length && source[j] == '<') {
    j = _skipTypeArguments(source, j);
  }
  if (j >= source.length || source[j] != '[') {
    throw TagsParseException(_lineOf(source, j), 'Expected a List.');
  }
  return j + 1;
}

/// Past the `]` and `)` closing a `@Tags` list at [j], or null when [j] does
/// not open the close.
int? _closeTagList(String source, int j) {
  if (source[j] != ']') return null;
  final after = _skipTrivia(source, j + 1);
  if (after >= source.length || source[after] != ')') {
    throw TagsParseException(
      _lineOf(source, after),
      'Expected ) to close @Tags.',
    );
  }
  return after + 1;
}

/// The one tag list element at [j], and the offset past its `,` separator —
/// or at its `]` when it is the last element.
///
/// A non-string element throws [TagsParseException]: upstream distinguishes
/// collection elements (spreads, `if` and `for` elements) from other
/// non-strings, and both are errors here. A name no selector can name is
/// refused with upstream's wording.
({int end, String value}) _readTagElement(String source, int j) {
  if (_readsKeyword(source, j, 'const')) j = _skipTrivia(source, j + 5);
  final literalStart = j;
  final literal = _parseString(source, j, strict: true);
  if (literal == null) {
    if (source.startsWith('...', j) ||
        _readsKeyword(source, j, 'if') ||
        _readsKeyword(source, j, 'for')) {
      throw TagsParseException(
        _lineOf(source, j),
        'Expected only literal elements.',
      );
    }
    throw TagsParseException(
      _lineOf(source, j),
      'Expected a String literal.',
    );
  }
  if (!_tagName.hasMatch(literal.value)) {
    throw TagsParseException(
      _lineOf(source, literalStart),
      'Invalid tag name. Tags must be (optionally hyphenated) Dart '
      'identifiers.',
    );
  }
  j = _skipTrivia(source, literal.end);
  if (j < source.length && source[j] == ',') {
    j++;
  } else if (j >= source.length || source[j] != ']') {
    throw TagsParseException(
      _lineOf(source, j),
      'Expected , or ] in @Tags.',
    );
  }
  return (end: j, value: literal.value);
}

/// Past the `//` or `/*` comment, or the string literal, opening at [j] — or
/// null when neither opens there.
///
/// The scanners below all step over comments and strings the same way; the
/// helper keeps the one copy. An opener whose literal never closes steps past
/// the opener: the file does not compile, so no tags are ever read from it.
int? _skipTriviaOrString(String source, int j) {
  final c = source[j];
  if (c == '/' &&
      j + 1 < source.length &&
      (source[j + 1] == '/' || source[j + 1] == '*')) {
    return _skipTrivia(source, j);
  }
  if (c == "'" ||
      c == '"' ||
      (c == 'r' &&
          j + 1 < source.length &&
          (source[j + 1] == "'" || source[j + 1] == '"'))) {
    final literal = _parseString(source, j);
    return literal == null ? j + 1 : literal.end;
  }
  return null;
}

/// Past the `<...>` type arguments opening at [i]. Type arguments hold no
/// directive punctuation, so meeting any — or the end of the file — throws
/// rather than wandering the rest of the file.
int _skipTypeArguments(String source, int i) {
  var depth = 0;
  var j = i;
  while (j < source.length) {
    final c = source[j];
    if (c == '<') {
      depth++;
      j++;
    } else if (c == '>') {
      depth--;
      j++;
      if (depth == 0) return j;
    } else if (c == ';' ||
        c == '(' ||
        c == ')' ||
        c == '[' ||
        c == ']' ||
        c == '{' ||
        c == '}' ||
        c == '@') {
      throw TagsParseException(
        _lineOf(source, j),
        'Unterminated type arguments in @Tags.',
      );
    } else {
      j = _skipTriviaOrString(source, j) ?? (j + 1);
    }
  }
  throw TagsParseException(
    _lineOf(source, i),
    'Unterminated type arguments in @Tags.',
  );
}

/// A tag name, as `test_api`'s `anchoredHyphenatedIdentifier` accepts it: a
/// Dart identifier that may also contain hyphens. Anything else in a `@Tags`
/// is refused with upstream's wording, because a tag no selector can name
/// would silently never match.
final _tagName = RegExp(r'^[a-zA-Z_-][a-zA-Z0-9_-]*$');

/// The 1-based line number of [offset] in [source], for error messages.
int _lineOf(String source, int offset) {
  var line = 1;
  final end = offset < source.length ? offset : source.length;
  for (var k = 0; k < end; k++) {
    if (source[k] == '\n') line++;
  }
  return line;
}

/// Whether the word at [i] opens a directive (`library`, `import`, `export`,
/// or `part`), as opposed to a declaration that happens to start with those
/// letters. A directive keyword is never followed by `(`, while a declaration
/// naming a function `import` is.
bool _isDirective(String source, int i) {
  for (final keyword in const ['library', 'import', 'export', 'part']) {
    if (!_readsKeyword(source, i, keyword)) continue;
    var j = _skipTrivia(source, i + keyword.length);
    if (keyword == 'part') {
      // `part of ...;` or `part '...';`; `part(` is a declaration.
      if (_readsKeyword(source, j, 'of')) return true;
      if (j < source.length && (source[j] == "'" || source[j] == '"')) {
        return true;
      }
      return false;
    }
    if (j < source.length && source[j] == '(') return false;
    return true;
  }
  return false;
}

/// Whether [word] sits at [i] with a non-identifier character on each side.
bool _readsKeyword(String source, int i, String word) {
  if (i > 0 && _isIdentifierChar(source[i - 1])) return false;
  if (!source.startsWith(word, i)) return false;
  final after = i + word.length;
  return after >= source.length || !_isIdentifierChar(source[after]);
}

bool _isIdentifierChar(String c) {
  return c == '_' ||
      c == r'$' ||
      (c.compareTo('a') >= 0 && c.compareTo('z') <= 0) ||
      (c.compareTo('A') >= 0 && c.compareTo('Z') <= 0) ||
      (c.compareTo('0') >= 0 && c.compareTo('9') <= 0);
}

/// The dotted name at [i] (`Tags`, or `prefix.Tags`), with whitespace and
/// comments (line, block and doc, all trivia to the analyzer) skipped wherever
/// Dart allows them: between `@` and the first segment, around each `.`, and
/// after the last segment. Trivia never splits an identifier itself, so
/// `Tag/*c*/s` stays two words, not one segment.
({int end, List<String> segments}) _parseDottedName(String source, int i) {
  final segments = <String>[];
  var j = _skipTrivia(source, i);
  var end = j;
  while (true) {
    final start = j;
    while (j < source.length && _isIdentifierChar(source[j])) {
      j++;
    }
    if (j == start) break;
    segments.add(source.substring(start, j));
    end = j;
    final dot = _skipTrivia(source, j);
    if (dot >= source.length || source[dot] != '.') break;
    final next = _skipTrivia(source, dot + 1);
    if (next >= source.length || !_isIdentifierChar(source[next])) break;
    j = next;
  }
  return (end: end, segments: segments);
}

/// Past an annotation at [i]: its type arguments, dotted continuations and
/// argument list, over strings and comments. Never throws — this is the
/// skipping pass, and a malformed non-`Tags` annotation must not fail the
/// scan; the compiler rejects the file with better words.
int _skipAnnotationTail(String source, int i) {
  final name = _parseDottedName(source, i + 1);
  var j = _skipTrivia(source, name.end);
  while (j < source.length) {
    if (source[j] == '<') {
      // Type arguments, as on a generic annotation (`@Foo<int>(...)`): the
      // `<` after an annotation name can open nothing else this early in the
      // file. Bailing past the end when unterminated ends the hunt with no
      // tags, which is all a file this broken deserves from a scanner.
      try {
        j = _skipTypeArguments(source, j);
      } on TagsParseException {
        return source.length;
      }
      j = _skipTrivia(source, j);
    } else if (source[j] == '.') {
      // A dotted continuation after type arguments (`@C<T>.named(...)`),
      // with trivia around the dot as the analyzer allows.
      final next = _skipTrivia(source, j + 1);
      if (next >= source.length || !_isIdentifierChar(source[next])) break;
      j = next;
      while (j < source.length && _isIdentifierChar(source[j])) {
        j++;
      }
      j = _skipTrivia(source, j);
    } else {
      break;
    }
  }
  if (j < source.length && source[j] == '(') {
    return _skipBalanced(source, j, '(', ')');
  }
  return j;
}

/// The prefixes `package:test` / `package:flutter_test` are imported under,
/// scanning the directives from [i] until the first declaration. Only these
/// libraries' `Tags` counts for a `@p.Tags` (see [extractLibraryTags]); the
/// scan skips every other directive and annotation exactly as the main loop
/// does, because a `@p.Tags` may precede the import that binds `p`.
Set<String> _testImportPrefixes(String source, int i) {
  final prefixes = <String>{};
  while (true) {
    i = _skipTrivia(source, i);
    if (i >= source.length) return prefixes;
    if (source[i] == '@') {
      i = _skipAnnotationTail(source, i);
    } else if (_isDirective(source, i)) {
      if (_readsKeyword(source, i, 'import')) {
        final prefix = _testImportPrefix(source, i);
        if (prefix != null) prefixes.add(prefix);
      }
      i = _skipDirective(source, i);
    } else {
      return prefixes;
    }
  }
}

/// The prefix the `import` directive at [i] binds, when it imports
/// `package:test` or `package:flutter_test` — the libraries that expose the
/// `Tags` annotation `flutter test` reads — else null.
///
/// Conditional (`if (cond) 'uri'`) and `deferred` imports bind the same way;
/// `show` / `hide` combinators are not read, which over-accepts a prefix whose
/// import hides `Tags`. Upstream resolves the annotation through the analyzer
/// and would not count it; nobody writes that import, so the scanner trades
/// the case for staying a scanner.
String? _testImportPrefix(String source, int i) {
  var j = _skipTrivia(source, i + 'import'.length);
  if (j >= source.length) return null;
  // The URI in its own variable: `parsed` is reassigned in the loop below,
  // which would un-promote a record local read after it.
  var parsed = _parseString(source, j);
  if (parsed == null) return null;
  var uri = parsed.value;
  j = _skipTrivia(source, parsed.end);
  while (_readsKeyword(source, j, 'if')) {
    var k = _skipTrivia(source, j + 2);
    if (k >= source.length || source[k] != '(') return null;
    j = _skipTrivia(source, _skipBalanced(source, k, '(', ')'));
    if (j >= source.length) return null;
    parsed = _parseString(source, j);
    if (parsed == null) return null;
    uri = parsed.value;
    j = _skipTrivia(source, parsed.end);
  }
  if (_readsKeyword(source, j, 'deferred')) j = _skipTrivia(source, j + 8);
  if (!_readsKeyword(source, j, 'as')) return null;
  j = _skipTrivia(source, j + 2);
  final start = j;
  while (j < source.length && _isIdentifierChar(source[j])) {
    j++;
  }
  if (j == start) return null;
  return _isTestUri(uri) ? source.substring(start, j) : null;
}

/// Whether [uri] is an import of `package:test` or `package:flutter_test`.
bool _isTestUri(String uri) {
  if (!uri.startsWith('package:')) return false;
  final first = uri.substring('package:'.length).split('/').first;
  return first == 'test' || first == 'flutter_test';
}

/// Past the balanced [open]..[close] pair opening at [i], over strings and
/// comments. Past the end when unbalanced.
int _skipBalanced(String source, int i, String open, String close) {
  var depth = 0;
  var j = i;
  while (j < source.length) {
    final c = source[j];
    if (c == open) {
      depth++;
      j++;
    } else if (c == close) {
      depth--;
      j++;
      if (depth == 0) return j;
    } else {
      j = _skipTriviaOrString(source, j) ?? (j + 1);
    }
  }
  return j;
}

/// Past the directive opening at [i]: through its `;` at depth zero, over
/// strings, comments and parenthesised configuration (`if (cond) 'uri'`).
int _skipDirective(String source, int i) {
  var depth = 0;
  var j = i;
  while (j < source.length) {
    final c = source[j];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
      j++;
    } else if (c == ')' || c == ']' || c == '}') {
      if (depth > 0) depth--;
      j++;
    } else if (c == ';' && depth == 0) {
      return j + 1;
    } else {
      j = _skipTriviaOrString(source, j) ?? (j + 1);
    }
  }
  return j;
}

/// The string literal (with `r` prefix and adjacent concatenation) at [i], or
/// null when none opens there. With [strict], an interpolation throws
/// [TagsParseException]: it has no constant value, so upstream's
/// `parseMetadata` rejects it with `Expected a String literal.` Without it,
/// interpolations are skipped, not evaluated, for scans over code whose
/// strings never become tags.
({int end, String value})? _parseString(
  String source,
  int i, {
  bool strict = false,
}) {
  var j = i;
  var raw = false;
  if (source[j] == 'r') {
    raw = true;
    j++;
  }
  if (j >= source.length || (source[j] != "'" && source[j] != '"')) {
    return null;
  }
  final quote = source[j];
  var triple = false;
  if (source.startsWith(quote * 3, j)) {
    triple = true;
    j += 3;
  } else {
    j++;
  }
  final close = triple ? quote * 3 : quote;
  final value = StringBuffer();
  while (j < source.length) {
    if (source.startsWith(close, j)) {
      j += close.length;
      // Adjacent literals concatenate, as upstream's `_parseString` joins
      // them. The recursive call already folds longer chains, so the string
      // is complete here: returning, not continuing, is what keeps a comma
      // or a following annotation out of the value.
      final next = _skipTrivia(source, j);
      final continued = _parseString(source, next, strict: strict);
      if (continued != null) {
        value.write(continued.value);
        return (end: continued.end, value: value.toString());
      }
      return (end: j, value: value.toString());
    }
    final c = source[j];
    if (!raw && c == r'\') {
      final escape = _parseEscape(source, j, strict: strict);
      value.write(escape.value);
      j = escape.end;
    } else if (!raw && c == r'$') {
      if (strict) {
        throw TagsParseException(
          _lineOf(source, j),
          'Expected a String literal.',
        );
      }
      final interpolation = _skipInterpolation(source, j);
      // A placeholder no tag can equal: the file does not compile, so this
      // value is never compared against a selection.
      value.write('\u{0}');
      j = interpolation;
    } else if (!triple && (c == '\n' || c == '\r')) {
      return null;
    } else {
      value.write(c);
      j++;
    }
  }
  return null;
}

/// The escape opening at [i] (`\` plus its sequence) and the character it
/// stands for. With [strict], an unknown escape throws [TagsParseException]:
/// it is a compile error in the file, so upstream never reads tags from it,
/// and decoding it to something else would name a tag the file cannot carry.
/// Without it the character is kept literally: a skipped-over string's escapes
/// never become tags.
({int end, String value}) _parseEscape(
  String source,
  int i, {
  bool strict = false,
}) {
  final j = i + 1;
  if (j >= source.length) return (end: j, value: r'\');
  final c = source[j];
  switch (c) {
    case 'n':
      return (end: j + 1, value: '\n');
    case 'r':
      return (end: j + 1, value: '\r');
    case 't':
      return (end: j + 1, value: '\t');
    case 'b':
      return (end: j + 1, value: '\b');
    case 'f':
      return (end: j + 1, value: '\f');
    case 'v':
      return (end: j + 1, value: '\v');
    case '0':
      return (end: j + 1, value: '\0');
    case 'x':
      final hex = _parseHex(source, j + 1, 2);
      return (end: hex.end, value: hex.value);
    case 'u':
      if (j + 1 < source.length && source[j + 1] == '{') {
        final end = source.indexOf('}', j + 2);
        if (end < 0) return (end: j + 1, value: 'u');
        final code = int.tryParse(source.substring(j + 2, end), radix: 16);
        if (code == null) return (end: j + 1, value: 'u');
        return (end: end + 1, value: String.fromCharCode(code));
      }
      final hex = _parseHex(source, j + 1, 4);
      return (end: hex.end, value: hex.value);
    default:
      if (strict) {
        throw TagsParseException(
          _lineOf(source, i),
          'Expected a String literal.',
        );
      }
      return (end: j + 1, value: c);
  }
}

/// Up to [digits] hex digits at [i] as the character they encode, or a literal
/// read when none follow.
({int end, String value}) _parseHex(String source, int i, int digits) {
  final hex = RegExp(r'^[0-9a-fA-F]+').stringMatch(source.substring(i));
  if (hex == null || hex.isEmpty) return (end: i, value: '');
  final take = hex.length < digits ? hex.length : digits;
  return (
    end: i + take,
    value: String.fromCharCode(int.parse(hex.substring(0, take), radix: 16)),
  );
}

/// Past the `$name` or `${...}` interpolation opening at [i], over nested
/// braces, strings and comments.
int _skipInterpolation(String source, int i) {
  if (i + 1 < source.length && source[i + 1] == '{') {
    return _skipBalanced(source, i + 1, '{', '}');
  }
  var j = i + 1;
  while (j < source.length && _isIdentifierChar(source[j])) {
    j++;
  }
  return j;
}

/// Past whitespace and comments from [i]. Block comments nest, as the
/// analyzer nests them: `/* /* */` needs two closers, so a `@Tags` after one
/// is still found.
int _skipTrivia(String source, int i) {
  var j = i;
  while (j < source.length) {
    final c = source[j];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f') {
      j++;
    } else if (c == '/' && j + 1 < source.length && source[j + 1] == '/') {
      final end = source.indexOf('\n', j + 2);
      j = end < 0 ? source.length : end + 1;
    } else if (c == '/' && j + 1 < source.length && source[j + 1] == '*') {
      j = _skipNestedComment(source, j);
    } else {
      break;
    }
  }
  return j;
}

/// Past the block comment opening at [i] (`/*`), over nested block comments.
/// Comment text is opaque — a quote or `//` inside one opens nothing — so
/// only `/*` and `*/` move the scan. Past the end when unterminated.
int _skipNestedComment(String source, int i) {
  var j = i + 2;
  var depth = 1;
  while (j < source.length && depth > 0) {
    if (source[j] == '/' && j + 1 < source.length && source[j + 1] == '*') {
      depth++;
      j += 2;
    } else if (source[j] == '*' &&
        j + 1 < source.length &&
        source[j + 1] == '/') {
      depth--;
      j += 2;
    } else {
      j++;
    }
  }
  return j;
}
