#include "counter.h"

static int32_t count = 0;

int32_t counter_bump(void) {
    return ++count;
}
