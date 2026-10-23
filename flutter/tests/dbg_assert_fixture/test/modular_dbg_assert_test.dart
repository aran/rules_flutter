/// Verifies that both dependency-module (`.flutter.kmod`) and entry-module
/// (`.flutter_entry.kmod`) assertions fire in a `-c dbg` modular `flutter_test`.
library;

import 'package:dbg_assert_fixture/assert_helper.dart';

void main() {
  var entryAssertFired = false;
  try {
    assert(false, 'entry assert fired');
  } on AssertionError {
    entryAssertFired = true;
  }
  if (!entryAssertFired) {
    throw StateError('Expected entry-module assert to fire in -c dbg');
  }

  var libraryAssertFired = false;
  try {
    triggerLibraryAssert();
  } on AssertionError {
    libraryAssertFired = true;
  }
  if (!libraryAssertFired) {
    throw StateError('Expected dependency-module assert to fire in -c dbg');
  }

  var constructorAssertFired = false;
  try {
    // Non-const invocation of a const constructor with an AssertInitializer.
    // ignore: prefer_const_constructors
    CheckedConst(valid: false);
  } on AssertionError {
    constructorAssertFired = true;
  }
  if (!constructorAssertFired) {
    throw StateError('Expected constructor assert to fire in -c dbg');
  }
}
