// Entrypoint fixture for the `compile_api` real-`import_dill` compile: it
// imports the same library the `_compile_api_dill_source` target compiled,
// and the `_compile_api_import` target consumes that dill as `import_dill`
// while keeping the dep's sources declared — `frontend_server` re-reads an
// imported dill's source closure, so the sound shape declares it.
import 'package:compile_api_dep/compile_api_dep.dart';

void main() {
  if (compileApiDepValue != 7) {
    throw StateError('bad dep');
  }
}
