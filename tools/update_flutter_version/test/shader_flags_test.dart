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

/// The same switch as flutter_tools 3.50 writes it, over `TargetOS`.
const _flutterTools350 = '''
  List<String> _shaderTargetsFromTargetPlatform(TargetPlatform targetPlatform) {
    switch (targetPlatform.os) {
      case .android || .linux || .windows:
        return <String>[
          '--sksl',
          '--runtime-stage-gles',
          '--runtime-stage-gles3',
          '--runtime-stage-vulkan',
        ];

      case .ios:
        return <String>['--runtime-stage-metal'];
      case .macos:
        return <String>['--sksl', '--runtime-stage-metal'];

      case .fuchsia || .tester:
        return <String>['--sksl', '--runtime-stage-vulkan'];

      case .web:
        return <String>['--sksl'];

      case .unsupported:
        TargetPlatform.throwUnsupportedTarget();
    }
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

  test('reads the switch over TargetOS as the one over TargetPlatform', () {
    expect(
      flutterToolsShaderFlags(_flutterTools350),
      flutterToolsShaderFlags(_flutterTools),
    );
  });

  test('a switch it cannot read is an error, not an empty table', () {
    expect(
      () => flutterToolsShaderFlags(
        '_shaderTargetsFromTargetPlatform() { switch (x) { case Os.ios: } }',
      ),
      throwsFormatException,
    );
  });

  test('reads qualified TargetOS cases as dot shorthand', () {
    expect(
      flutterToolsShaderFlags(
        _flutterTools350.replaceFirst(
          'case .android || .linux || .windows:',
          'case TargetOS.android || TargetOS.linux || TargetOS.windows:',
        ),
      ),
      flutterToolsShaderFlags(_flutterTools350),
    );
  });

  test('a case it cannot read is an error, not a dropped platform', () {
    expect(
      () => flutterToolsShaderFlags(
        _flutterTools350.replaceFirst('case .ios:', 'case .ios when metal:'),
      ),
      throwsFormatException,
    );
  });

  test('a platform it does not know is an error', () {
    expect(
      () => flutterToolsShaderFlags(
        _flutterTools350.replaceFirst('case .web:', 'case .web || .ohos:'),
      ),
      throwsFormatException,
    );
  });

  test('reads only the switch, not the code after it', () {
    expect(
      flutterToolsShaderFlags(_flutterTools).values.expand((f) => f),
      isNot(contains('--not-a-flag')),
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
