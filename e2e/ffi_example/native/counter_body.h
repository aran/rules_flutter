#ifndef COUNTER_BODY_H
#define COUNTER_BODY_H

#include "counter.h"
#include "counter_state.h"

// Not part of `counter.h`, the binding contract: Dart never calls this, so a
// change to it is not a change to what the bindings may call.
//
// The body owns no state: it works on the instance the launched image passes
// it, which is what lets a patch, a second image, carry on the same count.
FFI_EXAMPLE_EXPORT int32_t counter_bump_body(struct counter_state *state);

#endif
