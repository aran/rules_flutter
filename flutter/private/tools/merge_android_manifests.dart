/// Merges permissions into a main (base) AndroidManifest.xml: an overlay's,
/// and those of the app's Android libraries. Three callers, one mechanism:
///
///   * `flutter_android_app`'s debug and profile variant handling, folding
///     `android/app/src/{debug,profile}/AndroidManifest.xml` into `-c dbg`
///     and profile APKs the way Gradle's manifest merger does;
///   * `flutter_android_app(permissions = [...])`, folding the app's own
///     permissions in for **every** compilation mode — the seam a networked
///     app needs, since the debug variant's INTERNET is the Dart VM
///     service's and never reaches release;
///   * library permissions (`--library`, repeatable): a plugin or AAR that
///     declares `<uses-permission>` in its own manifest. Gradle merges those
///     into the app; Bazel's merger drops them unless
///     `--merge_android_manifest_permissions` is set, so an app that forgot
///     the flag shipped without them. Lifting them here makes the flag moot.
///
/// This tool implements deliberately narrow, never-wrong semantics: the
/// overlay may contain ONLY `<uses-permission>` / `<uses-permission-sdk-23>`
/// elements carrying `android:name` and optional `tools:*` merge directives
/// (`tools:node="remove"|"removeAll"|"replace"|"merge"`, `tools:remove`,
/// `tools:replace`, `tools:ignore`, `tools:targetApi`; `tools:node="removeAll"`
/// may omit `android:name`, and `replace` / `tools:replace` may carry
/// replacement `android:*` attributes), plus comments and whitespace.
/// Anything else — other elements, unsupported attributes, text content,
/// `${...}` Gradle placeholders, or an unparsable `android:maxSdkVersion` —
/// is a hard error naming the offending construct, so an overlay this tool
/// cannot faithfully merge can never be silently mis-merged. Users with
/// richer variant manifests pass `debug_manifest` on `flutter_android_app`
/// explicitly (or restructure).
///
/// Following AGP's two-stage merge model:
///   * Overlay merges (`--overlay` without `--library`) produce an
///     intermediate app-level manifest that will be merged further, so
///     `tools:*` marker elements and attributes in the base and overlay
///     survive in the output regardless of chain length.
///   * Library merges (`--library`, or a final merge with no `--overlay`)
///     apply the app's `tools:*` directives to lower-priority library
///     permissions and strip all `tools:*` marker elements and attributes so
///     the packaged manifest carries none.
///
/// Priority matches AGP:
///   * App declarations (`--base` and `--overlay`) have higher priority than
///     libraries (`--library`). An app permission's `android:maxSdkVersion`
///     is never widened and its attributes (e.g. `android:usesPermissionFlags`)
///     are never dropped by a library's unbounded duplicate.
///   * A library's `tools:node="remove"` or `"removeAll"` applies only to
///     lower-priority libraries in AGP's order (later `--library` inputs),
///     never to the app or to higher-priority libraries.
///   * `<uses-permission>` and `<uses-permission-sdk-23>` directives match
///     only their own element kind.
///
/// A library manifest is read leniently, since it is a whole manifest: only
/// the `<uses-permission>` / `<uses-permission-sdk-23>` elements directly
/// under its root are taken. Their `android:*` attributes (`maxSdkVersion`,
/// `usesPermissionFlags`) are kept; `tools:*` attributes are dropped; an
/// element marked `tools:node="remove"` or `"removeAll"` is a removal
/// directive that applies only to lower-priority libraries, never to the app
/// or higher-priority libraries. A `\${name}` placeholder passes through
/// verbatim when `name` is one the app's build substitutes afterwards
/// (`--placeholder`, e.g. androidx.core's `\${applicationId}.…` permission);
/// any other is a hard error.
///
/// The base manifest is never re-serialized: merged permissions are inserted
/// textually right after the root `<manifest ...>` open tag, and only base
/// permission spans that are removed or modified by a merge directive (or
/// stripped of `tools:*` attributes in the final library merge) are edited,
/// so every other base byte passes through untouched.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart merge_android_manifests.dart --base <path> [--overlay <path>]
///       [--library <path>]... [--placeholder <name>]... --output <path>
import 'dart:io';

/// Pointer at the Tier-1 escape hatch, appended to every rejection.
const _escapeHatch =
    'If the overlay needs constructs this merger does not '
    'support, pass an explicit merged manifest via the `debug_manifest` '
    'attribute of `flutter_android_app` instead.';

/// The overlay element names whose permissions we merge.
const _permissionElements = {'uses-permission', 'uses-permission-sdk-23'};

/// Supported values of `tools:node` on permission elements.
const _supportedToolsNodes = {
  'remove',
  'removeAll',
  'replace',
  'merge',
  'merge-only-attributes',
};

/// Supported `tools:*` attributes on overlay permission elements.
const _supportedOverlayToolsAttrs = {
  'tools:node',
  'tools:remove',
  'tools:replace',
  'tools:ignore',
  'tools:targetApi',
};

Set<String> _parseAttrList(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const {};
  final result = <String>{};
  for (final part in raw.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    result.add(trimmed.contains(':') ? trimmed : 'android:$trimmed');
  }
  return result;
}

int? _parseMaxSdkVersion(
  Map<String, String> attrs, {
  required String element,
  required String? permissionName,
  required String manifestPath,
}) {
  if (!attrs.containsKey('android:maxSdkVersion')) return null;
  final raw = attrs['android:maxSdkVersion']!;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 1) {
    final target = permissionName == null || permissionName.isEmpty
        ? '<$element>'
        : '<$element android:name="$permissionName">';
    throw FormatException(
      'Invalid android:maxSdkVersion "$raw" on $target in $manifestPath: '
      'expected a positive integer.',
    );
  }
  return parsed;
}

/// A permission declaration or `tools:*` directive parsed from the overlay.
class OverlayPermission {
  /// `uses-permission` or `uses-permission-sdk-23`.
  final String element;

  /// The `android:name` value, e.g. `android.permission.INTERNET`.
  /// Empty only when [isRemoveAll] is true and `android:name` was omitted.
  final String name;

  /// All attributes on the overlay element in source order.
  final Map<String, String> attributes;

  OverlayPermission(
    this.element,
    this.name, {
    Map<String, String>? attributes,
    bool isRemove = false,
  }) : attributes =
           attributes ??
           <String, String>{
             if (name.isNotEmpty) 'android:name': name,
             if (isRemove) 'tools:node': 'remove',
           };

  String? get toolsNode => attributes['tools:node'];

  /// Whether this element carries `tools:node="remove"`.
  bool get isRemove => toolsNode == 'remove';

  /// Whether this element carries `tools:node="removeAll"`.
  bool get isRemoveAll => toolsNode == 'removeAll';

  /// Whether this element carries `tools:node="replace"`.
  bool get isReplace => toolsNode == 'replace';

  /// Whether this element carries `tools:node="merge"`.
  bool get isMerge =>
      toolsNode == 'merge' || toolsNode == 'merge-only-attributes';

  /// Normalized attribute names listed in `tools:remove`.
  Set<String> get toolsRemove => _parseAttrList(attributes['tools:remove']);

  /// Normalized attribute names listed in `tools:replace`.
  Set<String> get toolsReplace => _parseAttrList(attributes['tools:replace']);

  /// Whether this element carries any `tools:*` attributes.
  bool get hasToolsAttributes =>
      attributes.keys.any((k) => k.startsWith('tools:'));
}

Never _reject(String overlayPath, String detail) {
  throw FormatException(
    'Cannot merge debug variant manifest $overlayPath: $detail\n'
    '$_escapeHatch',
  );
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

  /// Consumes whitespace, UTF-8 BOM, comments, and XML processing instructions.
  void skipInsignificant() {
    while (!atEnd) {
      final c = text[pos];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\uFEFF') {
        pos++;
      } else if (text.startsWith('<!--', pos)) {
        final end = text.indexOf('-->', pos + 4);
        if (end == -1) {
          throw const FormatException('unterminated comment');
        }
        pos = end + 3;
      } else if (text.startsWith('<?', pos)) {
        final end = text.indexOf('?>', pos + 2);
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
          'attribute $attrName in <$name> has an unquoted value',
        );
      }
      final quote = text[pos];
      pos++;
      final end = text.indexOf(quote, pos);
      if (end == -1) {
        throw FormatException(
          'attribute $attrName in <$name> has an unterminated value',
        );
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
  String overlayXml,
  String overlayPath,
) {
  final scanner = _Scanner(overlayXml);

  Never rejectAt(String detail) => _reject(overlayPath, detail);

  void checkNoPlaceholder(String value, String context) {
    if (value.contains(r'${')) {
      rejectAt(
        '$context contains a Gradle placeholder token "$value"; '
        'placeholders are not substituted by rules_flutter.',
      );
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
      rejectAt(
        'the <manifest> root carries attribute "${entry.key}"; only '
        'xmlns:* namespace declarations are supported.',
      );
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
      rejectAt(
        'unexpected text content "$excerpt"; only <uses-permission> '
        'elements, comments, and whitespace are supported.',
      );
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
      rejectAt(
        'element <$name> is not supported; only <uses-permission> '
        'and <uses-permission-sdk-23> may appear.',
      );
    }
    final toolsNode = attrs['tools:node'];
    if (toolsNode != null && !_supportedToolsNodes.contains(toolsNode)) {
      rejectAt(
        '<$name> carries unsupported tools:node="$toolsNode"; '
        'expected remove, removeAll, replace, or merge.',
      );
    }
    final isRemoveAll = toolsNode == 'removeAll';
    if (!isRemoveAll && !attrs.containsKey('android:name')) {
      rejectAt('<$name> is missing its android:name attribute.');
    }
    final allowsReplacementAndroidAttrs =
        toolsNode == 'replace' ||
        toolsNode == 'merge' ||
        toolsNode == 'merge-only-attributes' ||
        attrs.containsKey('tools:replace') ||
        attrs.containsKey('tools:remove');
    for (final entry in attrs.entries) {
      final key = entry.key;
      final val = entry.value;
      checkNoPlaceholder(val, 'the $key attribute');
      if (key == 'android:name') continue;
      if (_supportedOverlayToolsAttrs.contains(key)) {
        if ((key == 'tools:remove' || key == 'tools:replace') &&
            _parseAttrList(val).isEmpty) {
          rejectAt('<$name> has an empty $key attribute.');
        }
        continue;
      }
      if (key == 'android:maxSdkVersion') {
        final parsed = int.tryParse(val);
        if (parsed == null || parsed < 1) {
          rejectAt(
            '<$name> has invalid android:maxSdkVersion "$val": '
            'expected a positive integer.',
          );
        }
        if (allowsReplacementAndroidAttrs) continue;
      } else if (key.startsWith('android:') && allowsReplacementAndroidAttrs) {
        continue;
      }
      rejectAt(
        '<$name> carries attribute "$key"; '
        'only android:name and tools:* markers are supported.',
      );
    }
    final value = attrs['android:name'] ?? '';
    if (!isRemoveAll && value.isEmpty) {
      rejectAt('<$name> has an empty android:name attribute.');
    }
    permissions.add(
      OverlayPermission(name, value, attributes: Map.unmodifiable(attrs)),
    );
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
  _Scanner scanner,
  Never Function(String) rejectAt,
) {
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
      'base manifest $basePath has root element <$name>, not <manifest>.',
    );
  }
  if (selfClosing) {
    throw FormatException(
      'base manifest $basePath has a self-closing <manifest/> root; '
      'there is no element body to merge permissions into.',
    );
  }
  return scanner.pos;
}

class _BasePermission {
  final String element;
  final String name;
  final Map<String, String> attributes;
  final int? maxSdkVersion;
  final String? toolsNode;
  final int tagStart;
  final int tagEnd;
  final int spanStart;
  final int spanEnd;

  _BasePermission({
    required this.element,
    required this.name,
    required this.attributes,
    required this.maxSdkVersion,
    required this.toolsNode,
    required this.tagStart,
    required this.tagEnd,
    required this.spanStart,
    required this.spanEnd,
  });

  bool get isRemove => toolsNode == 'remove';
  bool get isRemoveAll => toolsNode == 'removeAll';
}

/// Scans root-level `<uses-permission>` and `<uses-permission-sdk-23>`
/// declarations in [baseXml] starting at [insertAt] (just after the root
/// `<manifest ...>` open tag).
List<_BasePermission> _scanBasePermissions(
  String baseXml,
  int insertAt,
  String basePath,
) {
  final scanner = _Scanner(baseXml)..pos = insertAt;
  final permissions = <_BasePermission>[];
  var depth = 1;
  while (depth > 0) {
    scanner.skipInsignificant();
    if (scanner.atEnd) break;
    final text = scanner.text;
    if (text[scanner.pos] != '<') {
      final next = text.indexOf('<', scanner.pos);
      scanner.pos = next == -1 ? text.length : next;
      continue;
    }
    if (text.startsWith('<![CDATA[', scanner.pos)) {
      final end = text.indexOf(']]>', scanner.pos);
      scanner.pos = end == -1 ? text.length : end + 3;
      continue;
    }
    if (text.startsWith('<?', scanner.pos) ||
        text.startsWith('<!', scanner.pos)) {
      final end = text.indexOf('>', scanner.pos);
      scanner.pos = end == -1 ? text.length : end + 1;
      continue;
    }
    final tagStart = scanner.pos;
    final (name, attrs, selfClosing, isEnd) = scanner.readTag();
    if (isEnd) {
      depth--;
      continue;
    }
    if (depth == 1 && _permissionElements.contains(name)) {
      var tagEnd = scanner.pos;
      if (!selfClosing) {
        final afterOpen = scanner.pos;
        scanner.skipInsignificant();
        if (!scanner.atEnd &&
            text[scanner.pos] == '<' &&
            !text.startsWith('<!', scanner.pos) &&
            !text.startsWith('<?', scanner.pos)) {
          final (closeName, _, _, closeIsEnd) = scanner.readTag();
          if (closeIsEnd && closeName == name) {
            tagEnd = scanner.pos;
          } else {
            scanner.pos = afterOpen;
            depth++;
          }
        } else {
          scanner.pos = afterOpen;
          depth++;
        }
      }
      var lineStart = tagStart;
      while (lineStart > insertAt &&
          (text[lineStart - 1] == ' ' || text[lineStart - 1] == '\t')) {
        lineStart--;
      }
      final atLineStart = lineStart > 0 && text[lineStart - 1] == '\n';
      var lineEnd = tagEnd;
      if (lineEnd < text.length && text[lineEnd] == '\r') lineEnd++;
      final hasTrailingNewline = lineEnd < text.length && text[lineEnd] == '\n';
      if (hasTrailingNewline) lineEnd++;
      final spanStart = (atLineStart && hasTrailingNewline)
          ? lineStart
          : tagStart;
      final spanEnd = (atLineStart && hasTrailingNewline) ? lineEnd : tagEnd;

      final toolsNode = attrs['tools:node'];
      if (toolsNode != null && !_supportedToolsNodes.contains(toolsNode)) {
        throw FormatException(
          'Unsupported tools:node="$toolsNode" on <$name> in $basePath.',
        );
      }
      final isRemoveAll = toolsNode == 'removeAll';
      final permName = attrs['android:name'] ?? '';
      final maxSdkVersion = _parseMaxSdkVersion(
        attrs,
        element: name,
        permissionName: permName,
        manifestPath: basePath,
      );
      if (isRemoveAll || permName.isNotEmpty) {
        permissions.add(
          _BasePermission(
            element: name,
            name: permName,
            attributes: attrs,
            maxSdkVersion: maxSdkVersion,
            toolsNode: toolsNode,
            tagStart: tagStart,
            tagEnd: tagEnd,
            spanStart: spanStart,
            spanEnd: spanEnd,
          ),
        );
      }
    } else if (!selfClosing) {
      depth++;
    }
  }
  return permissions;
}

/// A `<uses-permission>` taken from a library manifest, with the `android:*`
/// attributes it is emitted with.
class LibraryPermission {
  /// `uses-permission` or `uses-permission-sdk-23`.
  final String element;

  /// The `android:*` attributes, `android:name` among them, in source order.
  final Map<String, String> attributes;

  /// Whether this element carries `tools:node="remove"`.
  final bool isRemove;

  /// Whether this element carries `tools:node="removeAll"`.
  final bool isRemoveAll;

  final String? toolsNode;
  final Set<String> toolsRemove;
  final Set<String> toolsReplace;

  LibraryPermission(
    this.element,
    this.attributes, {
    this.isRemove = false,
    this.isRemoveAll = false,
    this.toolsNode,
    this.toolsRemove = const {},
    this.toolsReplace = const {},
  });

  String get name => attributes['android:name'] ?? '';

  int? get maxSdkVersion {
    final value = attributes['android:maxSdkVersion'];
    return value == null ? null : int.parse(value);
  }

  LibraryPermission withElement(String newElement) => newElement == element
      ? this
      : LibraryPermission(
          newElement,
          attributes,
          isRemove: isRemove,
          isRemoveAll: isRemoveAll,
          toolsNode: toolsNode,
          toolsRemove: toolsRemove,
          toolsReplace: toolsReplace,
        );

  String render() {
    final attrs = attributes.entries
        .map((e) => ' ${e.key}="${e.value}"')
        .join();
    return '<$element$attrs/>';
  }
}

/// The permissions [libraryXml] declares directly under its `<manifest>`
/// root, read as documented at the top of this file.
List<LibraryPermission> parseLibraryPermissions(
  String libraryXml,
  String libraryPath, {
  Set<String> placeholders = const {},
}) {
  Never reject(String detail) => throw FormatException(
    'Cannot read the permissions of library manifest $libraryPath: $detail',
  );

  final scanner = _Scanner(libraryXml);
  final permissions = <LibraryPermission>[];
  var depth = 0;
  while (true) {
    scanner.skipInsignificant();
    if (scanner.atEnd) break;
    final text = scanner.text;
    if (text[scanner.pos] != '<') {
      final next = text.indexOf('<', scanner.pos);
      scanner.pos = next == -1 ? text.length : next;
      continue;
    }
    if (text.startsWith('<![CDATA[', scanner.pos)) {
      final end = text.indexOf(']]>', scanner.pos);
      if (end == -1) reject('unterminated CDATA section.');
      scanner.pos = end + 3;
      continue;
    }
    if (text.startsWith('<?', scanner.pos) ||
        text.startsWith('<!', scanner.pos)) {
      final end = text.indexOf('>', scanner.pos);
      if (end == -1) reject('unterminated markup at offset ${scanner.pos}.');
      scanner.pos = end + 1;
      continue;
    }
    final (name, attrs, selfClosing, isEnd) = scanner.readTag();
    if (isEnd) {
      depth--;
      continue;
    }
    if (depth == 1 && _permissionElements.contains(name)) {
      for (final e in attrs.entries) {
        if (!e.key.startsWith('android:') && !e.key.startsWith('tools:')) {
          reject(
            '<$name> carries attribute "${e.key}", which is neither '
            'android:* nor tools:*.',
          );
        }
      }
      final toolsNode = attrs['tools:node'];
      if (toolsNode != null && !_supportedToolsNodes.contains(toolsNode)) {
        reject('<$name> carries unsupported tools:node="$toolsNode".');
      }
      if (attrs.containsKey('android:maxSdkVersion')) {
        final rawMaxSdk = attrs['android:maxSdkVersion']!;
        final parsedMaxSdk = int.tryParse(rawMaxSdk);
        if (parsedMaxSdk == null || parsedMaxSdk < 1) {
          final permName = attrs['android:name'] ?? '';
          final label = permName.isEmpty
              ? '<$name>'
              : '<$name android:name="$permName">';
          reject(
            '$label has invalid android:maxSdkVersion "$rawMaxSdk": '
            'expected a positive integer.',
          );
        }
      }
      if (toolsNode == 'removeAll') {
        permissions.add(
          LibraryPermission(
            name,
            {'android:name': attrs['android:name'] ?? ''},
            isRemoveAll: true,
          ),
        );
      } else if (toolsNode == 'remove') {
        final permissionName = attrs['android:name'];
        if (permissionName == null || permissionName.isEmpty) {
          reject('<$name> has no android:name attribute.');
        }
        permissions.add(
          LibraryPermission(
            name,
            {'android:name': permissionName},
            isRemove: true,
          ),
        );
      } else {
        final selfRemoved = _parseAttrList(attrs['tools:remove']);
        final selfReplaced = _parseAttrList(attrs['tools:replace']);
        final kept = <String, String>{
          for (final e in attrs.entries)
            if (e.key.startsWith('android:') && !selfRemoved.contains(e.key))
              e.key: e.value,
        };
        final permissionName = kept['android:name'];
        if (permissionName == null || permissionName.isEmpty) {
          reject('<$name> has no android:name attribute.');
        }
        for (final value in kept.values) {
          for (final match in RegExp(r'\$\{([^}]*)\}').allMatches(value)) {
            if (!placeholders.contains(match[1])) {
              reject(
                '<$name android:name="$permissionName"> contains the Gradle '
                'placeholder "\${${match[1]}}", which this build does not '
                'substitute (it substitutes: ${placeholders.join(', ')}).',
              );
            }
          }
        }
        permissions.add(
          LibraryPermission(
            name,
            kept,
            toolsNode: toolsNode == 'merge-only-attributes'
                ? 'merge'
                : toolsNode,
            toolsRemove: selfRemoved,
            toolsReplace: selfReplaced,
          ),
        );
      }
    }
    if (!selfClosing) depth++;
  }
  return permissions;
}

bool _isNarrowerMaxSdk(int? existingMaxSdk, int? incomingMaxSdk) {
  if (existingMaxSdk == null) return false;
  if (incomingMaxSdk == null) return true;
  return existingMaxSdk < incomingMaxSdk;
}

LibraryPermission _mergeLibraryPermissions(
  LibraryPermission earlier,
  LibraryPermission incoming,
) {
  if (earlier.toolsNode == 'replace') {
    return earlier;
  }
  final widenMaxSdk =
      !earlier.toolsReplace.contains('android:maxSdkVersion') &&
      !earlier.toolsRemove.contains('android:maxSdkVersion') &&
      _isNarrowerMaxSdk(earlier.maxSdkVersion, incoming.maxSdkVersion);
  final mergedAttrs = <String, String>{};
  for (final e in earlier.attributes.entries) {
    if (e.key == 'android:maxSdkVersion' && widenMaxSdk) {
      if (incoming.attributes.containsKey('android:maxSdkVersion')) {
        mergedAttrs['android:maxSdkVersion'] =
            incoming.attributes['android:maxSdkVersion']!;
      }
      continue;
    }
    mergedAttrs[e.key] = e.value;
  }
  for (final e in incoming.attributes.entries) {
    if (e.key == 'android:maxSdkVersion') continue;
    if (earlier.toolsRemove.contains(e.key) ||
        earlier.toolsReplace.contains(e.key)) {
      continue;
    }
    mergedAttrs.putIfAbsent(e.key, () => e.value);
  }
  return LibraryPermission(
    earlier.element,
    mergedAttrs,
    toolsNode: earlier.toolsNode,
    toolsRemove: earlier.toolsRemove,
    toolsReplace: earlier.toolsReplace,
  );
}

class _SpanEdit {
  final int start;
  final int end;
  final String replacement;

  const _SpanEdit(this.start, this.end, this.replacement);
}

String _applyEdits(String text, List<_SpanEdit> edits) {
  if (edits.isEmpty) return text;
  final sorted = [...edits]..sort((a, b) => a.start.compareTo(b.start));
  final buffer = StringBuffer();
  var cursor = 0;
  for (final edit in sorted) {
    if (edit.start < cursor) continue;
    if (edit.start > cursor) {
      buffer.write(text.substring(cursor, edit.start));
    }
    buffer.write(edit.replacement);
    cursor = edit.end;
  }
  if (cursor < text.length) {
    buffer.write(text.substring(cursor));
  }
  return buffer.toString();
}

/// Active permission in the app tier (either in `base` or added by `overlay`).
class _AppPermission {
  final String element;
  final String name;
  final Map<String, String> androidAttributes;
  String? toolsNode; // null, 'replace', or 'merge'
  final Set<String> toolsRemove;
  final Set<String> toolsReplace;
  final Map<String, String> otherToolsAttributes;

  final int? tagStart;
  final int? tagEnd;
  final int? spanStart;
  final int? spanEnd;
  final bool hadInitialToolsAttributes;
  bool modified = false;

  _AppPermission._({
    required this.element,
    required this.name,
    required this.androidAttributes,
    required this.toolsNode,
    required this.toolsRemove,
    required this.toolsReplace,
    required this.otherToolsAttributes,
    required this.hadInitialToolsAttributes,
    this.tagStart,
    this.tagEnd,
    this.spanStart,
    this.spanEnd,
    this.modified = false,
  });

  factory _AppPermission.fromBase(_BasePermission bp) {
    final removed = <String>{..._parseAttrList(bp.attributes['tools:remove'])};
    final replaced = <String>{
      ..._parseAttrList(bp.attributes['tools:replace']),
    };
    final rawNode = bp.toolsNode;
    final normalizedNode = rawNode == 'merge-only-attributes'
        ? 'merge'
        : rawNode;
    final androidAttrs = <String, String>{};
    var selfStripped = false;
    for (final e in bp.attributes.entries) {
      if (e.key.startsWith('android:')) {
        if (e.key != 'android:name' && removed.contains(e.key)) {
          selfStripped = true;
        } else {
          androidAttrs[e.key] = e.value;
        }
      }
    }
    final otherTools = <String, String>{};
    for (final e in bp.attributes.entries) {
      if (e.key.startsWith('tools:') &&
          e.key != 'tools:node' &&
          e.key != 'tools:remove' &&
          e.key != 'tools:replace') {
        otherTools[e.key] = e.value;
      }
    }
    return _AppPermission._(
      element: bp.element,
      name: bp.name,
      androidAttributes: androidAttrs,
      toolsNode: normalizedNode,
      toolsRemove: removed,
      toolsReplace: replaced,
      otherToolsAttributes: otherTools,
      hadInitialToolsAttributes: bp.attributes.keys.any(
        (k) => k.startsWith('tools:'),
      ),
      tagStart: bp.tagStart,
      tagEnd: bp.tagEnd,
      spanStart: bp.spanStart,
      spanEnd: bp.spanEnd,
      modified: selfStripped,
    );
  }

  factory _AppPermission.fromOverlay(OverlayPermission op) {
    final removed = <String>{...op.toolsRemove};
    final replaced = <String>{...op.toolsReplace};
    final rawNode = op.toolsNode;
    final normalizedNode = rawNode == 'merge-only-attributes'
        ? 'merge'
        : rawNode;
    final androidAttrs = <String, String>{'android:name': op.name};
    for (final e in op.attributes.entries) {
      if (e.key != 'android:name' &&
          e.key.startsWith('android:') &&
          !removed.contains(e.key)) {
        androidAttrs[e.key] = e.value;
      }
    }
    final otherTools = <String, String>{};
    for (final e in op.attributes.entries) {
      if (e.key.startsWith('tools:') &&
          e.key != 'tools:node' &&
          e.key != 'tools:remove' &&
          e.key != 'tools:replace') {
        otherTools[e.key] = e.value;
      }
    }
    return _AppPermission._(
      element: op.element,
      name: op.name,
      androidAttributes: androidAttrs,
      toolsNode: normalizedNode,
      toolsRemove: removed,
      toolsReplace: replaced,
      otherToolsAttributes: otherTools,
      hadInitialToolsAttributes: op.hasToolsAttributes,
    );
  }

  void mergeOverlay(OverlayPermission op) {
    final opRemove = op.toolsRemove;
    final opReplace = op.toolsReplace;
    final opNode = op.toolsNode == 'merge-only-attributes'
        ? 'merge'
        : op.toolsNode;

    if (opNode == 'replace') {
      androidAttributes
        ..clear()
        ..['android:name'] = name;
      for (final e in op.attributes.entries) {
        if (e.key != 'android:name' &&
            e.key.startsWith('android:') &&
            !opRemove.contains(e.key)) {
          androidAttributes[e.key] = e.value;
        }
      }
      toolsNode = 'replace';
      toolsRemove
        ..clear()
        ..addAll(opRemove);
      toolsReplace
        ..clear()
        ..addAll(opReplace);
      otherToolsAttributes.clear();
      for (final e in op.attributes.entries) {
        if (e.key.startsWith('tools:') &&
            e.key != 'tools:node' &&
            e.key != 'tools:remove' &&
            e.key != 'tools:replace') {
          otherToolsAttributes[e.key] = e.value;
        }
      }
      modified = true;
      return;
    }

    for (final rem in opRemove) {
      if (rem != 'android:name' && androidAttributes.remove(rem) != null) {
        modified = true;
      }
    }
    for (final rep in opReplace) {
      if (rep != 'android:name' &&
          !op.attributes.containsKey(rep) &&
          androidAttributes.remove(rep) != null) {
        modified = true;
      }
    }
    for (final e in op.attributes.entries) {
      if (e.key == 'android:name') continue;
      if (e.key.startsWith('android:') && !opRemove.contains(e.key)) {
        if (androidAttributes[e.key] != e.value) {
          androidAttributes[e.key] = e.value;
          modified = true;
        }
        toolsRemove.remove(e.key);
      }
    }
    if (opRemove.isNotEmpty && !toolsRemove.containsAll(opRemove)) {
      toolsRemove.addAll(opRemove);
      modified = true;
    }
    if (opReplace.isNotEmpty && !toolsReplace.containsAll(opReplace)) {
      toolsReplace.addAll(opReplace);
      modified = true;
    }
    if (opNode != null && toolsNode != 'replace' && toolsNode != opNode) {
      toolsNode = opNode;
      modified = true;
    }
    for (final e in op.attributes.entries) {
      if (e.key.startsWith('tools:') &&
          e.key != 'tools:node' &&
          e.key != 'tools:remove' &&
          e.key != 'tools:replace') {
        if (otherToolsAttributes[e.key] != e.value) {
          otherToolsAttributes[e.key] = e.value;
          modified = true;
        }
      }
    }
  }

  void mergeLibrary(LibraryPermission lp) {
    if (toolsNode == 'replace') {
      return;
    }
    final isExplicitMergeDirective =
        toolsNode == 'merge' ||
        toolsRemove.isNotEmpty ||
        toolsReplace.isNotEmpty;

    for (final e in lp.attributes.entries) {
      final attrKey = e.key;
      final attrVal = e.value;
      if (attrKey == 'android:name') continue;
      if (toolsRemove.contains(attrKey)) continue;
      if (toolsReplace.contains(attrKey)) continue;
      if (androidAttributes.containsKey(attrKey)) {
        // Higher-priority app attribute (including maxSdkVersion) always wins.
        continue;
      }
      if (attrKey == 'android:maxSdkVersion') {
        if (isExplicitMergeDirective) {
          androidAttributes[attrKey] = attrVal;
          modified = true;
        }
        continue;
      }
      androidAttributes[attrKey] = attrVal;
      modified = true;
    }
  }

  String render({required bool includeTools}) {
    final outAttrs = <String, String>{...androidAttributes};
    if (includeTools) {
      if (toolsNode != null) {
        outAttrs['tools:node'] = toolsNode!;
      }
      if (toolsRemove.isNotEmpty) {
        outAttrs['tools:remove'] = toolsRemove.join(',');
      }
      if (toolsReplace.isNotEmpty) {
        outAttrs['tools:replace'] = toolsReplace.join(',');
      }
      outAttrs.addAll(otherToolsAttributes);
    }
    final rendered = outAttrs.entries
        .map((e) => ' ${e.key}="${e.value}"')
        .join();
    return '<$element$rendered/>';
  }
}

String _otherPermissionElement(String element) =>
    element == 'uses-permission' ? 'uses-permission-sdk-23' : 'uses-permission';

/// Merges [overlayXml]'s permissions and [libraries]' permissions into
/// [baseXml], returning the merged manifest text. Throws [FormatException]
/// when an input violates the contract or [baseXml] has no `<manifest>` root.
String mergeManifests({
  required String baseXml,
  required String basePath,
  String? overlayXml,
  String? overlayPath,
  Map<String, String> libraries = const {},
  Set<String> placeholders = const {},
}) {
  final isOverlayOnly = overlayXml != null && libraries.isEmpty;
  final isLibraryMerge = !isOverlayOnly;

  final overlayPermissions = overlayXml == null
      ? const <OverlayPermission>[]
      : parseOverlayPermissions(overlayXml, overlayPath!);
  final insertAt = _baseInsertionPoint(baseXml, basePath);
  final basePermissions = _scanBasePermissions(baseXml, insertAt, basePath);

  final edits = <_SpanEdit>[];
  final baseRemoveAll = <String, List<_BasePermission>>{};
  final removedByBase = <(String, String), _BasePermission>{};
  final activeBase = <(String, String), _AppPermission>{};

  for (final perm in basePermissions) {
    if (perm.isRemoveAll) {
      (baseRemoveAll[perm.element] ??= <_BasePermission>[]).add(perm);
      continue;
    }
    final key = (perm.element, perm.name);
    if (perm.isRemove) {
      final prevRemove = removedByBase[key];
      if (prevRemove != null) {
        edits.add(_SpanEdit(prevRemove.spanStart, prevRemove.spanEnd, ''));
      }
      removedByBase[key] = perm;
      final prevActive = activeBase.remove(key);
      if (prevActive != null) {
        edits.add(_SpanEdit(prevActive.spanStart!, prevActive.spanEnd!, ''));
      }
    } else if (removedByBase.containsKey(key)) {
      edits.add(_SpanEdit(perm.spanStart, perm.spanEnd, ''));
    } else {
      final existing = activeBase[key];
      if (existing != null) {
        edits.add(_SpanEdit(perm.spanStart, perm.spanEnd, ''));
      } else {
        activeBase[key] = _AppPermission.fromBase(perm);
      }
    }
  }

  void stripBaseKey((String, String) key) {
    final active = activeBase.remove(key);
    if (active != null) {
      edits.add(_SpanEdit(active.spanStart!, active.spanEnd!, ''));
    }
    final rem = removedByBase.remove(key);
    if (rem != null) {
      edits.add(_SpanEdit(rem.spanStart, rem.spanEnd, ''));
    }
  }

  void stripAllBaseForElement(String element) {
    final activeKeys = activeBase.keys
        .where((k) => k.$1 == element)
        .toList(growable: false);
    for (final k in activeKeys) {
      final p = activeBase.remove(k)!;
      edits.add(_SpanEdit(p.spanStart!, p.spanEnd!, ''));
    }
    final remKeys = removedByBase.keys
        .where((k) => k.$1 == element)
        .toList(growable: false);
    for (final k in remKeys) {
      final p = removedByBase.remove(k)!;
      edits.add(_SpanEdit(p.spanStart, p.spanEnd, ''));
    }
    final remAll = baseRemoveAll.remove(element);
    if (remAll != null) {
      for (final p in remAll) {
        edits.add(_SpanEdit(p.spanStart, p.spanEnd, ''));
      }
    }
  }

  final removedAllByOverlay = <String>{};
  final removedByOverlay = <(String, String)>{};
  final overlayAdded = <(String, String), _AppPermission>{};

  for (final op in overlayPermissions) {
    if (op.isRemoveAll) {
      stripAllBaseForElement(op.element);
      overlayAdded.removeWhere((k, _) => k.$1 == op.element);
      removedByOverlay.removeWhere((k) => k.$1 == op.element);
      removedAllByOverlay.add(op.element);
      continue;
    }
    final key = (op.element, op.name);
    if (op.isRemove) {
      stripBaseKey(key);
      overlayAdded.remove(key);
      removedByOverlay.add(key);
      continue;
    }

    // Active permission in overlay cancels any prior removal of the same key.
    removedByOverlay.remove(key);
    final baseRem = removedByBase.remove(key);
    if (baseRem != null) {
      edits.add(_SpanEdit(baseRem.spanStart, baseRem.spanEnd, ''));
    }

    final existingBase = activeBase[key];
    if (existingBase != null) {
      existingBase.mergeOverlay(op);
      continue;
    }

    // If neither base nor overlay uses tools:* directives on this permission,
    // dedup a plain positive overlay declaration against an existing base
    // declaration of the other element kind.
    final otherKey = (_otherPermissionElement(op.element), op.name);
    final otherBase = activeBase[otherKey];
    if (otherBase != null &&
        !op.hasToolsAttributes &&
        !otherBase.hadInitialToolsAttributes &&
        !removedByBase.containsKey(key) &&
        !removedByOverlay.contains(key)) {
      continue;
    }

    final earlierOverlay = overlayAdded[key];
    if (earlierOverlay != null) {
      earlierOverlay.mergeOverlay(op);
    } else {
      overlayAdded[key] = _AppPermission.fromOverlay(op);
    }
  }

  // Libraries in the order given (higher priority first). A library's
  // tools:node="remove" or "removeAll" applies only to lower-priority
  // libraries (later in `libraries`), never to higher-priority libraries
  // (already in `resolvedLibraries`) or to the app. Across libraries, a
  // broader maxSdkVersion (or unbounded) upgrades a narrower one.
  final removedAllByLibraries = <String>{};
  final removedByLibraries = <(String, String)>{};
  final resolvedLibraries = <(String, String), LibraryPermission>{};
  for (final MapEntry(key: path, value: xml) in libraries.entries) {
    for (final permission in parseLibraryPermissions(
      xml,
      path,
      placeholders: placeholders,
    )) {
      if (permission.isRemoveAll) {
        removedAllByLibraries.add(permission.element);
        continue;
      }
      final key = (permission.element, permission.name);
      if (permission.isRemove) {
        removedByLibraries.add(key);
        continue;
      }
      if (removedAllByLibraries.contains(permission.element) ||
          removedByLibraries.contains(key)) {
        continue;
      }
      final earlier = resolvedLibraries[key];
      if (earlier == null) {
        resolvedLibraries[key] = permission;
      } else {
        resolvedLibraries[key] = _mergeLibraryPermissions(earlier, permission);
      }
    }
  }

  // Apply app-tier priority over the resolved library permissions.
  final fromLibraries = <(String, String), LibraryPermission>{};
  for (final MapEntry(key: key, value: permission)
      in resolvedLibraries.entries) {
    if (removedAllByOverlay.contains(permission.element) ||
        baseRemoveAll.containsKey(permission.element) ||
        removedByOverlay.contains(key) ||
        removedByBase.containsKey(key)) {
      continue;
    }
    final basePerm = activeBase[key];
    if (basePerm != null) {
      basePerm.mergeLibrary(permission);
      continue;
    }
    final overlayPerm = overlayAdded[key];
    if (overlayPerm != null) {
      overlayPerm.mergeLibrary(permission);
      continue;
    }
    fromLibraries[key] = permission;
  }

  if (isLibraryMerge) {
    for (final remList in baseRemoveAll.values) {
      for (final p in remList) {
        edits.add(_SpanEdit(p.spanStart, p.spanEnd, ''));
      }
    }
    for (final p in removedByBase.values) {
      edits.add(_SpanEdit(p.spanStart, p.spanEnd, ''));
    }
    for (final p in activeBase.values) {
      if (p.modified || p.hadInitialToolsAttributes) {
        edits.add(
          _SpanEdit(p.tagStart!, p.tagEnd!, p.render(includeTools: false)),
        );
      }
    }
  } else {
    for (final p in activeBase.values) {
      if (p.modified) {
        edits.add(
          _SpanEdit(p.tagStart!, p.tagEnd!, p.render(includeTools: true)),
        );
      }
    }
  }

  final lines = <String>[
    if (isOverlayOnly) ...[
      for (final elem in removedAllByOverlay) '<$elem tools:node="removeAll"/>',
      for (final (elem, name) in removedByOverlay)
        '<$elem android:name="$name" tools:node="remove"/>',
    ],
    for (final permission in overlayAdded.values)
      permission.render(includeTools: isOverlayOnly),
    for (final permission in fromLibraries.values) permission.render(),
  ];

  final editedBaseXml = _applyEdits(baseXml, edits);
  // An overlay always leaves its provenance, even when it adds nothing.
  if (lines.isEmpty && overlayXml == null) return editedBaseXml;

  final sources = [?overlayPath, if (libraries.isNotEmpty) 'library manifests'];
  final inserted = StringBuffer()
    ..write(
      '\n    <!-- Permissions merged by rules_flutter from '
      '${sources.join(' and ')} into $basePath. -->',
    );
  for (final line in lines) {
    inserted.write('\n    $line');
  }

  return editedBaseXml.substring(0, insertAt) +
      inserted.toString() +
      editedBaseXml.substring(insertAt);
}

void main(List<String> args) {
  String? basePath;
  String? overlayPath;
  String? outputPath;
  final libraryPaths = <String>[];
  final placeholders = <String>{};

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--base' && i + 1 < args.length) {
      basePath = args[++i];
    } else if (args[i] == '--overlay' && i + 1 < args.length) {
      overlayPath = args[++i];
    } else if (args[i] == '--library' && i + 1 < args.length) {
      libraryPaths.add(args[++i]);
    } else if (args[i] == '--placeholder' && i + 1 < args.length) {
      placeholders.add(args[++i]);
    } else if (args[i] == '--output' && i + 1 < args.length) {
      outputPath = args[++i];
    }
  }

  if (basePath == null || outputPath == null) {
    stderr.writeln(
      'Usage: dart merge_android_manifests.dart --base <path> '
      '[--overlay <path>] [--library <path>]... --output <path>',
    );
    exit(1);
  }

  final String merged;
  try {
    merged = mergeManifests(
      baseXml: File(basePath).readAsStringSync(),
      basePath: basePath,
      overlayXml: overlayPath == null
          ? null
          : File(overlayPath).readAsStringSync(),
      overlayPath: overlayPath,
      libraries: {
        for (final path in libraryPaths) path: File(path).readAsStringSync(),
      },
      placeholders: placeholders,
    );
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  File(outputPath).writeAsStringSync(merged);
}
