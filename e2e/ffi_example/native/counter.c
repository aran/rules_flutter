#include "counter_body.h"

// The code a hot reload can patch. Compiled into the app's `counter` library,
// where `counter_hot_patch.c` routes every call through it, and on its own into
// `counter_patch`, the library a hot reload loads beside the running one.
//
// It keeps nothing of its own: a static here would be a second count in every
// patch, starting at zero (see `counter_body.h`).
FFI_EXAMPLE_EXPORT int32_t counter_bump_body(struct counter_state *state) {
    state->count += 1;
    return state->count;
}
