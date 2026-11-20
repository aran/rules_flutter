// Tiny C library exposing one FFI function. Used by the
// `//package_assets/own_assets` app of the packages e2e module to verify the
// rules_flutter Native Assets pipeline is generic — i.e. nothing about it is
// objective_c-specific.

#include <stdint.h>

// Returns a fixed canary value the Dart side renders. If the dylib is
// missing or the manifest doesn't resolve, the FFI lookup throws and
// the screen blanks — which is what the screenshot regression catches.
__attribute__((visibility("default"))) int32_t synthetic_canary(void) {
  return 0x42424242;
}
