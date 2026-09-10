/// Verifies the web compiler settings reach the shipped bundle, by reading the
/// bundle rather than the command line.
///
/// The analysis tests in `flutter/tests/web_test.bzl` pin the flags onto the
/// dart2js and dart2wasm argv. That proves what was asked for, not what came
/// out — a flag can be spelled correctly, accepted by the compiler, and still
/// change nothing. So this compares two builds of the SAME app:
///
///   app_wasm:  the defaults, which in the default (release) configuration
///              means minified JS and a stripped, minified WASM.
///   app_tuned: minify_js/minify_wasm off and strip_wasm off, plus dump_info.
///
/// Every assertion below is a difference between those two bundles, so it
/// fails if the attrs stop being honoured — which asserting on one bundle
/// alone would not.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final root = '$testSrcDir/$testWorkspace';

  var failed = false;
  void check(String label, {required bool ok, required String detail}) {
    if (ok) {
      print('$label: OK ($detail)');
    } else {
      stderr.writeln('$label: FAIL — $detail');
      failed = true;
    }
  }

  File bundleFile(String target, String name) {
    final f = File('$root/${target}_web/$name');
    if (!f.existsSync()) {
      stderr.writeln('missing $name in $target bundle at ${f.path}');
      failed = true;
    }
    return f;
  }

  final tunedJs = bundleFile('app_tuned', 'main.dart.js');
  final defaultJs = bundleFile('app_wasm', 'main.dart.js');
  final tunedWasm = bundleFile('app_tuned', 'main.dart.wasm');
  final defaultWasm = bundleFile('app_wasm', 'main.dart.wasm');
  if (failed) exit(1);

  // minify_js = "false" — the Dart names survive into the JavaScript. Checked
  // by name rather than by size alone: a size difference could come from any
  // of the other settings, but an identifier only survives minification being
  // off.
  final tunedJsText = tunedJs.readAsStringSync();
  final defaultJsText = defaultJs.readAsStringSync();
  for (final identifier in ['StatelessWidget', 'MyHomePage']) {
    check(
      'minify_js=false keeps `$identifier`',
      ok: tunedJsText.contains(identifier),
      detail: 'present in the unminified build',
    );
    check(
      'default build minifies `$identifier` away',
      ok: !defaultJsText.contains(identifier),
      detail: 'absent from the default release build, as it should be',
    );
  }

  // strip_wasm = False + minify_wasm = "false" — the WASM keeps what the
  // default build discards, so it is materially larger.
  final tunedWasmLen = tunedWasm.lengthSync();
  final defaultWasmLen = defaultWasm.lengthSync();
  check(
    'strip_wasm=False/minify_wasm=false keep WASM symbols',
    ok: tunedWasmLen > defaultWasmLen,
    detail: 'tuned $tunedWasmLen bytes > default $defaultWasmLen bytes',
  );

  // dump_info = True — the report is a named build output, NOT something
  // every visitor downloads. `flutter build web` writes it into the deployed
  // directory; this rule deliberately does not, and the file runs to tens of
  // megabytes for this app, so the difference is not academic.
  final strays = Directory('$root/app_tuned_web')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.info.json'))
      .toList();
  check(
    'dump_info stays out of the deployed bundle',
    ok: strays.isEmpty,
    detail: strays.isEmpty
        ? 'no .info.json shipped'
        : 'shipped ${strays.length}: $strays',
  );

  // The compile debris dart2js writes beside its output must not ship either.
  final deps = Directory('$root/app_tuned_web')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.deps'))
      .toList();
  check(
    'dart2js .deps stays out of the deployed bundle',
    ok: deps.isEmpty,
    detail: deps.isEmpty ? 'no .deps shipped' : 'shipped ${deps.length}: $deps',
  );

  // `use_local_canvaskit` is the difference between an app that renders under
  // a strict `script-src 'self'` and one that does not: without it the engine
  // fetches CanvasKit from gstatic.com, and the policy blocks it. Both bundles
  // ship a local `canvaskit/` either way, so file presence proves nothing —
  // `useLocalCanvasKit` in the build config is the flag the loader actually
  // reads, which makes it the thing worth asserting.
  final tunedConfig = File(
    '$root/app_tuned_web/flutter_bootstrap.js',
  ).readAsStringSync();
  check(
    'app_tuned declares useLocalCanvasKit',
    ok: tunedConfig.contains('"useLocalCanvasKit":true'),
    detail: tunedConfig.contains('"useLocalCanvasKit":true')
        ? 'renderer loads from the app origin'
        : 'absent — the engine would fetch CanvasKit from gstatic.com, '
              "which `script-src 'self'` blocks",
  );

  // The negative half: a target that does not ask for it must not get it, or
  // the assertion above would pass for every build and prove nothing.
  final jsConfig = File(
    '$root/app_js_web/flutter_bootstrap.js',
  ).readAsStringSync();
  check(
    'app_js leaves useLocalCanvasKit unset',
    ok: !jsConfig.contains('useLocalCanvasKit'),
    detail: !jsConfig.contains('useLocalCanvasKit')
        ? 'absent as declared'
        : 'present without the attribute being set',
  );

  if (failed) exit(1);
  print('');
  print('All web compiler-flag checks passed.');
}
