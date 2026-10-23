// Hostile web-guard fixture: a `file:` import of an undeclared file.
//
// `lib/secret.dart` sits beside this file on the host but in no target's
// `srcs`. The `web_guard` wrapper every web compile runs behind must refuse
// this import with `is not a declared input` before the compiler runs — under
// the sandboxed and the local strategy alike — so the secret is never
// embedded in the bundle.
import 'file:../secret.dart';

void main() {
  print(webGuardSecret);
}
