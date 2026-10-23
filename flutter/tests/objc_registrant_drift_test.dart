/// Fails when the iOS ObjC registrant drifts from the flutter tool.
///
/// Reads the pinned `packages/flutter_tools/lib/src/flutter_plugins.dart`
/// from `@flutter_dev_root`, extracts its two ObjC template constants with
/// the same semantics the tool's Dart parser gives them (a `'''` literal
/// drops its empty first line), renders them with the tool's mustache
/// semantics for the fixture plugin set, and compares byte-for-byte with
/// what `flutter_ios_registrant` wrote. A template change in a toolchain
/// bump, or a divergence in the rule's copy of the shape, turns this red
/// instead of shipping a registrant the tool would not recognize.
///
/// The last arg is the Swift registrant of an app that excludes one of the
/// two fixture plugins: it proves `flutter_ios_app` forwards
/// `exclude_plugins` to its internal registrant.
///
/// Args (each a single `$(rlocationpaths)` expansion, in order): the tool
/// source, the rule's `.h`, the rule's two-plugin `.m`, the rule's empty
/// `.m`, the app's Swift registrant.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The fixture plugin set, in the order `fake_application` sorts it.
const List<Map<String, String>> _plugins = [
  {'name': 'path_provider_foundation', 'class': 'PathProviderPlugin'},
  {'name': 'url_launcher_ios', 'class': 'URLLauncherPlugin'},
];

/// What the tool fills the templates with: `framework` is always
/// `"Flutter"`, and `prefix` is always empty — the tool reads it from
/// `IOSPlugin.classPrefix`, which its own parser always sets to `""`.
const Map<String, String> _templateVars = {
  'framework': 'Flutter',
  'prefix': '',
};

/// Start of the line holding [tagStart].
int _lineStart(String text, int tagStart) =>
    tagStart == 0 ? 0 : text.lastIndexOf('\n', tagStart - 1) + 1;

/// Offset of the newline ending the line holding [afterTag], or [end].
int _lineEnd(String text, int afterTag, int end) {
  final newline = text.indexOf('\n', afterTag);
  if (newline < 0 || newline >= end) return end;
  return newline;
}

/// Packed `(closeLineStart, afterCloseLine)` for the `{{/key}}` closing the
/// section opened at [from]: the tool's templates keep every section tag
/// standalone, and anything else is a template change worth failing on.
int _findClose(String text, int from, int end, String key) {
  var i = from;
  while (true) {
    final next = text.indexOf('{{', i);
    if (next < 0 || next >= end) {
      throw StateError('no {{/$key}} closing the section');
    }
    final tagEnd = text.indexOf('}}', next);
    if (tagEnd < 0 || tagEnd >= end) {
      throw StateError('unclosed tag at offset $next');
    }
    if (text.substring(next + 2, tagEnd).trim() == '/$key') {
      final lineStart = _lineStart(text, next);
      final lineEnd = _lineEnd(text, tagEnd + 2, end);
      if (text.substring(lineStart, next).trim().isNotEmpty ||
          text.substring(tagEnd + 2, lineEnd).trim().isNotEmpty) {
        throw StateError('non-standalone {{/$key}}');
      }
      return lineStart * 1000000 + (lineEnd >= end ? end : lineEnd + 1);
    }
    i = tagEnd + 2;
  }
}

/// Renders [text] over [start, end): `{{var}}` substitution, `{{!comment}}`
/// elision, and `{{#methodChannelPlugins}}` repetition — the only three tag
/// shapes the ObjC templates use. A tag shape outside those throws: the
/// renderer must stay an exact model of what the templates need, so a new
/// shape in a toolchain bump fails here rather than rendering wrong.
void _render(
  String text,
  int i,
  int end,
  Map<String, String> vars,
  List<Map<String, String>>? items,
  StringBuffer out,
) {
  while (true) {
    final next = text.indexOf('{{', i);
    if (next < 0 || next >= end) {
      out.write(text.substring(i, end));
      return;
    }
    final tagEnd = text.indexOf('}}', next);
    if (tagEnd < 0 || tagEnd >= end) {
      throw StateError('unclosed tag at offset $next');
    }
    final raw = text.substring(next + 2, tagEnd).trim();
    if (raw.isEmpty) throw StateError('empty tag at offset $next');
    final marker = raw[0];
    if (marker != '#' && marker != '/' && marker != '!') {
      out.write(text.substring(i, next));
      if (!vars.containsKey(raw)) {
        throw StateError('unknown variable {{$raw}}');
      }
      out.write(vars[raw]);
      i = tagEnd + 2;
      continue;
    }
    final key = raw.substring(1).trim();
    final lineStart = _lineStart(text, next);
    final lineEnd = _lineEnd(text, tagEnd + 2, end);
    final standalone =
        text.substring(lineStart, next).trim().isEmpty &&
        text.substring(tagEnd + 2, lineEnd).trim().isEmpty;
    if (marker == '!') {
      // A standalone comment eats its whole line; an inline one just itself.
      out.write(text.substring(i, standalone ? lineStart : next));
      i = standalone ? (lineEnd >= end ? end : lineEnd + 1) : tagEnd + 2;
      continue;
    }
    if (marker == '/') throw StateError('stray {{/$key}}');
    if (!standalone) throw StateError('non-standalone {{#$key}}');
    out.write(text.substring(i, lineStart));
    final innerStart = lineEnd >= end ? end : lineEnd + 1;
    final packed = _findClose(text, innerStart, end, key);
    final innerEnd = packed ~/ 1000000;
    final afterClose = packed % 1000000;
    if (items == null || key != 'methodChannelPlugins') {
      throw StateError('cannot render section {{#$key}}');
    }
    for (final item in items) {
      _render(
        text,
        innerStart,
        innerEnd,
        Map<String, String>.of(vars)..addAll(item),
        null,
        out,
      );
    }
    i = afterClose;
  }
}

/// The template constant [name] as the tool's Dart parser sees it.
String _extractTemplate(String source, String name) {
  final marker = "const $name = '''";
  final open = source.indexOf(marker);
  if (open < 0) throw StateError('$name not found in flutter_plugins.dart');
  final bodyStart = open + marker.length;
  final close = source.indexOf("'''", bodyStart);
  if (close < 0) throw StateError('$name never closes in flutter_plugins.dart');
  final body = source.substring(bodyStart, close);
  if (!body.startsWith('\n')) {
    throw StateError(
      '$name does not start with a newline; extraction is stale',
    );
  }
  return body.substring(1);
}

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final keys = args
      .expand((arg) => arg.split(RegExp(r'\s+')))
      .where((key) => key.isNotEmpty)
      .toList();
  if (keys.length != 5) {
    throw StateError(
      'expected 5 rlocationpaths (tool, header, impl, empty impl, app '
      'registrant), got ${keys.length}',
    );
  }
  final toolSource = File(runfiles.rlocation(keys[0])).readAsStringSync();
  final headerTemplate = _extractTemplate(
    toolSource,
    '_objcPluginRegistryHeaderTemplate',
  );
  final implTemplate = _extractTemplate(
    toolSource,
    '_objcPluginRegistryImplementationTemplate',
  );
  List<int> ruleBytes(String key) =>
      File(runfiles.rlocation(key)).readAsBytesSync();

  group('ObjC registrant matches the flutter tool byte-for-byte', () {
    test('header', () {
      final rendered = StringBuffer();
      _render(
        headerTemplate,
        0,
        headerTemplate.length,
        _templateVars,
        _plugins,
        rendered,
      );
      expect(ruleBytes(keys[1]), equals(rendered.toString().codeUnits));
    });
    test('two-plugin implementation', () {
      final rendered = StringBuffer();
      _render(
        implTemplate,
        0,
        implTemplate.length,
        _templateVars,
        _plugins,
        rendered,
      );
      expect(ruleBytes(keys[2]), equals(rendered.toString().codeUnits));
    });
    test('empty implementation', () {
      final rendered = StringBuffer();
      _render(
        implTemplate,
        0,
        implTemplate.length,
        _templateVars,
        const [],
        rendered,
      );
      expect(ruleBytes(keys[3]), equals(rendered.toString().codeUnits));
    });
  });

  group('flutter_ios_app forwards exclude_plugins', () {
    test('excluded plugin leaves no import and no call', () {
      final registrant = File(
        runfiles.rlocation(keys[4]),
      ).readAsStringSync();
      expect(registrant, contains('class GeneratedPluginRegistrant'));
      expect(registrant, contains('import path_provider_foundation'));
      expect(registrant, contains('PathProviderPlugin.register(with:'));
      expect(registrant, isNot(contains('url_launcher_ios')));
      expect(registrant, isNot(contains('URLLauncherPlugin')));
    });
  });
}
