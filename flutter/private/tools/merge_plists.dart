/// Merges XML property lists — the additive seam Apple's build rules do not
/// provide.
///
/// `rules_apple` merges `infoplists` natively but takes exactly one
/// `entitlements` file, so an app that needs one extra
/// `com.apple.security.*` key would otherwise have to take over the whole
/// `flutter create` scaffold file. This tool merges a base plist with one or
/// more addition plists under one of two explicit, never-wrong modes:
///
///   --mode=strict-add  (entitlements additions, user-authored)
///       Additions may only *add*. A key the base already declares with an
///       identical value is deduped silently; a key the base declares with a
///       different value is a hard error naming the key and both files. This
///       is what `additional_entitlements` uses: the same additions are
///       merged into both the debug and the release base, and
///       `flutter create`'s DebugProfile.entitlements already declares some
///       of them, so identical-value dedupe is load-bearing.
///
///   --mode=supplement  (rules_flutter's own dev-only keys)
///       The base always wins: a key the base declares keeps the base's
///       value. Arrays under the same key are unioned, base entries first.
///       This is what the iOS Dart VM service keys use, matching Flutter's
///       `xcode_backend.dart`, so an app that declares its own
///       `NSBonjourServices` or `NSLocalNetworkUsageDescription` keeps them
///       and still gets a debuggable VM service — where passing both plists
///       to rules_apple's plisttool is a hard build failure.
///
/// `--drop-empty <key>` removes a key from the base whose value is an empty
/// string. It exists for one shape and says so: a `flutter create` scaffold
/// declares a key Xcode is expected to fill in — `CFBundleIconFile` in the
/// macOS `Info.plist` — and leaves it `<string></string>`. Nothing fills it in
/// here, and when the bundle rule generates its own value from an asset
/// catalog, Apple's plisttool refuses the pair outright: `found key
/// "CFBundleIconFile" in two plists with different values: "" != "AppIcon"`.
/// Only an empty value is dropped, so a plist that actually names an icon file
/// keeps it and the conflict is still reported.
///
/// Only the root `<dict>`'s own keys participate. Values are compared and
/// carried as verbatim XML, so nested structures pass through untouched and
/// this tool never has to understand them.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart merge_plists.dart --mode <mode> [--base <path>] \
///       [--addition <path> ...] [--drop-empty <key> ...] --output <path>
///
/// `--base` may be omitted, in which case the additions merge into an empty
/// plist (iOS apps legitimately ship no `Runner.entitlements`).
import 'dart:io';

/// How a key present in both the base and an addition is resolved.
enum MergeMode {
  /// Identical values dedupe, differing values are a hard error.
  strictAdd,

  /// The base wins; same-key arrays are unioned.
  supplement,
}

/// A `<key>`/value pair from a plist's root `<dict>`. [rawValue] is the
/// value element's verbatim XML, so nested structures round-trip untouched.
class PlistEntry {
  final String key;
  final String rawValue;

  PlistEntry(this.key, this.rawValue);
}

class PlistFormatException implements Exception {
  final String message;

  PlistFormatException(this.message);

  @override
  String toString() => message;
}

Never _reject(String path, String detail) =>
    throw PlistFormatException('Cannot merge plist $path: $detail');

/// Whitespace-insensitive comparison key for a value's XML, so
/// `<true/>` and `<true />`, or arrays differing only in indentation,
/// compare equal.
String _normalize(String xml) => xml
    .replaceAll(RegExp(r'>\s+<'), '><')
    .replaceAll(RegExp(r'\s+/>'), '/>')
    .replaceAll(RegExp(r'\s+>'), '>')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Minimal strict XML scanner, understanding only what plists need: the XML
/// declaration, the DOCTYPE, comments, and start/end/self-closing tags.
class _Scanner {
  final String text;
  final String path;
  int pos = 0;

  _Scanner(this.text, this.path);

  bool get atEnd => pos >= text.length;

  /// Consumes whitespace, comments, the XML declaration and the DOCTYPE.
  void skipInsignificant() {
    while (!atEnd) {
      final c = text[pos];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        pos++;
      } else if (text.startsWith('<!--', pos)) {
        final end = text.indexOf('-->', pos + 4);
        if (end == -1) _reject(path, 'unterminated comment.');
        pos = end + 3;
      } else if (text.startsWith('<?', pos)) {
        final end = text.indexOf('?>', pos);
        if (end == -1) _reject(path, 'unterminated processing instruction.');
        pos = end + 2;
      } else if (text.startsWith('<!DOCTYPE', pos)) {
        final end = text.indexOf('>', pos);
        if (end == -1) _reject(path, 'unterminated DOCTYPE declaration.');
        pos = end + 1;
      } else {
        break;
      }
    }
  }

  /// Reads the tag at the current position. Returns
  /// (name, selfClosing, isEndTag).
  (String, bool, bool) readTag() {
    if (atEnd || text[pos] != '<') {
      _reject(path, 'expected a tag at offset $pos.');
    }
    pos++;
    var isEndTag = false;
    if (!atEnd && text[pos] == '/') {
      isEndTag = true;
      pos++;
    }
    final start = pos;
    while (!atEnd && RegExp(r'[A-Za-z0-9_.:-]').hasMatch(text[pos])) {
      pos++;
    }
    if (pos == start) _reject(path, 'malformed tag at offset $start.');
    final name = text.substring(start, pos);

    // Skip attributes; plist elements carry at most `version`, and we never
    // need to read one.
    var inQuote = '';
    while (!atEnd) {
      final c = text[pos];
      if (inQuote.isNotEmpty) {
        if (c == inQuote) inQuote = '';
        pos++;
      } else if (c == '"' || c == "'") {
        inQuote = c;
        pos++;
      } else if (c == '>') {
        pos++;
        return (name, false, isEndTag);
      } else if (text.startsWith('/>', pos)) {
        pos += 2;
        return (name, true, isEndTag);
      } else {
        pos++;
      }
    }
    _reject(path, 'unterminated tag <$name.');
  }

  /// Consumes the element starting at the current position (which must be
  /// `<`) including everything nested inside it, and returns its verbatim
  /// XML.
  String readElement() {
    final start = pos;
    final (name, selfClosing, isEndTag) = readTag();
    if (isEndTag) _reject(path, 'unexpected close tag </$name>.');
    if (selfClosing) return text.substring(start, pos);

    var depth = 1;
    while (depth > 0) {
      final next = text.indexOf('<', pos);
      if (next == -1) _reject(path, 'unterminated element <$name>.');
      pos = next;
      if (text.startsWith('<!--', pos)) {
        final end = text.indexOf('-->', pos + 4);
        if (end == -1) _reject(path, 'unterminated comment.');
        pos = end + 3;
        continue;
      }
      final (_, nestedSelfClosing, nestedIsEnd) = readTag();
      if (nestedIsEnd) {
        depth--;
      } else if (!nestedSelfClosing) {
        depth++;
      }
    }
    return text.substring(start, pos);
  }

  /// Reads the text content up to the next `<`.
  String readText() {
    final next = text.indexOf('<', pos);
    if (next == -1) _reject(path, 'unterminated text content.');
    final content = text.substring(pos, next);
    pos = next;
    return content;
  }
}

/// Parses [xml] and returns the entries of its root `<dict>`, in order.
/// An empty document (no `<plist>`) is rejected; a plist whose root is not a
/// `<dict>` is rejected, because there is nothing to merge into.
List<PlistEntry> parsePlist(String xml, String path) {
  final scanner = _Scanner(xml, path);
  scanner.skipInsignificant();
  if (scanner.atEnd) _reject(path, 'the file has no <plist> root element.');

  final (rootName, rootSelfClosing, rootIsEnd) = scanner.readTag();
  if (rootIsEnd || rootName != 'plist') {
    _reject(path, 'the root element must be <plist>, found <$rootName>.');
  }
  if (rootSelfClosing) return [];

  scanner.skipInsignificant();
  final (dictName, dictSelfClosing, dictIsEnd) = scanner.readTag();
  if (dictIsEnd || dictName != 'dict') {
    _reject(
      path,
      'the <plist> root must contain a <dict>, found <$dictName>. '
      'Entitlements and Info.plist files are always dictionaries.',
    );
  }
  if (dictSelfClosing) return [];

  final entries = <PlistEntry>[];
  final seen = <String>{};
  while (true) {
    scanner.skipInsignificant();
    if (scanner.atEnd) _reject(path, 'the root <dict> is never closed.');
    final save = scanner.pos;
    final (name, selfClosing, isEnd) = scanner.readTag();
    if (isEnd) {
      if (name != 'dict') _reject(path, 'unexpected close tag </$name>.');
      return entries;
    }
    if (name != 'key') {
      _reject(
        path,
        'expected a <key> in the root <dict>, found <$name>. Every value '
        'in a plist dictionary must be preceded by its key.',
      );
    }
    if (selfClosing) _reject(path, 'found an empty <key/> with no name.');
    final key = scanner.readText().trim();
    final (closeName, _, closeIsEnd) = scanner.readTag();
    if (!closeIsEnd || closeName != 'key') {
      _reject(path, 'the <key> at offset $save is not closed by </key>.');
    }
    if (key.isEmpty) _reject(path, 'found a <key></key> with an empty name.');
    if (!seen.add(key)) {
      _reject(path, 'the root <dict> declares the key "$key" twice.');
    }

    scanner.skipInsignificant();
    if (scanner.atEnd ||
        scanner.text[scanner.pos] != '<' ||
        scanner.text.startsWith('</', scanner.pos)) {
      _reject(path, 'the key "$key" has no value element.');
    }
    entries.add(PlistEntry(key, scanner.readElement()));
  }
}

/// The `<string>` items of an `<array>` element's verbatim XML, or null when
/// [rawValue] is not an array of plain strings.
List<String>? _stringArrayItems(String rawValue) {
  final trimmed = rawValue.trim();
  if (!trimmed.startsWith('<array')) return null;
  final open = trimmed.indexOf('>');
  if (open == -1) return null;
  final close = trimmed.lastIndexOf('</array>');
  if (close == -1) return null;
  final body = trimmed.substring(open + 1, close);
  final items = <String>[];
  var cursor = 0;
  while (true) {
    final start = body.indexOf('<string>', cursor);
    if (start == -1) break;
    final end = body.indexOf('</string>', start);
    if (end == -1) return null;
    items.add(body.substring(start + '<string>'.length, end));
    cursor = end + '</string>'.length;
  }
  // Reject anything in the array that is not a <string>: an array we cannot
  // fully account for must never be silently rewritten.
  final withoutStrings = body.replaceAll(
    RegExp(r'<string>.*?</string>', dotAll: true),
    '',
  );
  if (withoutStrings.trim().isNotEmpty) return null;
  return items;
}

String _renderStringArray(List<String> items) {
  final buffer = StringBuffer('<array>');
  for (final item in items) {
    buffer.write('\n\t\t<string>$item</string>');
  }
  buffer.write('\n\t</array>');
  return buffer.toString();
}

/// Whether [rawValue] is an empty `<string>` element, in either spelling.
///
/// `<string></string>` is what `flutter create` writes; `<string/>` is what a
/// round trip through `plutil` or Xcode can leave behind. Both mean the same
/// nothing, and a key that is nothing is the one this tool will drop.
bool _isEmptyString(String rawValue) {
  final trimmed = rawValue.trim();
  return trimmed == '<string></string>' || trimmed == '<string/>';
}

/// Merges [additions] into [baseEntries] under [mode].
List<PlistEntry> mergeEntries({
  required List<PlistEntry> baseEntries,
  required String basePath,
  required List<(String, List<PlistEntry>)> additions,
  required MergeMode mode,
}) {
  final merged = <String, PlistEntry>{};
  final order = <String>[];
  final origin = <String, String>{};
  for (final entry in baseEntries) {
    merged[entry.key] = entry;
    order.add(entry.key);
    origin[entry.key] = basePath;
  }

  for (final (additionPath, entries) in additions) {
    for (final entry in entries) {
      final existing = merged[entry.key];
      if (existing == null) {
        merged[entry.key] = entry;
        order.add(entry.key);
        origin[entry.key] = additionPath;
        continue;
      }
      if (_normalize(existing.rawValue) == _normalize(entry.rawValue)) {
        continue;
      }
      switch (mode) {
        case MergeMode.strictAdd:
          throw PlistFormatException(
            'Conflicting value for plist key "${entry.key}":\n'
            '  ${origin[entry.key]} declares ${_normalize(existing.rawValue)}\n'
            '  $additionPath declares ${_normalize(entry.rawValue)}\n'
            'Additions may only add keys, never change one the base '
            'already sets. Edit the base file if the existing value is '
            'wrong, or drop the key from the addition.',
          );
        case MergeMode.supplement:
          final baseItems = _stringArrayItems(existing.rawValue);
          final additionItems = _stringArrayItems(entry.rawValue);
          if (baseItems != null && additionItems != null) {
            final union = <String>[...baseItems];
            for (final item in additionItems) {
              if (!union.contains(item)) union.add(item);
            }
            merged[entry.key] = PlistEntry(
              entry.key,
              _renderStringArray(union),
            );
          }
        // Otherwise the base wins and the addition is dropped.
      }
    }
  }

  return [for (final key in order) merged[key]!];
}

String renderPlist(List<PlistEntry> entries) {
  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    )
    ..writeln('<plist version="1.0">')
    ..writeln('<dict>');
  for (final entry in entries) {
    buffer
      ..writeln('\t<key>${entry.key}</key>')
      ..writeln('\t${entry.rawValue.trim()}');
  }
  buffer
    ..writeln('</dict>')
    ..writeln('</plist>');
  return buffer.toString();
}

/// Merges [additionSources] into [baseSource] under [mode] and returns the
/// rendered plist.
String mergePlists({
  required ({String path, String xml})? base,
  required List<({String path, String xml})> additionSources,
  required MergeMode mode,
  Set<String> dropEmptyKeys = const {},
}) {
  final parsedBase = base == null
      ? <PlistEntry>[]
      : parsePlist(base.xml, base.path);
  // Dropped before the merge, not after: an addition legitimately declares
  // the key this removes, and removing it afterwards would take that with it.
  final baseEntries = [
    for (final entry in parsedBase)
      if (!(dropEmptyKeys.contains(entry.key) &&
          _isEmptyString(entry.rawValue)))
        entry,
  ];
  final additions = <(String, List<PlistEntry>)>[
    for (final addition in additionSources)
      (addition.path, parsePlist(addition.xml, addition.path)),
  ];
  return renderPlist(
    mergeEntries(
      baseEntries: baseEntries,
      basePath: base?.path ?? '<empty>',
      additions: additions,
      mode: mode,
    ),
  );
}

void main(List<String> args) {
  String? basePath;
  String? outputPath;
  String? modeName;
  final additionPaths = <String>[];
  final dropEmptyKeys = <String>{};

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--base' && i + 1 < args.length) {
      basePath = args[++i];
    } else if (args[i] == '--addition' && i + 1 < args.length) {
      additionPaths.add(args[++i]);
    } else if (args[i] == '--drop-empty' && i + 1 < args.length) {
      dropEmptyKeys.add(args[++i]);
    } else if (args[i] == '--output' && i + 1 < args.length) {
      outputPath = args[++i];
    } else if (args[i] == '--mode' && i + 1 < args.length) {
      modeName = args[++i];
    } else {
      stderr.writeln('Unrecognized argument: ${args[i]}');
      exit(1);
    }
  }

  const modes = {
    'strict-add': MergeMode.strictAdd,
    'supplement': MergeMode.supplement,
  };
  final mode = modes[modeName];
  // Additions are no longer required: `--drop-empty` alone is a real job, and
  // it is the one the macOS Info.plist needs. Asking for neither is not.
  if (mode == null ||
      outputPath == null ||
      (additionPaths.isEmpty && dropEmptyKeys.isEmpty)) {
    stderr.writeln(
      'Usage: dart merge_plists.dart --mode <strict-add|supplement> '
      '[--base <path>] [--addition <path> ...] [--drop-empty <key> ...] '
      '--output <path>\n'
      'At least one of --addition or --drop-empty is required.',
    );
    exit(1);
  }

  final String merged;
  try {
    merged = mergePlists(
      base: basePath == null
          ? null
          : (path: basePath, xml: File(basePath).readAsStringSync()),
      additionSources: [
        for (final path in additionPaths)
          (path: path, xml: File(path).readAsStringSync()),
      ],
      mode: mode,
      dropEmptyKeys: dropEmptyKeys,
    );
  } on PlistFormatException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  File(outputPath).writeAsStringSync(merged);
}
