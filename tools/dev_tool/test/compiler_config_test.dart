import 'package:flutter_bazel_dev_tool/compiler_config.dart';
import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:test/test.dart';

WebToolchainPaths webToolchain() => WebToolchainPaths(
  ddcOutlineDill: '/tc/ddc_outline.dill',
  librariesSpec: '/tc/libraries.json',
  dartSdkJs: '/tc/dart_sdk.js',
  ddcModuleLoaderJs: '/tc/ddc_module_loader.js',
  stackTraceMapperJs: '/tc/stack_trace_mapper.js',
  dartSdkRoot: '/tc/dart-sdk',
);

void main() {
  group('enableExperiments', () {
    // The build emits bare names; the frontend server wants
    // `--enable-experiment=<name>`. These live on the resident compiler's own
    // argv, so they hold for the initial compile and every recompile after it
    // — an experiment is a property of the process, not of a request.

    test('native config spells each experiment as a flag', () {
      final flags = NativeCompilerConfig(
        patchedSdkRoot: '/patched',
        enableExperiments: const ['records', 'macros'],
      ).extraFlags;
      expect(flags, contains('--enable-experiment=records'));
      expect(flags, contains('--enable-experiment=macros'));
    });

    test('web config spells each experiment as a flag', () {
      final flags = WebCompilerConfig(
        webToolchain: webToolchain(),
        enableExperiments: const ['records'],
      ).extraFlags;
      expect(flags, contains('--enable-experiment=records'));
    });

    test('no experiments emits no experiment flag on either target', () {
      // Mutation guard: a `for` loop that emitted an empty-name flag would
      // pass the two cases above and break every app that enables none.
      expect(
        NativeCompilerConfig(patchedSdkRoot: '/patched').extraFlags,
        isNot(contains(startsWith('--enable-experiment'))),
      );
      expect(
        WebCompilerConfig(webToolchain: webToolchain()).extraFlags,
        isNot(contains(startsWith('--enable-experiment'))),
      );
    });

    test('experiments do not disturb the flags around them', () {
      // The list is spliced into an ordered argv. A splice that ate its
      // neighbour would still satisfy the `contains` checks above.
      final flags = WebCompilerConfig(
        webToolchain: webToolchain(),
        enableExperiments: const ['records'],
        dartDefines: const ['A=1'],
      ).extraFlags;
      expect(flags, contains('--dartdevc-canary'));
      expect(flags, contains('--experimental-emit-debug-metadata'));
      expect(flags, contains('-DA=1'));

      final native = NativeCompilerConfig(
        patchedSdkRoot: '/patched',
        enableExperiments: const ['records'],
        dartDefines: const ['A=1'],
      ).extraFlags;
      expect(native, contains('--enable-asserts'));
      expect(native, contains('-DA=1'));
    });
  });
}
