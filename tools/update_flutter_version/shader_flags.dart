/// Whether rules_flutter's impellerc flags still match `flutter_tools`'.
///
/// `flutter_shader_compile.bzl` mirrors, per target platform, the runtime
/// stages `flutter build` compiles a shader for. Flutter changes that list
/// from time to time (a new backend, a stage dropped), and a stale mirror
/// builds shaders that fail to load at runtime on the platform that moved.
/// A version bump is when to look.
library;

/// `flutter_tools`' `TargetPlatform` names, folded into the platform names
/// `SHADER_PLATFORM_FLAGS` uses. Fuchsia is not a rules_flutter target.
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
};

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
  final body = source.substring(start);
  final out = <String, List<String>>{};
  var pending = <String>[];
  final caseOrReturn = RegExp(
    r'case TargetPlatform\.(\w+):|return <String>\[([^\]]*)\]',
  );
  for (final m in caseOrReturn.allMatches(body)) {
    if (m[1] != null) {
      pending.add(m[1]!);
      continue;
    }
    final flags = RegExp(r"'([^']+)'").allMatches(m[2]!).map((f) => f[1]!);
    for (final platform in pending) {
      final name = _platformNames[platform];
      if (name != null) out[name] = flags.toList();
    }
    pending = [];
    // The switch ends at its last return; the rest of the file is other code.
    if (out.length == _platformNames.values.toSet().length) break;
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
