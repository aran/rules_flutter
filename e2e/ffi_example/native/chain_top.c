#include "chain.h"

// Reaches `chain_base` through the library it links, so the call returns only
// if the loader found that library under the name this one records for it.
int32_t chain_top(int32_t a) {
    return chain_base(a) * 2;
}
