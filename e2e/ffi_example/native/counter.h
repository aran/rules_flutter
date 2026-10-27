#ifndef COUNTER_H
#define COUNTER_H

#include <stdint.h>

// The same export macro as `mul.h`, which `c_patch_tool` reads declarations by.
#ifndef FFI_EXAMPLE_EXPORT
#ifdef _WIN32
#define FFI_EXAMPLE_EXPORT __declspec(dllexport)
#else
#define FFI_EXAMPLE_EXPORT __attribute__((visibility("default")))
#endif
#endif

// Adds to a count held in the library's static state and returns it. Each
// loaded image of the library keeps a count of its own.
FFI_EXAMPLE_EXPORT int32_t counter_bump(void);

#endif
