// Hostile web-guard fixture: a `package:` URI with an empty path segment
// naming an undeclared file (see `file_main.dart`). The front end resolves
// some such spellings absolutely, so the guard refuses them outright.
import 'package:web_guard_fixture//secret.dart';

void main() {
  print(webGuardSecret);
}
