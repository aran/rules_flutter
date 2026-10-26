// The routing that makes a fixture library patchable in a running app — the
// smallest thing that honours `flutter_native_library.hot_patch`, written by
// hand in C, and shared by every library here that a patch can reach.
//
// Every call to ROUTED goes through a pointer that starts at this library's own
// ROUTED_BODY. `flutter_hot_patch_apply` loads a patch — a whole second build
// of the body's source — and points the call at the patch's ROUTED_BODY. A
// toolchain that builds patches for real (per-function, reaching the running
// library's state) does far more; the contract with the dev tool is the same.
//
// Include it after declaring both functions and defining ROUTED and
// ROUTED_BODY to their names.

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#define ROUTER_NAME(x) #x
#define ROUTER_SYMBOL(x) ROUTER_NAME(x)

static int32_t (*routed_impl)(int32_t, int32_t) = ROUTED_BODY;

FFI_EXAMPLE_EXPORT int32_t ROUTED(int32_t a, int32_t b) {
    return routed_impl(a, b);
}

FFI_EXAMPLE_EXPORT int32_t flutter_hot_patch_apply(
    const char *patch_path, char *message, size_t message_capacity) {
    // No patch: the edit was undone, so calls go back to the launched code.
    if (patch_path == NULL) {
        routed_impl = ROUTED_BODY;
        return 0;
    }
#ifdef _WIN32
    HMODULE patch = LoadLibraryA(patch_path);
    if (patch == NULL) {
        snprintf(message, message_capacity, "LoadLibrary failed: error %lu",
                 GetLastError());
        return 1;
    }
    void *body = (void *)GetProcAddress(patch, ROUTER_SYMBOL(ROUTED_BODY));
#else
    void *patch = dlopen(patch_path, RTLD_NOW | RTLD_LOCAL);
    if (patch == NULL) {
        snprintf(message, message_capacity, "%s", dlerror());
        return 1;
    }
    void *body = dlsym(patch, ROUTER_SYMBOL(ROUTED_BODY));
#endif
    if (body == NULL) {
        snprintf(message, message_capacity, "%s exports no %s", patch_path,
                 ROUTER_SYMBOL(ROUTED_BODY));
        return 2;
    }
    routed_impl = (int32_t (*)(int32_t, int32_t))body;
    return 0;
}

FFI_EXAMPLE_EXPORT uint32_t flutter_hot_patch_abi(void) {
    return 1;
}
