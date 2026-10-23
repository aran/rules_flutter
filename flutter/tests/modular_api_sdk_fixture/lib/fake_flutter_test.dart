// Stand-in for `package:flutter_test` for the public modular kernel API
// tests: naming a `flutter_library` `flutter_test` makes the kernel module
// aspect emit the shared base dill for it, so the `use_base_dill` callers can
// delta-link against a real base without the root workspace carrying the
// actual SDK package. Nothing here executes (analysis tests never run the
// actions), so the body is only a distinct library.
String fakeFlutterTestMarker = 'fake-flutter-test-sdk';
