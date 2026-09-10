// Entrypoint fixture for the `language_version` analysis tests.
//
// Deliberately framework-free, like `web_fixture_main.dart` beside it: the
// tests read declared actions and providers, never build the fixtures, so the
// root workspace's lack of a `package:flutter` never comes up.
//
// Under `lib/`, like a real app's `main`, so it is reachable as
// `package:lv_fixture/language_version_main.dart` through the app package
// record `synthesize_app_package` writes — the same record whose
// `languageVersion` these tests exist to pin.
void main() {}
