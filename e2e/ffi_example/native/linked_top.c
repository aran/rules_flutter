#include "linked_pair.h"

// Reaches `linked_base` through the library it links, so the call returns
// only if the loader found that library beside this one.
int32_t linked_top(int32_t a) {
    return linked_base(a) * 2;
}
