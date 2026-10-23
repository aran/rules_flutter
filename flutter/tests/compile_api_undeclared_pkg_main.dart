// Entrypoint fixture for the `compile_api` read-set test: it imports an
// undeclared file from its own dependency package. The directive guard
// accepts the non-escaping `package:` URI, so the post-compile read-set
// check in `kernel_filter` is what refuses the build — including when the
// caller passes `extra_flags = ["--incremental"]`.
import 'package:compile_api_dep/compile_api_pkg_secret.dart';

void main() {
  if (compileApiPkgSecret() != 'pkg-secret-undeclared') {
    throw StateError('bad secret');
  }
}
