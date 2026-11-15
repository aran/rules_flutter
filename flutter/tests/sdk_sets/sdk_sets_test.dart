/// Runs the tools that build actions run against real copies of the Flutter
/// SDK files those actions declare (see BUILD.bazel for why a copy), so an
/// action short of a file it reads fails here and not only on a remote
/// executor.
///
/// Arguments: `generate_asset_manifest=<runfiles path>`, and `<copy>=<runfiles path>` for
/// each copy BUILD.bazel declares.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final paths = {
    for (final a in args)
      a.substring(0, a.indexOf('=')): runfiles.rlocation(
        a.substring(a.indexOf('=') + 1),
      ),
  };
  final exe = Platform.isWindows ? '.exe' : '';

  /// A file of a copy: `dart-sdk/<path>` for the SDK's own, else `extra/`.
  String sdk(String copy, String path) => '${paths[copy]}/dart-sdk/$path';

  /// A program of a copy's SDK, `bin/<name>`, which on Windows ends `.exe`;
  /// the snapshots it runs do not.
  String program(String copy, String name) => sdk(copy, 'bin/$name$exe');
  String extra(String copy, String name) => '${paths[copy]}/extra/$name';

  late Directory work;
  late String app;
  late String packages;
  late String webApp;
  final environment = <String, String>{};

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory ?? app,
      environment: environment,
    );
    expect(
      result.exitCode,
      0,
      reason:
          '$executable ${arguments.join(' ')}\n${result.stdout}\n${result.stderr}',
    );
    return result;
  }

  setUpAll(() {
    work = Directory.systemTemp.createTempSync('sdk_sets.');
    // The SDK writes nothing into the real home.
    environment
      ..['HOME'] = work.path
      ..['APPDATA'] = work.path
      ..['DART_SUPPRESS_ANALYTICS'] = 'true';
    app = '${work.path}/app';
    void write(String path, String content) => (File(
      '$app/$path',
    )..createSync(recursive: true)).writeAsStringSync(content);
    write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'app',
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.0',
          },
        ],
      }),
    );
    write('lib/answer.dart', 'int answer() => 42;\n');
    write(
      'lib/main.dart',
      "import 'package:app/answer.dart';\n"
          'void main() { answer(); }\n',
    );
    write(
      'web/main.dart',
      "import 'dart:js_interop';\n"
          "import 'package:app/answer.dart';\n"
          "@JS('console.log')\n"
          'external void log(JSAny? value);\n'
          'void main() { log(answer().toJS); }\n',
    );
    packages = '$app/.dart_tool/package_config.json';
    webApp = '$app/web/main.dart';
  });

  tearDownAll(() => work.deleteSync(recursive: true));

  // The app's kernel, compiled as DartKernel does, once for the tests that
  // read it.
  Future<String>? compiled;
  Future<String> appKernel() => compiled ??= () async {
    final output = '${work.path}/app.dill';
    await run(program('kernel_compile', 'dartaotruntime'), [
      sdk('kernel_compile', 'bin/snapshots/frontend_server_aot.dart.snapshot'),
      '--sdk-root',
      '${paths['kernel_compile']}/extra/',
      '--target',
      'flutter',
      '--packages',
      packages,
      '--output-dill',
      output,
      '--no-print-incremental-dependencies',
      'package:app/main.dart',
    ]);
    return output;
  }();

  group('kernel', () {
    test('the front end compiles a whole program with no tool_files', () async {
      expect(File(await appKernel()).lengthSync(), greaterThan(0));
    });

    test('kernel_worker compiles a module with no tool_files', () async {
      final output = '${work.path}/module.dill';
      await run(program('kernel_worker', 'dartaotruntime'), [
        sdk('kernel_worker', 'bin/snapshots/kernel_worker_aot.dart.snapshot'),
        '--target',
        'flutter',
        // URIs: kernel_worker resolves both as URIs, so an absolute Windows
        // path would read as the scheme `c:`. The build's actions pass
        // relative paths, which resolve either way.
        '--dart-sdk-summary',
        Uri.file(extra('kernel_worker', 'platform_strong.dill')).toString(),
        '--packages-file',
        Uri.file(packages).toString(),
        '--no-summary-only',
        '--exclude-non-sources',
        '--source',
        'package:app/answer.dart',
        '--output',
        output,
      ]);
      expect(File(output).lengthSync(), greaterThan(0));
    });
  });

  group('script', () {
    test('the VM runs a script from source', () async {
      final bundle = '${work.path}/flutter_assets';
      final config = File('${work.path}/assets.json')
        ..writeAsStringSync(jsonEncode({'assets': {}, 'fonts': []}));
      await run(program('script', 'dart'), [
        paths['generate_asset_manifest']!,
        '--config',
        config.path,
        '--output-dir',
        bundle,
      ]);
      expect(File('$bundle/AssetManifest.bin').existsSync(), isTrue);
    });
  });

  group('web', () {
    test('dart compile js', () async {
      final output = '${work.path}/js/main.dart.js';
      await run(program('dart2js', 'dart'), [
        'compile',
        'js',
        '--platform-binaries=${paths['dart2js']}/extra',
        '--packages=$packages',
        '-O1',
        '-o',
        output,
        webApp,
      ]);
      expect(File(output).existsSync(), isTrue);
    });

    test('dart compile wasm, optimizing', () async {
      final output = '${work.path}/wasm/main.dart.wasm';
      await run(program('dart2wasm', 'dart'), [
        'compile',
        'wasm',
        '--extra-compiler-option=--platform=${extra('dart2wasm', 'dart2wasm_platform.dill')}',
        '--packages=$packages',
        '-O2',
        '-o',
        output,
        webApp,
      ]);
      expect(File(output).existsSync(), isTrue);
    });
  });
}
