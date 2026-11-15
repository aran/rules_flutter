/// Whether rules_flutter's impellerc flags still match `flutter_tools`'.
///
/// `flutter_shader_compile.bzl` mirrors, per target platform, the runtime
/// stages `flutter build` compiles a shader for. Flutter changes that list
/// from time to time (a new backend, a stage dropped), and a stale mirror
/// builds shaders that fail to load at runtime on the platform that moved.
/// A version bump is when to look.
library;

/// `flutter_tools`' `TargetPlatform` names (to 3.47) and `TargetOS` names
/// (from 3.50), folded into the platform names `SHADER_PLATFORM_FLAGS` uses.
/// Fuchsia is not a rules_flutter target.
const _platformNames = {
  'android': 'android',
  'android_arm': 'android',
  'android_arm64': 'android',
  'android_x64': 'android',
  'linux_x64': 'linux',
  'linux_arm64': 'linux',
  'linux_riscv64': 'linux',
  'windows_x64': 'windows',
  'windows_arm64': 'windows',
  'ios': 'ios',
  'darwin': 'macos',
  'tester': 'tester',
  'web_javascript': 'web',
  'linux': 'linux',
  'windows': 'windows',
  'macos': 'macos',
  'web': 'web',
};

/// Platform names `_shaderTargetsFromTargetPlatform` switches over that
/// rules_flutter builds no shaders for.
const _notTargets = {'fuchsia', 'fuchsia_arm64', 'fuchsia_x64', 'unsupported'};

/// The text between the brace that opens the body of the declaration at
/// [start] in [source] and the brace that closes it.
String _bracedBody(String source, int start) {
  final open = source.indexOf('{', start);
  var depth = 0;
  for (var i = open; i >= 0 && i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return source.substring(open + 1, i);
  }
  throw const FormatException(
    'unterminated _shaderTargetsFromTargetPlatform in shader_compiler.dart',
  );
}

/// The flags `_shaderTargetsFromTargetPlatform` returns in [source], the
/// text of `flutter_tools/lib/src/build_system/tools/shader_compiler.dart`,
/// keyed by rules_flutter platform name.
Map<String, List<String>> flutterToolsShaderFlags(String source) {
  final start = source.indexOf('_shaderTargetsFromTargetPlatform(');
  if (start < 0) {
    throw const FormatException(
      'no _shaderTargetsFromTargetPlatform in shader_compiler.dart',
    );
  }
  final body = _bracedBody(source, start);
  final out = <String, List<String>>{};
  var pending = <String>[];
  // A case names `TargetPlatform` values (`case TargetPlatform.ios:`) or, in
  // a switch over `targetPlatform.os`, `TargetOS` values, qualified or in dot
  // shorthand (`case .android || .linux || .windows:`). A case in any other
  // shape, a guard say, is an error: skipping it would attach its platforms'
  // flags to the wrong case or leave them out.
  final caseOrReturn = RegExp(
    r'case ([^:]+):'
    r'|return <String>\[([^\]]*)\]',
  );
  final value = RegExp(r'^\w*\.(\w+)$');
  for (final m in caseOrReturn.allMatches(body)) {
    if (m[1] != null) {
      for (final alternative in m[1]!.split('||')) {
        final name = value.firstMatch(alternative.trim())?[1];
        if (name == null) {
          throw FormatException(
            'unreadable case in _shaderTargetsFromTargetPlatform: '
            'case ${m[1]}:',
          );
        }
        if (!_platformNames.containsKey(name) && !_notTargets.contains(name)) {
          throw FormatException(
            'unknown platform in _shaderTargetsFromTargetPlatform: $name',
          );
        }
        pending.add(name);
      }
      continue;
    }
    final flags = RegExp(r"'([^']+)'").allMatches(m[2]!).map((f) => f[1]!);
    for (final platform in pending) {
      final name = _platformNames[platform];
      if (name != null) out[name] = flags.toList();
    }
    pending = [];
  }
  if (out.isEmpty) {
    throw const FormatException(
      'no platform cases read from _shaderTargetsFromTargetPlatform',
    );
  }
  return out;
}

/// `SHADER_PLATFORM_FLAGS` in [bzl], the text of `flutter_shader_compile.bzl`.
Map<String, List<String>> rulesShaderFlags(String bzl) {
  final start = bzl.indexOf('SHADER_PLATFORM_FLAGS = {');
  if (start < 0) {
    throw const FormatException('no SHADER_PLATFORM_FLAGS in the .bzl file');
  }
  final end = bzl.indexOf('\n}', start);
  final entry = RegExp(r'"(\w+)":\s*\[([^\]]*)\]');
  return {
    for (final m in entry.allMatches(bzl.substring(start, end)))
      m[1]!: RegExp(r'"([^"]+)"').allMatches(m[2]!).map((f) => f[1]!).toList(),
  };
}

/// One line per platform whose flags differ, empty when they all agree.
List<String> shaderFlagMismatches(
  Map<String, List<String>> flutter,
  Map<String, List<String>> rules,
) => [
  for (final platform in {...flutter.keys, ...rules.keys})
    if ((flutter[platform] ?? const []).join(' ') !=
        (rules[platform] ?? const []).join(' '))
      '$platform: flutter_tools ${flutter[platform] ?? 'none'}, '
          'rules_flutter ${rules[platform] ?? 'none'}',
];
