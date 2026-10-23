// Entrypoint importing a sibling that is NOT declared: the compile must
// fail. Present on disk but absent from `srcs`, the sibling never reaches
// the sandbox, so the read is refused.
import 'consumer_undeclared_sibling.dart';

void main() {
  print(undeclaredValue);
}
