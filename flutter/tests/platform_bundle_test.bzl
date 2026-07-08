"""Unit tests for platform bundle config construction.

Tests the pure helper functions used by linux, android, and windows bundle rules.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:common.bzl", "ANDROID_ABIS", "android_elf_machine_for_abi", "android_platform_for_abi", "compute_android_jni_path", "compute_desktop_bundle_copies")

# -- compute_desktop_bundle_copies tests --

def _linux_debug_copies_test_impl(ctx):
    """Debug Linux build places kernel_dill at data/app.dill."""
    env = unittest.begin(ctx)

    copies = compute_desktop_bundle_copies(
        is_debug = True,
        kernel_dill_path = "/out/app.dill",
        aot_output_path = None,
        aot_dst = "lib/libapp.so",
        icu_data_path = "/sdk/icudtl.dat",
        engine_basenames = [("/eng/libflutter.so", "libflutter.so")],
        native_basenames = [],
    )

    # icudtl + kernel_dill + engine = 3
    asserts.equals(env, 3, len(copies))
    asserts.equals(env, {"src": "/sdk/icudtl.dat", "dst": "data/icudtl.dat"}, copies[0])
    asserts.equals(env, {"src": "/out/app.dill", "dst": "data/flutter_assets/kernel_blob.bin"}, copies[1])
    asserts.equals(env, {"src": "/eng/libflutter.so", "dst": "lib/libflutter.so"}, copies[2])

    return unittest.end(env)

def _linux_release_copies_test_impl(ctx):
    """Release Linux build places aot_output at lib/libapp.so."""
    env = unittest.begin(ctx)

    copies = compute_desktop_bundle_copies(
        is_debug = False,
        kernel_dill_path = None,
        aot_output_path = "/out/libapp.so",
        aot_dst = "lib/libapp.so",
        icu_data_path = "/sdk/icudtl.dat",
        engine_basenames = [("/eng/libflutter.so", "libflutter.so")],
        native_basenames = [("/ffi/libfoo.so", "libfoo.so")],
    )

    # icudtl + aot + engine + native = 4
    asserts.equals(env, 4, len(copies))
    asserts.equals(env, {"src": "/out/libapp.so", "dst": "lib/libapp.so"}, copies[1])
    asserts.equals(env, {"src": "/ffi/libfoo.so", "dst": "lib/libfoo.so"}, copies[3])

    return unittest.end(env)

def _windows_release_copies_test_impl(ctx):
    """Release Windows build places aot_output at app.so, engine at root."""
    env = unittest.begin(ctx)

    copies = compute_desktop_bundle_copies(
        is_debug = False,
        kernel_dill_path = None,
        aot_output_path = "/out/app.so",
        aot_dst = "app.so",
        icu_data_path = "/sdk/icudtl.dat",
        engine_basenames = [("/eng/flutter_windows.dll", "flutter_windows.dll")],
        native_basenames = [],
        engine_dst_prefix = "",
    )

    asserts.equals(env, 3, len(copies))
    asserts.equals(env, {"src": "/out/app.so", "dst": "app.so"}, copies[1])

    # Engine DLL at root (no lib/ prefix).
    asserts.equals(env, {"src": "/eng/flutter_windows.dll", "dst": "flutter_windows.dll"}, copies[2])

    return unittest.end(env)

def _windows_debug_copies_test_impl(ctx):
    """Debug Windows build places kernel_dill at data/app.dill."""
    env = unittest.begin(ctx)

    copies = compute_desktop_bundle_copies(
        is_debug = True,
        kernel_dill_path = "/out/app.dill",
        aot_output_path = None,
        aot_dst = "app.so",
        icu_data_path = "/sdk/icudtl.dat",
        engine_basenames = [],
        native_basenames = [],
        engine_dst_prefix = "",
    )

    asserts.equals(env, 2, len(copies))
    asserts.equals(env, {"src": "/out/app.dill", "dst": "data/flutter_assets/kernel_blob.bin"}, copies[1])

    return unittest.end(env)

def _no_artifacts_copies_test_impl(ctx):
    """When neither kernel nor AOT is provided, only icudtl is copied."""
    env = unittest.begin(ctx)

    copies = compute_desktop_bundle_copies(
        is_debug = False,
        kernel_dill_path = None,
        aot_output_path = None,
        aot_dst = "lib/libapp.so",
        icu_data_path = "/sdk/icudtl.dat",
        engine_basenames = [],
        native_basenames = [],
    )

    asserts.equals(env, 1, len(copies))
    asserts.equals(env, "data/icudtl.dat", copies[0]["dst"])

    return unittest.end(env)

# -- compute_android_jni_path tests --

def _android_jni_path_arm64_test_impl(ctx):
    """Default ABI arm64-v8a produces correct JNI path."""
    env = unittest.begin(ctx)

    path = compute_android_jni_path("arm64-v8a", "libapp.so")
    asserts.equals(env, "jni/arm64-v8a/libapp.so", path)

    return unittest.end(env)

def _android_jni_path_x86_64_test_impl(ctx):
    """x86_64 ABI produces correct JNI path."""
    env = unittest.begin(ctx)

    path = compute_android_jni_path("x86_64", "libapp.so")
    asserts.equals(env, "jni/x86_64/libapp.so", path)

    return unittest.end(env)

def _android_jni_path_custom_basename_test_impl(ctx):
    """Custom basename (FFI lib) works correctly."""
    env = unittest.begin(ctx)

    path = compute_android_jni_path("arm64-v8a", "libfoo.so")
    asserts.equals(env, "jni/arm64-v8a/libfoo.so", path)

    return unittest.end(env)

# -- Android ABI table tests --

def _android_abi_platform_test_impl(ctx):
    """Each ABI maps to its //flutter/platforms target."""
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        Label("//flutter/platforms:android_arm64"),
        android_platform_for_abi("arm64-v8a"),
    )
    asserts.equals(
        env,
        Label("//flutter/platforms:android_x64"),
        android_platform_for_abi("x86_64"),
    )

    return unittest.end(env)

def _android_abi_elf_machine_test_impl(ctx):
    """Each ABI maps to its ELF e_machine value."""
    env = unittest.begin(ctx)

    asserts.equals(env, 183, android_elf_machine_for_abi("arm64-v8a"))  # EM_AARCH64
    asserts.equals(env, 62, android_elf_machine_for_abi("x86_64"))  # EM_X86_64

    return unittest.end(env)

def _android_abi_table_complete_test_impl(ctx):
    """The ABI table covers exactly the supported cross-compile ABIs."""
    env = unittest.begin(ctx)

    asserts.equals(env, ["arm64-v8a", "x86_64"], sorted(ANDROID_ABIS.keys()))

    return unittest.end(env)

_t0_test = unittest.make(_linux_debug_copies_test_impl)
_t1_test = unittest.make(_linux_release_copies_test_impl)
_t2_test = unittest.make(_windows_release_copies_test_impl)
_t3_test = unittest.make(_windows_debug_copies_test_impl)
_t4_test = unittest.make(_no_artifacts_copies_test_impl)
_t5_test = unittest.make(_android_jni_path_arm64_test_impl)
_t6_test = unittest.make(_android_jni_path_x86_64_test_impl)
_t7_test = unittest.make(_android_jni_path_custom_basename_test_impl)
_t8_test = unittest.make(_android_abi_platform_test_impl)
_t9_test = unittest.make(_android_abi_elf_machine_test_impl)
_t10_test = unittest.make(_android_abi_table_complete_test_impl)

def platform_bundle_test_suite(name):
    unittest.suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
    )
