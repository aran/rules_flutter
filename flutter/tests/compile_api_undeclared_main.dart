// Entrypoint fixture for the `compile_api` soundness test: it imports a
// sibling that exists on disk but is never declared in `srcs`. Even beside
// an `import_dill`, the guard must refuse this import — the sibling's bytes
// come from the host, not from a compiled, declared input.
import 'compile_api_undeclared_sibling.dart';

void main() {
  if (compileApiUndeclaredSibling != 1) {
    throw StateError('bad sibling');
  }
}
