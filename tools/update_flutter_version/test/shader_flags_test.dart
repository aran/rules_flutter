import 'package:test/test.dart';

import '../shader_flags.dart';

/// `_shaderTargetsFromTargetPlatform` as flutter_tools 3.47 writes it.
const _flutterTools = '''
  List<String> _shaderTargetsFromTargetPlatform(TargetPlatform targetPlatform) {
    switch (targetPlatform) {
      case TargetPlatform.android_x64:
      case TargetPlatform.android_arm:
      case TargetPlatform.android_arm64:
      case TargetPlatform.android:
      case TargetPlatform.linux_x64:
      case TargetPlatform.linux_arm64:
      case TargetPlatform.linux_riscv64:
      case TargetPlatform.windows_x64:
      case TargetPlatform.windows_arm64:
        return <String>[
          '--sksl',
          '--runtime-stage-gles',
          '--runtime-stage-gles3',
          '--runtime-stage-vulkan',
        ];

      case TargetPlatform.ios:
        return <String>['--runtime-stage-metal'];
      case TargetPlatform.darwin:
        return <String>['--sksl', '--runtime-stage-metal'];

      case TargetPlatform.fuchsia_arm64:
      case TargetPlatform.fuchsia_x64:
      case TargetPlatform.tester:
        return <String>['--sksl', '--runtime-stage-vulkan'];

      case TargetPlatform.web_javascript:
        return <String>['--sksl'];

      case TargetPlatform.unsupported:
        TargetPlatform.throwUnsupportedTarget();
    }
  }

  Future<bool> compileShader() async {
    return <String>['--not-a-flag'];
  }
''';

const _rules = '''
SHADER_PLATFORM_FLAGS = {
    "ios": ["--runtime-stage-metal"],
    "macos": ["--sksl", "--runtime-stage-metal"],
    "android": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "linux": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "windows": ["--sksl", "--runtime-stage-gles", "--runtime-stage-gles3", "--runtime-stage-vulkan"],
    "web": ["--sksl"],
    "tester": ["--sksl", "--runtime-stage-vulkan"],
}
''';

void main() {
  test('reads every platform, folding flutter_tools names into ours', () {
    final flags = flutterToolsShaderFlags(_flutterTools);
    expect(flags.keys.toSet(), {
      'android',
      'linux',
      'windows',
      'ios',
      'macos',
      'tester',
      'web',
    });
    expect(flags['macos'], ['--sksl', '--runtime-stage-metal']);
    expect(flags['tester'], ['--sksl', '--runtime-stage-vulkan']);
  });

  test('agreeing tables have no mismatch', () {
    expect(
      shaderFlagMismatches(
        flutterToolsShaderFlags(_flutterTools),
        rulesShaderFlags(_rules),
      ),
      isEmpty,
    );
  });

  test('a stage flutter_tools added is reported', () {
    final moved = _flutterTools.replaceFirst(
      "return <String>['--runtime-stage-metal'];",
      "return <String>['--runtime-stage-metal', '--runtime-stage-vulkan'];",
    );
    expect(
      shaderFlagMismatches(
        flutterToolsShaderFlags(moved),
        rulesShaderFlags(_rules),
      ),
      [
        'ios: flutter_tools [--runtime-stage-metal, --runtime-stage-vulkan], '
            'rules_flutter [--runtime-stage-metal]',
      ],
    );
  });
}
