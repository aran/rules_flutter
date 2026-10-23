// Hostile web-guard fixture: a relative import climbing out of the declared
// inputs to an undeclared file (see `file_main.dart`).
import '../secret.dart';

void main() {
  print(webGuardSecret);
}
