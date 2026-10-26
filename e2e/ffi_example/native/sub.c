#include "sub_body.h"

// The code a hot reload can patch. Compiled into the app's `sub` library, where
// `sub_hot_patch.c` routes every call through it, and on its own into
// `sub_patch`, the library a hot reload loads beside the running one.
FFI_EXAMPLE_EXPORT int32_t sub_body(int32_t a, int32_t b) {
    return a - b;
}
