/// Verifies what every built bundle says about service workers.
///
/// What ships is Flutter's own teardown worker: it unregisters itself and
/// reloads its clients, releasing a visitor still holding a cache-first worker
/// from an earlier `flutter build web`. A cache-first worker must never ship
/// here — a browser installs an update only when the worker script differs
/// byte for byte, so one that caches `/` and `index.html` can pin a visitor to
/// a single build permanently, with no way to reach them afterwards.
///
/// Runs as a Bazel dart_test with the bundles as data dependencies.
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

  var failed = false;

  void fail(String label, String message) {
    stderr.writeln('$label: FAIL — $message');
    failed = true;
  }

  String? read(String label, String path) {
    final file = File(path);
    if (!file.existsSync()) {
      fail(label, 'expected file not found at $path');
      return null;
    }
    return file.readAsStringSync();
  }

  /// Asserts the shape of a bundle that ships the worker (`pwa = True`).
  void checkPwaBundle({required String label, required String bundlePath}) {
    final worker = read(label, '$bundlePath/flutter_service_worker.js');
    if (worker != null) {
      if (!worker.contains('self.registration.unregister()')) {
        fail(label, 'the worker does not unregister itself');
      }
      if (!worker.contains('client.navigate(client.url)')) {
        fail(
          label,
          'the worker does not reload its clients, so a client controlled '
          'by the old caching worker keeps reading its cache',
        );
      }
      // A worker that touches the Cache API is the bug this test exists for.
      for (final banned in const [
        'caches.open',
        'caches.match',
        'cache.addAll',
        'CACHE_NAME',
      ]) {
        if (worker.contains(banned)) {
          fail(label, 'the worker caches (`$banned` present)');
        }
      }
    }

    final bootstrap = read(label, '$bundlePath/flutter_bootstrap.js');
    if (bootstrap != null) {
      if (!bootstrap.contains('serviceWorkerSettings')) {
        fail(
          label,
          'flutter_bootstrap.js does not pass serviceWorkerSettings, so '
          'flutter.js never registers the worker and a visitor holding the '
          'old caching worker is never freed',
        );
      }
      // Passing serviceWorkerUrl takes flutter.js's unconditional-register
      // branch, which installs a worker for first-time visitors who have
      // nothing to tear down — and warns about deprecation in their console.
      if (bootstrap.contains('serviceWorkerUrl')) {
        fail(label, 'flutter_bootstrap.js sets serviceWorkerUrl');
      }
    }

    final index = read(label, '$bundlePath/index.html');
    if (index != null && index.contains('navigator.serviceWorker.register')) {
      fail(
        label,
        'index.html registers the worker itself; registration belongs to '
        'flutter.js, which also waits for activation and times out',
      );
    }

    if (!failed) print('$label: OK (teardown worker, registered via loader).');
  }

  /// Asserts a `pwa = False` bundle ships and says nothing about workers.
  void checkNoPwaBundle({required String label, required String bundlePath}) {
    if (File('$bundlePath/flutter_service_worker.js').existsSync()) {
      fail(label, 'pwa = False still emitted flutter_service_worker.js');
    }
    final bootstrap = read(label, '$bundlePath/flutter_bootstrap.js');
    if (bootstrap != null && bootstrap.contains('serviceWorkerSettings')) {
      fail(label, 'pwa = False still registers a service worker');
    }
    if (!failed) print('$label: OK (no worker, no registration).');
  }

  final root = '$testSrcDir/$testWorkspace';

  // Tier 1 (flutter_web_app), user-provided web/index.html.
  checkPwaBundle(label: 'app_wasm', bundlePath: '$root/app_wasm_web');

  // Tier 2 (flutter_web_bundle) with a generated index.html — the other path
  // through index.html generation, and a dart2js-only bundle.
  checkPwaBundle(label: 'app_js', bundlePath: '$root/app_js_web');

  checkNoPwaBundle(label: 'app_no_pwa', bundlePath: '$root/app_no_pwa_web');

  if (failed) {
    exit(1);
  }
  print('');
  print('All service worker checks passed.');
}
