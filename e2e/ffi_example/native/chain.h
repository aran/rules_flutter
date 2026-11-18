#ifndef CHAIN_H
#define CHAIN_H

#include <stdint.h>

#ifdef _WIN32
#define CHAIN_EXPORT __declspec(dllexport)
#else
#define CHAIN_EXPORT __attribute__((visibility("default")))
#endif

// In `chain_base`, its own library.
CHAIN_EXPORT int32_t chain_base(int32_t a);

// In `chain_top`, which links `chain_base` and calls it.
CHAIN_EXPORT int32_t chain_top(int32_t a);

#endif
