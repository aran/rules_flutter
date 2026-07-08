/// Merges a `flutter create` debug variant AndroidManifest.xml into a main
/// (base) manifest, the way Gradle's manifest merger folds
/// `android/app/src/debug/AndroidManifest.xml` into debug APKs.
///
/// This tool implements deliberately narrow, never-wrong semantics: the
/// overlay may contain ONLY `<uses-permission>` / `<uses-permission-sdk-23>`
/// elements carrying exactly an `android:name` attribute (plus comments and
/// whitespace). Anything else — other elements, other attributes, text
/// content, `${...}` Gradle placeholders — is a hard error naming the
/// offending construct, so an overlay this tool cannot faithfully merge can
/// never be silently mis-merged. Users with richer variant manifests pass
/// `debug_manifest` on `flutter_android_app` explicitly (or restructure).
///
/// The base manifest is never re-serialized: merged permissions are inserted
/// textually right after the root `<manifest ...>` open tag, so every base
/// byte the tool doesn't understand passes through untouched.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart merge_android_manifests.dart --base <path> --overlay <path> --output <path>
import 'dart:io';

/// Pointer at the Tier-1 escape hatch, appended to every rejection.
const _escapeHatch = 'If the overlay needs constructs this merger does not '
    'support, pass an explicit merged manifest via the `debug_manifest` '
    'attribute of `flutter_android_app` instead.';

/// The overlay element names whose permissions we merge.
const _permissionElements = {'uses-permission', 'uses-permission-sdk-23'};

/// A permission declaration parsed from the overlay.
class OverlayPermission {
  /// `uses-permission` or `uses-permission-sdk-23`.
  final String element;

  /// The `android:name` value, e.g. `android.permission.INTERNET`.
  final String name;

  OverlayPermission(this.element, this.name);
}

Never _reject(String overlayPath, String detail) {
  throw FormatException(
      'Cannot merge debug variant manifest $overlayPath: $detail\n'
      '$_escapeHatch');
}

/// Minimal strict XML scanner shared by the overlay parser and the base
/// open-tag locator. Understands only what these manifests need: the XML
/// declaration, comments, and start/end/self-closing tags with
/// double-or-single-quoted attributes.
class _Scanner {
  final String text;
  int pos = 0;

  _Scanner(this.text);

  bool get atEnd => pos >= text.length;

  /// Consumes whitespace, comments, and (at position 0) the XML declaration.
  void skipInsignificant() {
    while (!atEnd) {
      final c = text[pos];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        pos++;
      } else if (text.startsWith('<!--', pos)) {
        final end = text.indexOf('-->', pos + 4);
        if (end == -1) {
          throw const FormatException('unterminated comment');
        }
        pos = end + 3;
      } else if (pos == 0 && text.startsWith('<?xml', pos)) {
        final end = text.indexOf('?>', pos);
        if (end == -1) {
          throw const FormatException('unterminated XML declaration');
        }
        pos = end + 2;
      } else {
        break;
      }
    }
  }

  /// Parses a tag at the current position (which must be `<`). Returns
  /// (name, attributes, selfClosing, isEndTag). Attribute order is
  /// preserved; duplicate attribute names are an error.
  (String, Map<String, String>, bool, bool) readTag() {
    if (atEnd || text[pos] != '<') {
      throw FormatException('expected a tag at offset $pos');
    }
    pos++;
    var isEndTag = false;
    if (!atEnd && text[pos] == '/') {
      isEndTag = true;
      pos++;
    }
    final name = _readName();
    final attributes = <String, String>{};
    while (true) {
      _skipSpaces();
      if (atEnd) throw FormatException('unterminated tag <$name');
      if (text[pos] == '>') {
        pos++;
        return (name, attributes, false, isEndTag);
      }
      if (text.startsWith('/>', pos)) {
        pos += 2;
        return (name, attributes, true, isEndTag);
      }
      final attrName = _readName();
      _skipSpaces();
      if (atEnd || text[pos] != '=') {
        throw FormatException('attribute $attrName in <$name> has no value');
      }
      pos++;
      _skipSpaces();
      if (atEnd || (text[pos] != '"' && text[pos] != "'")) {
        throw FormatException(
            'attribute $attrName in <$name> has an unquoted value');
      }
      final quote = text[pos];
      pos++;
      final end = text.indexOf(quote, pos);
      if (end == -1) {
        throw FormatException(
            'attribute $attrName in <$name> has an unterminated value');
      }
      if (attributes.containsKey(attrName)) {
        throw FormatException('duplicate attribute $attrName in <$name>');
      }
      attributes[attrName] = text.substring(pos, end);
      pos = end + 1;
    }
  }

  void _skipSpaces() {
    while (!atEnd &&
        (text[pos] == ' ' ||
            text[pos] == '\t' ||
            text[pos] == '\r' ||
            text[pos] == '\n')) {
      pos++;
    }
  }

  String _readName() {
    final start = pos;
    while (!atEnd && RegExp(r'[A-Za-z0-9_.:-]').hasMatch(text[pos])) {
      pos++;
    }
    if (pos == start) {
      throw FormatException('malformed tag at offset $start');
    }
    return text.substring(start, pos);
  }
}

/// Parses the overlay under the strict contract documented at the top of
/// this file. Throws [FormatException] on any construct outside it.
List<OverlayPermission> parseOverlayPermissions(
    String overlayXml, String overlayPath) {
  final scanner = _Scanner(overlayXml);

  Never rejectAt(String detail) => _reject(overlayPath, detail);

  void checkNoPlaceholder(String value, String context) {
    if (value.contains(r'${')) {
      rejectAt('$context contains a Gradle placeholder token "$value"; '
          'placeholders are not substituted by rules_flutter.');
    }
  }

  scanner.skipInsignificant();
  if (scanner.atEnd) rejectAt('the overlay has no root element.');
  final (rootName, rootAttrs, rootSelfClosing, rootIsEnd) = scanner.readTag();
  if (rootIsEnd || rootName != 'manifest') {
    rejectAt('the root element must be <manifest>, found <$rootName>.');
  }
  for (final entry in rootAttrs.entries) {
    if (entry.key != 'xmlns' && !entry.key.startsWith('xmlns:')) {
      rejectAt('the <manifest> root carries attribute "${entry.key}"; only '
          'xmlns:* namespace declarations are supported.');
    }
    checkNoPlaceholder(entry.value, 'the "${entry.key}" attribute');
  }

  final permissions = <OverlayPermission>[];
  if (rootSelfClosing) {
    _requireOnlyTrailingInsignificant(scanner, rejectAt);
    return permissions;
  }

  while (true) {
    scanner.skipInsignificant();
    if (scanner.atEnd) {
      rejectAt('the overlay is missing its </manifest> close tag.');
    }
    if (scanner.text[scanner.pos] != '<') {
      final text = scanner.text.substring(scanner.pos).trim();
      final excerpt = text.length > 40 ? '${text.substring(0, 40)}…' : text;
      rejectAt('unexpected text content "$excerpt"; only <uses-permission> '
          'elements, comments, and whitespace are supported.');
    }
    final (name, attrs, selfClosing, isEnd) = scanner.readTag();
    if (isEnd) {
      if (name != 'manifest') {
        rejectAt('unexpected close tag </$name>.');
      }
      _requireOnlyTrailingInsignificant(scanner, rejectAt);
      return permissions;
    }
    if (!_permissionElements.contains(name)) {
      rejectAt('element <$name> is not supported; only <uses-permission> '
          'and <uses-permission-sdk-23> may appear.');
    }
    if (attrs.length != 1 || !attrs.containsKey('android:name')) {
      final extras = attrs.keys.where((k) => k != 'android:name');
      if (extras.isNotEmpty) {
        rejectAt('<$name> carries attribute "${extras.first}"; exactly one '
            'android:name attribute is supported.');
      }
      rejectAt('<$name> is missing its android:name attribute.');
    }
    final value = attrs['android:name']!;
    checkNoPlaceholder(value, 'the android:name attribute');
    if (value.isEmpty) {
      rejectAt('<$name> has an empty android:name attribute.');
    }
    permissions.add(OverlayPermission(name, value));
    if (!selfClosing) {
      // Allow only an immediately-following matching close tag (with
      // insignificant content between) — permission elements have no body.
      scanner.skipInsignificant();
      final (closeName, closeAttrs, _, closeIsEnd) = scanner.readTag();
      if (!closeIsEnd || closeName != name || closeAttrs.isNotEmpty) {
        rejectAt('<$name> must be empty; found nested content.');
      }
    }
  }
}

void _requireOnlyTrailingInsignificant(
    _Scanner scanner, Never Function(String) rejectAt) {
  scanner.skipInsignificant();
  if (!scanner.atEnd) {
    rejectAt('unexpected content after </manifest>.');
  }
}

/// Locates the root `<manifest ...>` open tag in [baseXml] and returns the
/// offset just past its `>`. Throws [FormatException] when the base has no
/// non-self-closing `<manifest>` root to insert into.
int _baseInsertionPoint(String baseXml, String basePath) {
  final scanner = _Scanner(baseXml);
  scanner.skipInsignificant();
  if (scanner.atEnd) {
    throw FormatException('base manifest $basePath is empty.');
  }
  final (name, _, selfClosing, isEnd) = scanner.readTag();
  if (isEnd || name != 'manifest') {
    throw FormatException(
        'base manifest $basePath has root element <$name>, not <manifest>.');
  }
  if (selfClosing) {
    throw FormatException(
        'base manifest $basePath has a self-closing <manifest/> root; '
        'there is no element body to merge permissions into.');
  }
  return scanner.pos;
}

/// The `android:name` values of every `<uses-permission>` /
/// `<uses-permission-sdk-23>` the base already declares. Comments are
/// excluded; the rest of the base is scanned leniently (we only need names,
/// never a full parse).
Set<String> _basePermissionNames(String baseXml) {
  final withoutComments =
      baseXml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  final names = <String>{};
  final tag = RegExp(r'<uses-permission(?:-sdk-23)?[\s/>]([^>]*)>?');
  final nameAttr = RegExp('android:name\\s*=\\s*["\']([^"\']*)["\']');
  for (final match in tag.allMatches(withoutComments)) {
    final attrText = match.group(1) ?? '';
    final name = nameAttr.firstMatch(attrText)?.group(1);
    if (name != null) names.add(name);
  }
  return names;
}

/// Merges [overlayXml]'s permissions into [baseXml], returning the merged
/// manifest text. Throws [FormatException] when the overlay violates the
/// strict contract or the base has no `<manifest>` root.
String mergeManifests({
  required String baseXml,
  required String overlayXml,
  required String basePath,
  required String overlayPath,
}) {
  final overlayPermissions = parseOverlayPermissions(overlayXml, overlayPath);
  final insertAt = _baseInsertionPoint(baseXml, basePath);
  final existing = _basePermissionNames(baseXml);

  final seen = <String>{};
  final inserted = StringBuffer()
    ..write('\n    <!-- Debug variant permissions merged by rules_flutter '
        'from $overlayPath into $basePath. -->');
  for (final permission in overlayPermissions) {
    if (existing.contains(permission.name)) continue;
    if (!seen.add(permission.name)) continue;
    inserted.write(
        '\n    <${permission.element} android:name="${permission.name}"/>');
  }

  return baseXml.substring(0, insertAt) +
      inserted.toString() +
      baseXml.substring(insertAt);
}

void main(List<String> args) {
  String? basePath;
  String? overlayPath;
  String? outputPath;

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--base' && i + 1 < args.length) {
      basePath = args[++i];
    } else if (args[i] == '--overlay' && i + 1 < args.length) {
      overlayPath = args[++i];
    } else if (args[i] == '--output' && i + 1 < args.length) {
      outputPath = args[++i];
    }
  }

  if (basePath == null || overlayPath == null || outputPath == null) {
    stderr.writeln('Usage: dart merge_android_manifests.dart '
        '--base <path> --overlay <path> --output <path>');
    exit(1);
  }

  final String merged;
  try {
    merged = mergeManifests(
      baseXml: File(basePath).readAsStringSync(),
      overlayXml: File(overlayPath).readAsStringSync(),
      basePath: basePath,
      overlayPath: overlayPath,
    );
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  File(outputPath).writeAsStringSync(merged);
}
