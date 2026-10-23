/// Helper library compiled into a modular `.flutter.kmod` / `.flutter.koutline`
/// dependency of `:modular_dbg_assert_flutter_test`.
library;

/// Throws [AssertionError] when assertions are enabled.
void triggerLibraryAssert() {
  assert(false, 'library assert fired');
}

/// Class with a `const` constructor assertion compiled into `.flutter.koutline`.
class CheckedConst {
  const CheckedConst({required this.valid})
    : assert(valid, 'constructor assert fired');

  final bool valid;
}
