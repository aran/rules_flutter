#ifndef SUB_H
#define SUB_H

#include <stdint.h>

// The same export macro as `mul.h`, which `c_patch_tool` reads declarations by.
#ifndef FFI_EXAMPLE_EXPORT
#ifdef _WIN32
#define FFI_EXAMPLE_EXPORT __declspec(dllexport)
#else
#define FFI_EXAMPLE_EXPORT __attribute__((visibility("default")))
#endif
#endif

FFI_EXAMPLE_EXPORT int32_t sub(int32_t a, int32_t b);

#endif
