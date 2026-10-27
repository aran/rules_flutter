// Makes `counter` patchable in a running app: every call goes through
// `hot_patch_router.h`, which a patch of `counter.c` can redirect.
//
// The count lives here, in the image the app launched, and nowhere else: every
// call hands it to whichever body is current, so a patch carries on from the
// count the launched code left, and every asset id this library serves keeps
// sharing it.

#include "counter_body.h"

#define ROUTED_BODY counter_bump_body
#define ROUTED_BODY_TYPE counter_bump_body_fn
typedef int32_t (*ROUTED_BODY_TYPE)(struct counter_state *);
#include "hot_patch_router.h"

static struct counter_state state;

FFI_EXAMPLE_EXPORT int32_t counter_bump(void) {
    return routed_body(&state);
}
