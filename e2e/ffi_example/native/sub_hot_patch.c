// Makes `sub` patchable in a running app: every call goes through
// `hot_patch_router.h`, which a patch of `sub.c` can redirect.

#include "sub_body.h"

#define ROUTED sub
#define ROUTED_BODY sub_body
#include "hot_patch_router.h"
