// Entrypoint reaching the dep: the dill source compiles this, and the
// `import_dill` compile below consumes that dill.
import 'package:consumer_dep/consumer_dep.dart';

void main() {
  if (consumerDepValue != 7) {
    throw StateError('bad dep');
  }
}
