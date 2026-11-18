/// Compares what each `bzl_library` loads with what it lists in `deps`.
///
/// Stardoc, and any other consumer of `bzl_library`, reads the target's
/// transitive `.bzl` files to follow `load()` statements. A `bzl_library` that
/// leaves a loaded file out of its `deps` works only while some other target
/// happens to pull that file in, and breaks when that target changes. So the
/// property is: for every `bzl_library`, each file its `srcs` load is a `src` of
/// the library itself or of one of its direct `deps`, and no dep is listed that
/// nothing loads from.
///
/// This reads source text (BUILD files and `.bzl` files), so it covers the
/// shapes this repository writes: a `bzl_library` whose `srcs` and `deps` are
/// literal lists of double-quoted strings. Any other shape is reported, not
/// skipped.
///
/// A library of this repository is found in the BUILD files the caller hands
/// over, so a loaded file can be matched to the library that holds it. An
/// external load cannot be: the external repository's BUILD files are not
/// inputs. The convention those repositories follow, and the one a dep is
/// required to follow here, is a library named for the file
/// (`@rules_cc//cc:find_cc_toolchain` for
/// `@rules_cc//cc:find_cc_toolchain.bzl`); [ExternalExceptions] names the loads
/// that need something else.
library;

/// A Bazel label, normalised: the main repository has a null [repo], and
/// `@rules_flutter//` spellings of it are folded in.
class Label {
  const Label(this.repo, this.pkg, this.name);

  /// Parses [raw], read in [package] of the main repository when it is
  /// relative (`:name`, or a bare file name).
  factory Label.parse(String raw, {required String package}) {
    var s = raw;
    String? repo;
    if (s.startsWith('@')) {
      final slashes = s.indexOf('//');
      if (slashes < 0) throw FormatException('not a label', raw);
      repo = s.substring(0, slashes).replaceFirst(RegExp('^@@?'), '');
      s = s.substring(slashes);
      if (repo == 'rules_flutter') repo = null;
    }
    if (s.startsWith('//')) {
      final colon = s.indexOf(':');
      final pkg = colon < 0 ? s.substring(2) : s.substring(2, colon);
      final name = colon < 0 ? pkg.split('/').last : s.substring(colon + 1);
      return Label(repo, pkg, name);
    }
    if (s.startsWith(':')) return Label(null, package, s.substring(1));
    return Label(null, package, s);
  }

  final String? repo;
  final String pkg;
  final String name;

  bool get isExternal => repo != null;

  /// The name without its `.bzl`, which is what a library for the file is
  /// called.
  String get stem => name.endsWith('.bzl')
      ? name.substring(0, name.length - '.bzl'.length)
      : name;

  /// The label of the library an external load is expected to be listed as.
  Label get externalLibrary => Label(repo, pkg, stem);

  @override
  bool operator ==(Object other) =>
      other is Label &&
      other.repo == repo &&
      other.pkg == pkg &&
      other.name == name;

  @override
  int get hashCode => Object.hash(repo, pkg, name);

  @override
  String toString() => '${repo == null ? '' : '@$repo'}//$pkg:$name';
}

/// One `bzl_library(...)` call.
class BzlLibrary {
  const BzlLibrary({
    required this.label,
    required this.srcs,
    required this.deps,
  });

  final Label label;
  final List<Label> srcs;
  final List<Label> deps;
}

/// Loads that cannot be covered by a dep named for the loaded file, and what
/// to do about each.
class ExternalExceptions {
  const ExternalExceptions({
    this.library = const {},
    this.noLibrary = const {},
  });

  /// A load whose library has another name: the load's file label, as written
  /// in the `load()`, to the label of the library that holds it.
  final Map<String, String> library;

  /// Loads that have no `bzl_library` anywhere (a generated repository's file,
  /// say), each with the reason. They need no dep.
  final Map<String, String> noLibrary;
}

/// Removes comments from Starlark [text], and empties triple-quoted strings
/// (docstrings). Other strings stay as they are.
String stripComments(String text) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (text.startsWith('"""', i)) {
      final end = text.indexOf('"""', i + 3);
      i = end < 0 ? text.length : end + 3;
      out.write('""');
    } else if (c == '"' || c == "'") {
      out.write(c);
      i++;
      while (i < text.length && text[i] != c && text[i] != '\n') {
        if (text[i] == r'\' && i + 1 < text.length) {
          out.write(text[i]);
          i++;
        }
        out.write(text[i]);
        i++;
      }
      if (i < text.length && text[i] == c) {
        out.write(c);
        i++;
      }
    } else if (c == '#') {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// The text between the parenthesis that opens at [open] and its match.
String _balanced(String text, int open) {
  var depth = 0;
  var i = open;
  while (i < text.length) {
    final c = text[i];
    if (c == '"' || c == "'") {
      i++;
      while (i < text.length && text[i] != c) {
        if (text[i] == r'\') i++;
        i++;
      }
    } else if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return text.substring(open + 1, i);
    }
    i++;
  }
  throw FormatException('unbalanced parenthesis', text, open);
}

final _stringLiteral = RegExp(r'"([^"\\\n]*)"');

List<String> _strings(String text) => [
  for (final m in _stringLiteral.allMatches(text)) m.group(1)!,
];

/// The label of every file that [bzlText] `load()`s, as written.
List<String> loadsOf(String bzlText) {
  final text = stripComments(bzlText);
  final loads = <String>[];
  for (final m in RegExp(r'^load\(', multiLine: true).allMatches(text)) {
    final args = _balanced(text, m.end - 1);
    final strings = _strings(args);
    if (strings.isEmpty) {
      throw FormatException('a load() without a label', args);
    }
    loads.add(strings.first);
  }
  return loads;
}

/// The `bzl_library` calls of the BUILD file [buildText] of [package].
///
/// Throws a [FormatException] for a call whose `name`, `srcs` or `deps` is not
/// a literal.
List<BzlLibrary> bzlLibrariesOf(String package, String buildText) {
  final text = stripComments(buildText);
  final libraries = <BzlLibrary>[];
  for (final m in RegExp(r'^bzl_library\(', multiLine: true).allMatches(text)) {
    final args = _balanced(text, m.end - 1);
    final name = RegExp(r'\bname\s*=\s*"([^"]+)"').firstMatch(args)?.group(1);
    if (name == null) {
      throw FormatException('a bzl_library without a literal name', args);
    }
    List<Label> list(String attr) {
      final start = RegExp('\\b$attr\\s*=\\s*').firstMatch(args);
      if (start == null) return const [];
      final rest = args.substring(start.end);
      final literal = RegExp(r'^\[([^\]]*)\]\s*(,|$)').firstMatch(rest);
      if (literal == null) {
        throw FormatException(
          '//$package:$name: $attr is not a literal list of strings, which '
          'this check reads',
          rest,
        );
      }
      return [
        for (final s in _strings(literal.group(1)!))
          Label.parse(s, package: package),
      ];
    }

    libraries.add(
      BzlLibrary(
        label: Label(null, package, name),
        srcs: list('srcs'),
        deps: list('deps'),
      ),
    );
  }
  return libraries;
}

/// Checks every library of [libraries] and returns what is wrong, one line
/// each, empty when nothing is.
///
/// [readBzl] returns the text of a `.bzl` file of this repository.
List<String> checkBzlLibraries(
  List<BzlLibrary> libraries, {
  required String Function(Label file) readBzl,
  ExternalExceptions exceptions = const ExternalExceptions(),
}) {
  final holder = <Label, BzlLibrary>{};
  for (final library in libraries) {
    for (final src in library.srcs) {
      holder[src] = library;
    }
  }

  final problems = <String>[];
  for (final library in libraries) {
    final own = library.srcs.toSet();
    final required = <Label, String>{};
    for (final src in library.srcs) {
      if (!src.name.endsWith('.bzl')) continue;
      final String text;
      try {
        text = readBzl(src);
      } on Object catch (e) {
        problems.add('${library.label}: cannot read $src ($e)');
        continue;
      }
      for (final raw in loadsOf(text)) {
        final loaded = Label.parse(raw, package: src.pkg);
        if (own.contains(loaded)) continue;
        if (loaded.isExternal) {
          if (exceptions.noLibrary.containsKey(raw)) continue;
          final other = exceptions.library[raw];
          final dep = other == null
              ? loaded.externalLibrary
              : Label.parse(other, package: src.pkg);
          required[dep] = '$src loads $raw';
        } else {
          final target = holder[loaded];
          if (target == null) {
            problems.add(
              '${library.label}: $src loads $loaded, which no bzl_library '
              'lists in its srcs',
            );
          } else {
            required[target.label] = '$src loads $loaded';
          }
        }
      }
    }
    final deps = library.deps.toSet();
    for (final entry in required.entries) {
      if (!deps.contains(entry.key)) {
        problems.add(
          '${library.label}: missing dep ${entry.key} (${entry.value})',
        );
      }
    }
    for (final dep in library.deps) {
      if (!required.containsKey(dep)) {
        problems.add(
          '${library.label}: dep $dep is not needed; no src loads from it',
        );
      }
    }
  }
  return problems;
}
