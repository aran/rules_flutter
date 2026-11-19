#ifndef LINKED_PAIR_H
#define LINKED_PAIR_H

#include <stdint.h>

#ifdef _WIN32
#define LINKED_PAIR_EXPORT __declspec(dllexport)
#else
#define LINKED_PAIR_EXPORT __attribute__((visibility("default")))
#endif

// In `linked_base`, its own library.
LINKED_PAIR_EXPORT int32_t linked_base(int32_t a);

// In `linked_top`, which links `linked_base` and calls it.
LINKED_PAIR_EXPORT int32_t linked_top(int32_t a);

#endif
