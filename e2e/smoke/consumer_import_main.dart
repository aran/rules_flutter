// Entrypoint for the real-`import_dill` compile: imports the dep whose
// whole-program dill seeds this compile via `import_dill`.
import 'package:consumer_dep/consumer_dep.dart';

void main() {
  if (consumerDepValue != 7) {
    throw StateError('bad dep');
  }
}
