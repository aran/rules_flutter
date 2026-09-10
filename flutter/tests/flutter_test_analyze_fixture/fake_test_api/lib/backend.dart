/// Stands in for `package:test_api`, which the root workspace has no pub hub
/// to supply.
///
/// `flutter_test` refuses `deps` that do not transitively expose
/// `package:test_api`, and matches on the package name alone. Nothing imports
/// this file: the fixture's `flutter_test` is never run (it is `manual`), and
/// only its analysis closure is exercised.
library;

/// Present so the package has a library source rather than an empty `lib/`.
const String backendPlaceholder = 'test_api';
