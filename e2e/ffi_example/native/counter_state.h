#ifndef COUNTER_STATE_H
#define COUNTER_STATE_H

#include <stdint.h>

// Everything the counter remembers between calls. The image the app launched
// holds the one instance (`counter_hot_patch.c`) and passes it to the body on
// every call, so the launched body and every patch of it share one count.
//
// A patch is built against this header and reads the launched instance through
// it, so a change here is a change to memory the running image laid out at
// launch: `c_patch_tool` answers it with a restart.
struct counter_state {
    int32_t count;
};

#endif
