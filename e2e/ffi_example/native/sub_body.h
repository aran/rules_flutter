#ifndef SUB_BODY_H
#define SUB_BODY_H

#include "sub.h"

// Not part of `sub.h`, the binding contract: Dart never calls this, so a change
// to it is not a change to what the bindings may call.
FFI_EXAMPLE_EXPORT int32_t sub_body(int32_t a, int32_t b);

#endif
