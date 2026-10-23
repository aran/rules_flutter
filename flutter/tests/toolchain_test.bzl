"""Unit tests for engine helpers and provider definitions."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:providers.bzl", "FlutterSdkInfo", "resolve_exec_dart", "resolve_exec_dart_vm", "resolve_flutter_sdk_info")
load("//flutter/private:common.bzl", "KERNEL_COMPILE_ATTRS", "flutter_compile_kernel")
load("//flutter/private:engine_helpers.bzl", "dart_binary_name", "dartaotruntime_binary_name", "engine_arch_for_os", "platform_to_arch", "platform_to_os")
load("//flutter/private:flutter_kernel_module.bzl", "find_flutter_kernel_module_tools", "is_same_sdk")

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
    runtime_files = depset(["exec_runtime_file"])
    with_exec_tc = struct(
        toolchains = {
            "@rules_flutter//flutter:toolchain_type": struct(flutter_sdk_info = raw),
            "@rules_dart//dart:exec_tools_toolchain_type": struct(
                dart_sdk_info = struct(
                    dart = "exec_dart_bin",
                    runtime_files = runtime_files,
                ),
            ),
        },
    )
    asserts.equals(env, "exec_dart_bin", resolve_exec_dart(with_exec_tc, raw))
    asserts.equals(env, "exec_dart_bin", resolve_exec_dart(with_exec_tc))
    dart_exe, vm_files = resolve_exec_dart_vm(with_exec_tc, raw)
    asserts.equals(env, "exec_dart_bin", dart_exe)
    asserts.equals(env, ["exec_runtime_file"], vm_files.to_list())
    return unittest.end(env)

def _is_same_sdk_and_find_tools_test_impl(ctx):
    env = unittest.begin(ctx)

    flutter_dart = struct(path = "external/flutter_linux/dart-sdk/bin/dart", basename = "dart")
    flutter_aot = struct(path = "external/flutter_linux/dart-sdk/bin/dartaotruntime", basename = "dartaotruntime")
    flutter_dartvm = struct(path = "external/flutter_linux/dart-sdk/bin/dartvm", basename = "dartvm")
    flutter_kw = struct(path = "external/flutter_linux/dart-sdk/bin/snapshots/kernel_worker_aot.dart.snapshot")
    flutter_libs = struct(path = "external/flutter_linux/dart-sdk/lib/libraries.json")

    rules_dart_bin = struct(path = "external/dart_sdk_linux/bin/dart", basename = "dart")
    rules_dart_aot = struct(path = "external/dart_sdk_linux/bin/dartaotruntime", basename = "dartaotruntime")
    rules_dart_vm = struct(path = "external/dart_sdk_linux/bin/dartvm", basename = "dartvm")
    rules_dart_kw = struct(path = "external/dart_sdk_linux/bin/snapshots/kernel_worker_aot.dart.snapshot")
    rules_dart_libs = struct(path = "external/dart_sdk_linux/lib/libraries.json")

    flutter_info = FlutterSdkInfo(
        version = "3.41.2",
        engine_revision = "abc123",
        dart = flutter_dart,
        dartaotruntime = flutter_aot,
        gen_snapshot = None,
        flutter_tester = None,
        frontend_server = "frontend_server_snap",
        platform_kernel_dill = "flutter_platform_strong.dill",
        platform_kernel_dill_product = None,
        patched_sdk = "patched_sdk_target",
        icu_data = "icudtl.dat",
        tool_files = depset([flutter_dart, flutter_aot, flutter_dartvm, flutter_kw, flutter_libs]),
        dart_vm_files = depset([flutter_dart, flutter_dartvm]),
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

    matching_exec_tools = struct(
        dart = flutter_dart,
        dartvm = flutter_dartvm,
        runtime_files = depset([flutter_dart, flutter_dartvm]),
        dartaotruntime = flutter_aot,
        kernel_worker = flutter_kw,
        platform_dill = "vm_platform_strong.dill",
        libraries_json = flutter_libs,
        version = "3.13.4",
    )
    mismatched_exec_tools = struct(
        dart = rules_dart_bin,
        dartvm = rules_dart_vm,
        runtime_files = depset([rules_dart_bin, rules_dart_vm]),
        dartaotruntime = rules_dart_aot,
        kernel_worker = rules_dart_kw,
        platform_dill = "rules_dart_vm_platform_strong.dill",
        libraries_json = rules_dart_libs,
        version = "3.13.5",
    )

    asserts.true(env, is_same_sdk(matching_exec_tools, flutter_info), "matching dartaotruntime should be same SDK")
    asserts.false(env, is_same_sdk(mismatched_exec_tools, flutter_info), "different dartaotruntime should not be same SDK")
    asserts.false(env, is_same_sdk(None, flutter_info), "None exec_tools should not be same SDK")
    asserts.false(env, is_same_sdk(matching_exec_tools, None), "None flutter_sdk_info should not be same SDK")

    # Fallback to version comparison when executable files are absent.
    asserts.true(
        env,
        is_same_sdk(struct(version = "3.13.4"), struct(version = "3.13.4")),
        "matching version strings should be same SDK when executables are absent",
    )
    asserts.false(
        env,
        is_same_sdk(struct(version = "3.13.5"), struct(version = "3.13.4")),
        "different version strings should not be same SDK",
    )

    # When exec_tools matches flutter_info, find_flutter_kernel_module_tools returns exec_tools unchanged.
    same_result = find_flutter_kernel_module_tools(flutter_info, matching_exec_tools)
    asserts.equals(env, matching_exec_tools, same_result)

    # When @rules_dart's toolchain resolved first (mismatched_exec_tools),
    # find_flutter_kernel_module_tools selects Flutter's dartaotruntime, kernel_worker,
    # platform_dill, and libraries_json while keeping exec_tools' outer VM for kernel_module.dill.
    selected = find_flutter_kernel_module_tools(flutter_info, mismatched_exec_tools)
    asserts.true(env, selected != None, "should select Flutter SDK kernel module tools on mismatch")
    asserts.true(env, is_same_sdk(selected, flutter_info), "selected tools must match flutter_info SDK")
    asserts.equals(env, flutter_aot, selected.dartaotruntime)
    asserts.equals(env, flutter_kw, selected.kernel_worker)
    asserts.equals(env, "flutter_platform_strong.dill", selected.platform_dill)
    asserts.equals(env, flutter_libs, selected.libraries_json)
    asserts.equals(env, rules_dart_bin, selected.dart)
    asserts.equals(env, rules_dart_vm, selected.dartvm)
    asserts.equals(env, "3.13.5", selected.version)

    # If flutter_info lacks kernel_worker in tool_files, returns None rather than silently using mismatched tools.
    incomplete_flutter_info = FlutterSdkInfo(
        version = "3.41.2",
        engine_revision = "abc123",
        dart = flutter_dart,
        dartaotruntime = flutter_aot,
        gen_snapshot = None,
        flutter_tester = None,
        frontend_server = "frontend_server_snap",
        platform_kernel_dill = "flutter_platform_strong.dill",
        platform_kernel_dill_product = None,
        patched_sdk = "patched_sdk_target",
        icu_data = "icudtl.dat",
        tool_files = depset([flutter_dart, flutter_aot]),
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
    asserts.equals(env, None, find_flutter_kernel_module_tools(incomplete_flutter_info, mismatched_exec_tools))
    return unittest.end(env)

def _missing_exec_dart_rule_impl(ctx):
    resolve_exec_dart(ctx)
    return [DefaultInfo()]

_missing_exec_dart_rule = rule(
    implementation = _missing_exec_dart_rule_impl,
    toolchains = [],
)

def _missing_exec_dart_vm_rule_impl(ctx):
    resolve_exec_dart_vm(ctx)
    return [DefaultInfo()]

_missing_exec_dart_vm_rule = rule(
    implementation = _missing_exec_dart_vm_rule_impl,
    toolchains = [],
)

def _unresolved_exec_dart_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Unresolved @rules_dart//dart:exec_tools_toolchain_type")
    return analysistest.end(env)

_unresolved_exec_dart_failure_test = analysistest.make(
    _unresolved_exec_dart_failure_test_impl,
    expect_failure = True,
)

def _missing_product_dill_rule_impl(ctx):
    info = resolve_flutter_sdk_info(ctx)
    no_product_dill = FlutterSdkInfo(
        version = info.version,
        engine_revision = info.engine_revision,
        dart = info.dart,
        dartaotruntime = info.dartaotruntime,
        gen_snapshot = info.gen_snapshot,
        flutter_tester = info.flutter_tester,
        frontend_server = info.frontend_server,
        platform_kernel_dill = info.platform_kernel_dill,
        platform_kernel_dill_product = None,
        patched_sdk = info.patched_sdk,
        icu_data = info.icu_data,
        tool_files = info.tool_files,
        dart_vm_files = info.dart_vm_files,
        dart_pub_files = info.dart_pub_files,
        dart2wasm_files = info.dart2wasm_files,
        dart2js_files = info.dart2js_files,
        engine_library = info.engine_library,
        const_finder = info.const_finder,
        font_subset = info.font_subset,
        impellerc = info.impellerc,
        shader_lib = info.shader_lib,
        material_icons_font = info.material_icons_font,
        vm_isolate_snapshot = info.vm_isolate_snapshot,
        isolate_snapshot = info.isolate_snapshot,
        target_os = info.target_os,
        target_arch = info.target_arch,
        linux_sysroot = info.linux_sysroot,
    )
    kernel_dill = flutter_compile_kernel(ctx, no_product_dill, aot = True).kernel_dill
    return [DefaultInfo(files = depset([kernel_dill]))]

_missing_product_dill_rule = rule(
    implementation = _missing_product_dill_rule_impl,
    attrs = KERNEL_COMPILE_ATTRS,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_flutter//flutter/private:product_tools_toolchain_type", mandatory = False),
    ],
)

def _unresolved_product_dill_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Unresolved @rules_flutter//flutter:product_tools_toolchain_type")
    return analysistest.end(env)

_unresolved_product_dill_failure_test = analysistest.make(
    _unresolved_product_dill_failure_test_impl,
    expect_failure = True,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:profile")): False,
    },
)

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

_PrimaryToolchainProbeInfo = provider(
    doc = "Probe provider for primary toolchain analysis tests.",
    fields = ["sdk_info", "gen_snapshot_var", "is_linux"],
)

def _primary_toolchain_probe_impl(ctx):
    sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    is_linux = ctx.target_platform_has_constraint(
        ctx.attr._linux_constraint[platform_common.ConstraintValueInfo],
    )
    return [
        _PrimaryToolchainProbeInfo(
            sdk_info = sdk_info,
            gen_snapshot_var = ctx.expand_make_variables("test", "$(GEN_SNAPSHOT)", {}),
            is_linux = is_linux,
        ),
    ]

_primary_toolchain_probe = rule(
    implementation = _primary_toolchain_probe_impl,
    attrs = {
        "_linux_constraint": attr.label(default = "@platforms//os:linux"),
    },
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
)

def _primary_toolchain_host_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    probe = tut[_PrimaryToolchainProbeInfo]
    sdk_info = probe.sdk_info

    asserts.true(env, sdk_info.gen_snapshot != None, "Expected primary toolchain gen_snapshot to be populated")
    asserts.true(env, sdk_info.const_finder != None, "Expected primary toolchain const_finder to be populated")
    asserts.true(env, sdk_info.font_subset != None, "Expected primary toolchain font_subset to be populated")
    asserts.true(env, sdk_info.platform_kernel_dill_product != None, "Expected primary toolchain platform_kernel_dill_product to be populated")
    asserts.true(env, sdk_info.material_icons_font != None, "Expected primary toolchain material_icons_font to be populated")
    asserts.true(env, sdk_info.engine_library != None, "Expected primary toolchain engine_library to be populated on desktop host")
    if probe.is_linux:
        asserts.true(env, sdk_info.linux_sysroot != None, "Expected primary toolchain linux_sysroot to be populated on Linux host")
    if sdk_info.gen_snapshot != None:
        asserts.equals(env, sdk_info.gen_snapshot.path, probe.gen_snapshot_var, "Expected $(GEN_SNAPSHOT) to expand to gen_snapshot path")
    return analysistest.end(env)

_primary_toolchain_host_test = analysistest.make(_primary_toolchain_host_test_impl)

def _primary_toolchain_android_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    probe = tut[_PrimaryToolchainProbeInfo]
    sdk_info = probe.sdk_info

    asserts.true(env, sdk_info.gen_snapshot != None, "Expected Android cross toolchain gen_snapshot to be populated")
    asserts.true(env, sdk_info.const_finder != None, "Expected Android cross toolchain const_finder to be populated")
    asserts.true(env, sdk_info.font_subset != None, "Expected Android cross toolchain font_subset to be populated")
    asserts.true(env, sdk_info.platform_kernel_dill_product != None, "Expected Android cross toolchain platform_kernel_dill_product to be populated")
    asserts.true(env, sdk_info.material_icons_font != None, "Expected Android cross toolchain material_icons_font to be populated")
    if sdk_info.gen_snapshot != None:
        asserts.equals(env, sdk_info.gen_snapshot.path, probe.gen_snapshot_var, "Expected $(GEN_SNAPSHOT) to expand to Android gen_snapshot path")
    return analysistest.end(env)

_primary_toolchain_android_test = analysistest.make(
    _primary_toolchain_android_test_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label("//flutter/platforms:android_arm64")),
    },
)

_t0_test = unittest.make(_provider_exists_test_impl)
_t1_test = unittest.make(_dart_binary_name_test_impl)
_t2_test = unittest.make(_platform_mapping_test_impl)
_t3_test = unittest.make(_engine_arch_for_os_test_impl)
_t4_test = unittest.make(_resolve_flutter_sdk_info_test_impl)
_t5_test = unittest.make(_resolve_exec_dart_test_impl)
_t6_test = unittest.make(_is_same_sdk_and_find_tools_test_impl)

def toolchain_test_suite(name):
    """Test suite for Flutter toolchain resolution and helper functions.

    Args:
      name: Base name for the test suite targets.
    """
    _primary_toolchain_probe(
        name = name + "_primary_probe",
        tags = ["manual"],
    )
    _primary_toolchain_host_test(
        name = name + "_primary_host_test",
        target_under_test = ":" + name + "_primary_probe",
    )
    _primary_toolchain_android_test(
        name = name + "_primary_android_test",
        target_under_test = ":" + name + "_primary_probe",
    )
    _missing_exec_dart_rule(
        name = name + "_missing_exec_dart_fixture",
        tags = ["manual"],
    )
    _missing_exec_dart_vm_rule(
        name = name + "_missing_exec_dart_vm_fixture",
        tags = ["manual"],
    )
    _unresolved_exec_dart_failure_test(
        name = name + "_unresolved_exec_dart_test",
        target_under_test = ":" + name + "_missing_exec_dart_fixture",
    )
    _unresolved_exec_dart_failure_test(
        name = name + "_unresolved_exec_dart_vm_test",
        target_under_test = ":" + name + "_missing_exec_dart_vm_fixture",
    )
    _missing_product_dill_rule(
        name = name + "_missing_product_dill_fixture",
        package_name = "toolchain_fixture",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
    )
    _unresolved_product_dill_failure_test(
        name = name + "_unresolved_product_dill_test",
        target_under_test = ":" + name + "_missing_product_dill_fixture",
    )
    unittest.suite(
        name + "_unit",
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_primary_host_test",
            ":" + name + "_primary_android_test",
            ":" + name + "_unresolved_exec_dart_test",
            ":" + name + "_unresolved_exec_dart_vm_test",
            ":" + name + "_unresolved_product_dill_test",
        ],
    )
