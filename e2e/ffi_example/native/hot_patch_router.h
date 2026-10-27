// The routing that makes a fixture library patchable in a running app — the
// smallest thing that honours `flutter_native_library.hot_patch`, written by
// hand in C, and shared by every library here that a patch can reach.
//
// Every exported function the includer writes calls `routed_body`, a pointer
// that starts at this library's own ROUTED_BODY. `flutter_hot_patch_apply`
// loads a patch — a whole second build of the body's source — and points the
// call at the patch's ROUTED_BODY.
//
// A patch is a second image, so whatever static storage it defines is its own,
// starting fresh, and invisible to this one. A body that keeps state therefore
// owns none: the includer holds it, here, in the image the app launched, and
// passes it to the body on every call, so the launched body and every patch
// after it work on the same storage. The builder refuses a patch whose body
// defines state of its own, or whose state layout moved (see
// `tools/c_patch_tool.dart`). A toolchain that builds patches for real
// (per-function, reaching the running library's statics by address) does far
// more; the contract with the dev tool is the same.
//
// Include it after declaring the body and defining ROUTED_BODY to its name and
// ROUTED_BODY_TYPE to its pointer type.

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifdef _WIN32
#include <windows.h>
#define HOT_PATCH_EXPORT __declspec(dllexport)
#else
#include <dlfcn.h>
#define HOT_PATCH_EXPORT __attribute__((visibility("default")))
#endif

#define ROUTER_NAME(x) #x
#define ROUTER_SYMBOL(x) ROUTER_NAME(x)

static ROUTED_BODY_TYPE routed_body = ROUTED_BODY;

HOT_PATCH_EXPORT int32_t flutter_hot_patch_apply(
    const char *patch_path, char *message, size_t message_capacity) {
    // No patch: the edit was undone, so calls go back to the launched code.
    if (patch_path == NULL) {
        routed_body = ROUTED_BODY;
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
    routed_body = (ROUTED_BODY_TYPE)body;
    return 0;
}

HOT_PATCH_EXPORT uint32_t flutter_hot_patch_abi(void) {
    return 1;
}
