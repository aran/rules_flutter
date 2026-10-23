// Hostile web-guard fixture: an app-scheme import naming a file no target
// declares (see `file_main.dart`). The app scheme resolves only across the
// compile's staging root, which holds declared inputs alone.
import 'org-dartlang-app:///flutter/tests/web_guard_fixture/lib/secret.dart';

void main() {
  print(webGuardSecret);
}
