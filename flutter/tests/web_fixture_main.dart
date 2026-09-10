// Entrypoint fixture for `_web_pkg_root_main_fixture` in web_test.bzl.
//
// Deliberately NOT under a `lib/` directory: a file beside its package's
// `lib/` is reachable by no `package:` URI, which is the shape
// `_no_package_uri_refused_test` pins. A release web bundle can still express
// it — the generated wrapper falls back to a relative import — but the DDC dev
// loop compiles its synthetic entrypoint from a staging directory under
// `org-dartlang-app:` and can reach the app only by package URI, so a `-c dbg`
// build of this target stops and says so.
//
// Its `lib/` sibling is the fixture everything else uses. Both existed only as
// the two halves of a strip that has since been replaced by one shared prefix;
// see `package_lib_prefix`.
void main() {}
