#ifndef NATIVE_ADD_H
#define NATIVE_ADD_H

#include <stdint.h>

// MSVC exports nothing by default; ELF/Mach-O export everything visible.
#ifdef _WIN32
#define NATIVE_ADD_EXPORT __declspec(dllexport)
#else
#define NATIVE_ADD_EXPORT __attribute__((visibility("default")))
#endif

NATIVE_ADD_EXPORT int32_t native_add(int32_t a, int32_t b);

#endif
