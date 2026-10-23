// A package import the `compile_api` extras caller compiles: reaching it
// through `package:` proves a caller rule built only on `//flutter:utils.bzl`
// wires `deps` into the compile, alongside `vm_flags`/`import_dill`.
import 'package:compile_api_dep/compile_api_dep.dart';

void main() {
  if (compileApiDepValue != 7) {
    throw StateError('bad dep');
  }
}
