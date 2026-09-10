// Entrypoint fixture for the flutter_web_bundle tests in web_test.bzl.
//
// Deliberately framework-free: the root workspace carries no pub deps for
// package:flutter, and the web wrapper main only needs `dart:ui_web` (which
// comes from the web platform dill), so `void main() {}` is enough for both
// the analysis tests and the build_tests that actually run dart2wasm/dart2js.
//
// Under `lib/`, like a real app's `main`, which is what makes it reachable as
// `package:web_fixture/web_fixture_main.dart`. That URI resolves through the
// app package record `synthesize_app_package` writes, and the record is rooted
// at this target's own Bazel package. While it was hardcoded to the workspace
// root, this file could not be compiled at all — the import resolved to
// `//lib/web_fixture_main.dart`, which does not exist — and the fixtures all
// had to sit beside `lib/` instead. See `app_main_package_uri`.
void main() {}
