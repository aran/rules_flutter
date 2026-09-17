#ifndef MUL_BODY_H
#define MUL_BODY_H

#include "mul.h"

// Not part of `mul.h`, the binding contract: Dart never calls this, so a change
// to it is not a change to what the bindings may call.
FFI_EXAMPLE_EXPORT int32_t mul_body(int32_t a, int32_t b);

#endif
