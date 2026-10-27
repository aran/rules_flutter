#ifndef COUNTER_H
#define COUNTER_H

#include <stdint.h>

#ifndef COUNTER_EXPORT
#ifdef _WIN32
#define COUNTER_EXPORT __declspec(dllexport)
#else
#define COUNTER_EXPORT __attribute__((visibility("default")))
#endif
#endif

// Adds one to a count held in the library's static state and returns it. Each
// loaded image of the library keeps a count of its own.
COUNTER_EXPORT int32_t counter_bump(void);

#endif
