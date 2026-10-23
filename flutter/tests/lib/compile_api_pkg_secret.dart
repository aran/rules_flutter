// Undeclared fixture for the `compile_api` read-set test: it exists on disk
// inside the `compile_api_dep` package but is in no target's `srcs`, so a
// `package:compile_api_dep/` import of it is an undeclared read. The
// pre-compile directive guard accepts any non-escaping `package:` URI, so
// only the post-compile read-set check refuses it — including under
// `extra_flags = ["--incremental"]` (see `_compile_api_build_negative_pkg`
// in `compile_api_test.bzl`).
String compileApiPkgSecret() => 'pkg-secret-undeclared';
