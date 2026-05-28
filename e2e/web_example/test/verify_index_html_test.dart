/// Verifies bundled web index.html files have Flutter's $FLUTTER_BASE_HREF
/// placeholder substituted with the rule's `base_href` value, exercising
/// the three code paths:
///   - app_wasm:         Tier 1 (flutter_web_app) with user-provided
///                       web/index.html and the default base_href "/".
///   - app_wasm_subpath: Same Tier 1 path with a non-default base_href.
///   - app_js:           Tier 2 (flutter_web_bundle composed with
///                       flutter_web_index_html_gen) with non-default base_href.
///
/// Runs as a Bazel dart_test with all three bundles as data dependencies.
library;

import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  var failed = false;

  void check({
    required String label,
    required String bundlePath,
    required String expectedBase,
  }) {
    final indexPath = '$bundlePath/index.html';
    final index = File(indexPath);
    if (!index.existsSync()) {
      stderr.writeln('$label: index.html not found at $indexPath');
      failed = true;
      return;
    }

    final contents = index.readAsStringSync();
    if (contents.contains(r'$FLUTTER_BASE_HREF')) {
      stderr.writeln(r'$label: FAIL — bundled index.html still contains $FLUTTER_BASE_HREF');
      failed = true;
    }
    if (!contents.contains(expectedBase)) {
      stderr.writeln('$label: FAIL — expected `$expectedBase` not found in bundled index.html');
      stderr.writeln('Actual contents:');
      stderr.writeln(contents);
      failed = true;
    } else {
      print('$label: OK ($expectedBase substituted into index.html).');
    }
  }

  final root = '$testSrcDir/$testWorkspace';

  // Tier 1 (flutter_web_app) with user-provided web/index.html and the
  // default base_href = "/".
  check(
    label: 'app_wasm (default base_href)',
    bundlePath: '$root/app_wasm_web',
    expectedBase: '<base href="/">',
  );

  // Same Tier 1 path with a non-default base_href.
  check(
    label: 'app_wasm_subpath',
    bundlePath: '$root/app_wasm_subpath_web',
    expectedBase: '<base href="/web_example/">',
  );

  // Tier 2 (flutter_web_bundle) with generated index.html via
  // flutter_web_index_html_gen and a non-default base_href.
  check(
    label: 'app_js',
    bundlePath: '$root/app_js_web',
    expectedBase: '<base href="/web_example_js/">',
  );

  if (failed) {
    exit(1);
  }
  print('');
  print('All web index.html substitution checks passed.');
}
