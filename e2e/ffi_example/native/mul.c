#include "mul_body.h"

// The code a hot reload can patch. Compiled into the app's `mul` library, where
// `mul_hot_patch.c` routes every call through it, and on its own into
// `mul_patch`, the library a hot reload loads beside the running one.
FFI_EXAMPLE_EXPORT int32_t mul_body(int32_t a, int32_t b) {
    return a * b;
}
