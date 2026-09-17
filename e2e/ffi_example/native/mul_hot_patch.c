// Makes `mul` patchable in a running app — the smallest library that honours
// `flutter_native_library.hot_patch`, written by hand in C.
//
// Every call goes through `mul_impl`, which starts at this library's own
// `mul_body`. `flutter_hot_patch_apply` loads a patch — a whole second build of
// `mul.c` — and points `mul_impl` at the patch's `mul_body`. A toolchain that
// builds patches for real (per-function, reaching the running library's state)
// does far more; the contract with the dev tool is the same.

#include <stddef.h>
#include <stdio.h>

#include "mul_body.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

static int32_t (*mul_impl)(int32_t, int32_t) = mul_body;

FFI_EXAMPLE_EXPORT int32_t mul(int32_t a, int32_t b) {
    return mul_impl(a, b);
}

FFI_EXAMPLE_EXPORT int32_t flutter_hot_patch_apply(
    const char *patch_path, char *message, size_t message_capacity) {
    // No patch: the edit was undone, so calls go back to the launched code.
    if (patch_path == NULL) {
        mul_impl = mul_body;
        return 0;
    }
#ifdef _WIN32
    HMODULE patch = LoadLibraryA(patch_path);
    if (patch == NULL) {
        snprintf(message, message_capacity, "LoadLibrary failed: error %lu",
                 GetLastError());
        return 1;
    }
    void *body = (void *)GetProcAddress(patch, "mul_body");
#else
    void *patch = dlopen(patch_path, RTLD_NOW | RTLD_LOCAL);
    if (patch == NULL) {
        snprintf(message, message_capacity, "%s", dlerror());
        return 1;
    }
    void *body = dlsym(patch, "mul_body");
#endif
    if (body == NULL) {
        snprintf(message, message_capacity, "%s exports no mul_body", patch_path);
        return 2;
    }
    mul_impl = (int32_t (*)(int32_t, int32_t))body;
    return 0;
}

FFI_EXAMPLE_EXPORT uint32_t flutter_hot_patch_abi(void) {
    return 1;
}
