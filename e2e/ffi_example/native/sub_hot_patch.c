// Makes `sub` patchable in a running app: every call goes through
// `hot_patch_router.h`, which a patch of `sub.c` can redirect.

#include "sub_body.h"

#define ROUTED_BODY sub_body
#define ROUTED_BODY_TYPE sub_body_fn
typedef int32_t (*ROUTED_BODY_TYPE)(int32_t, int32_t);
#include "hot_patch_router.h"

FFI_EXAMPLE_EXPORT int32_t sub(int32_t a, int32_t b) {
    return routed_body(a, b);
}
