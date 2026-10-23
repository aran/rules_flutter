// Hostile web-guard fixture: a schemeless `//`-prefixed import, which the
// resolvers map to nothing (see `file_main.dart`). Null never means
// "declared": the guard refuses it before the compiler runs.
import '//host/secret.dart';

void main() {
  print(webGuardSecret);
}
