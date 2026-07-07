#ifndef MUL_H
#define MUL_H

#include <stdint.h>

// MSVC exports nothing by default; ELF/Mach-O export everything visible.
// Same shape as the FFI_PLUGIN_EXPORT macro from `flutter create
// --template=plugin_ffi`.
#ifdef _WIN32
#define FFI_EXAMPLE_EXPORT __declspec(dllexport)
#else
#define FFI_EXAMPLE_EXPORT __attribute__((visibility("default")))
#endif

FFI_EXAMPLE_EXPORT int32_t mul(int32_t a, int32_t b);

#endif
