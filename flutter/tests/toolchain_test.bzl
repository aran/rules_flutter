"""Unit tests for engine helpers and provider definitions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter:providers.bzl", "FlutterSdkInfo", "resolve_exec_dart", "resolve_flutter_sdk_info")
load("//flutter/private:engine_helpers.bzl", "dart_binary_name", "dartaotruntime_binary_name", "engine_arch_for_os", "platform_to_arch", "platform_to_os")

def _provider_exists_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, FlutterSdkInfo != None, "FlutterSdkInfo should be defined")
    asserts.true(
        env,
        type(FlutterSdkInfo) == "Provider",
        "FlutterSdkInfo should be a Provider, got {}".format(type(FlutterSdkInfo)),
    )
    return unittest.end(env)

def _resolve_flutter_sdk_info_test_impl(ctx):
    env = unittest.begin(ctx)
    raw = FlutterSdkInfo(
        version = "3.41.2",
        engine_revision = "abc123",
        dart = "dart_bin",
        dartaotruntime = "dartaotruntime_bin",
        gen_snapshot = None,
        flutter_tester = "flutter_tester_bin",
        frontend_server = "frontend_server_snap",
        platform_kernel_dill = "platform_strong.dill",
        platform_kernel_dill_product = None,
        patched_sdk = "patched_sdk_target",
        icu_data = "icudtl.dat",
        tool_files = depset(["all"]),
        dart_vm_files = depset(["vm"]),
        dart_pub_files = depset(["pub"]),
        dart2wasm_files = depset(["wasm"]),
        dart2js_files = depset(["js"]),
        engine_library = None,
        const_finder = None,
        font_subset = None,
        impellerc = "impellerc_bin",
        shader_lib = ["shader_lib"],
        material_icons_font = None,
        vm_isolate_snapshot = "vm_snap",
        isolate_snapshot = "iso_snap",
        target_os = "linux",
        target_arch = "x64",
        linux_sysroot = None,
    )
    mock_ctx = struct(
        toolchains = {
            "@rules_flutter//flutter:toolchain_type": struct(flutter_sdk_info = raw),
            "@rules_flutter//flutter/private:product_tools_toolchain_type": struct(
                platform_kernel_dill_product = "product.dill",
                const_finder = "const_finder.snap",
                font_subset = "font-subset",
            ),
            "@rules_flutter//flutter/private:aot_toolchain_type": struct(
                gen_snapshot = "gen_snapshot_bin",
            ),
            "@rules_flutter//flutter/private:desktop_engine_toolchain_type": struct(
                engine_library = "libflutter_linux_gtk.so",
                linux_sysroot = "sysroot_files",
            ),
            "@rules_flutter//flutter/private:material_icons_toolchain_type": struct(
                material_icons_font = "MaterialIcons-Regular.otf",
            ),
        },
    )
    merged = resolve_flutter_sdk_info(mock_ctx)
    asserts.equals(env, sorted(dir(raw)), sorted(dir(merged)))
    asserts.equals(env, ["vm"], merged.dart_vm_files.to_list())
    asserts.equals(env, ["pub"], merged.dart_pub_files.to_list())
    asserts.equals(env, ["wasm"], merged.dart2wasm_files.to_list())
    asserts.equals(env, ["js"], merged.dart2js_files.to_list())
    asserts.equals(env, "gen_snapshot_bin", merged.gen_snapshot)
    asserts.equals(env, "product.dill", merged.platform_kernel_dill_product)
    asserts.equals(env, "const_finder.snap", merged.const_finder)
    asserts.equals(env, "font-subset", merged.font_subset)
    asserts.equals(env, "libflutter_linux_gtk.so", merged.engine_library)
    asserts.equals(env, "sysroot_files", merged.linux_sysroot)
    asserts.equals(env, "MaterialIcons-Regular.otf", merged.material_icons_font)

    mock_ctx_font_subset_tc = struct(
        toolchains = {
            "@rules_flutter//flutter:toolchain_type": struct(flutter_sdk_info = raw),
            "@rules_flutter//flutter/private:product_tools_toolchain_type": struct(
                platform_kernel_dill_product = "product.dill",
                const_finder = None,
                font_subset = None,
            ),
            "@rules_flutter//flutter/private:font_subset_toolchain_type": struct(
                const_finder = "lazy_const_finder.snap",
                font_subset = "lazy_font_subset",
            ),
        },
    )
    merged_lazy = resolve_flutter_sdk_info(mock_ctx_font_subset_tc)
    asserts.equals(env, "product.dill", merged_lazy.platform_kernel_dill_product)
    asserts.equals(env, "lazy_const_finder.snap", merged_lazy.const_finder)
    asserts.equals(env, "lazy_font_subset", merged_lazy.font_subset)
    return unittest.end(env)

def _resolve_exec_dart_test_impl(ctx):
    env = unittest.begin(ctx)
    raw = FlutterSdkInfo(
        version = "3.41.2",
        engine_revision = "abc123",
        dart = "flutter_dart_bin",
        dartaotruntime = "dartaotruntime_bin",
        gen_snapshot = None,
        flutter_tester = None,
        frontend_server = "frontend_server_snap",
        platform_kernel_dill = "platform_strong.dill",
        platform_kernel_dill_product = None,
        patched_sdk = "patched_sdk_target",
        icu_data = "icudtl.dat",
        tool_files = depset([]),
        dart_vm_files = depset([]),
        dart_pub_files = depset([]),
        dart2wasm_files = depset([]),
        dart2js_files = depset([]),
        engine_library = None,
        const_finder = None,
        font_subset = None,
        impellerc = None,
        shader_lib = [],
        material_icons_font = None,
        vm_isolate_snapshot = None,
        isolate_snapshot = None,
        target_os = "linux",
        target_arch = "x64",
        linux_sysroot = None,
    )
    with_exec_tc = struct(
        toolchains = {
            "@rules_flutter//flutter:toolchain_type": struct(flutter_sdk_info = raw),
            "@rules_dart//dart:exec_tools_toolchain_type": struct(
                dart_sdk_info = struct(dart = "exec_dart_bin"),
            ),
        },
    )
    asserts.equals(env, "exec_dart_bin", resolve_exec_dart(with_exec_tc, raw))

    with_none_exec_tc = struct(
        toolchains = {
            "@rules_flutter//flutter:toolchain_type": struct(flutter_sdk_info = raw),
            "@rules_dart//dart:exec_tools_toolchain_type": None,
        },
    )
    asserts.equals(env, "flutter_dart_bin", resolve_exec_dart(with_none_exec_tc, raw))

    without_exec_tc = struct(
        toolchains = {
            "@rules_flutter//flutter:toolchain_type": struct(flutter_sdk_info = raw),
        },
    )
    asserts.equals(env, "flutter_dart_bin", resolve_exec_dart(without_exec_tc))
    return unittest.end(env)

def _dart_binary_name_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "dart", dart_binary_name("darwin-arm64"))
    asserts.equals(env, "dart", dart_binary_name("linux-x64"))
    asserts.equals(env, "dart.exe", dart_binary_name("windows-x64"))
    asserts.equals(env, "dartaotruntime", dartaotruntime_binary_name("darwin-arm64"))
    asserts.equals(env, "dartaotruntime.exe", dartaotruntime_binary_name("windows-x64"))
    return unittest.end(env)

def _platform_mapping_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "macos", platform_to_os("darwin-arm64"))
    asserts.equals(env, "linux", platform_to_os("linux-x64"))
    asserts.equals(env, "windows", platform_to_os("windows-x64"))
    asserts.equals(env, "arm64", platform_to_arch("darwin-arm64"))
    asserts.equals(env, "x64", platform_to_arch("linux-x64"))
    asserts.equals(env, "", platform_to_arch("nohyphen"))
    return unittest.end(env)

def _engine_arch_for_os_test_impl(ctx):
    env = unittest.begin(ctx)

    # macOS always overrides to x64.
    asserts.equals(env, "x64", engine_arch_for_os("macos", "arm64"))
    asserts.equals(env, "x64", engine_arch_for_os("macos", "x64"))

    # Other OSes pass through.
    asserts.equals(env, "x64", engine_arch_for_os("linux", "x64"))
    asserts.equals(env, "arm64", engine_arch_for_os("linux", "arm64"))
    asserts.equals(env, "x64", engine_arch_for_os("windows", "x64"))
    return unittest.end(env)

_t0_test = unittest.make(_provider_exists_test_impl)
_t1_test = unittest.make(_dart_binary_name_test_impl)
_t2_test = unittest.make(_platform_mapping_test_impl)
_t3_test = unittest.make(_engine_arch_for_os_test_impl)
_t4_test = unittest.make(_resolve_flutter_sdk_info_test_impl)
_t5_test = unittest.make(_resolve_exec_dart_test_impl)

def toolchain_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test)
