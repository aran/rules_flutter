// Makes `mul` patchable in a running app: every call goes through
// `hot_patch_router.h`, which a patch of `mul.c` can redirect.

#include "mul_body.h"

#define ROUTED mul
#define ROUTED_BODY mul_body
#include "hot_patch_router.h"
