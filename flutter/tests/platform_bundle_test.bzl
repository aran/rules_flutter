"""Unit tests for platform bundle config construction.

Tests the pure helper functions used by linux, android, and windows bundle rules.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:common.bzl", "ANDROID_ABIS", "android_elf_machine_for_abi", "android_platform_for_abi", "compute_android_jni_path", "compute_desktop_bundle_copies")
load("//flutter/private:flutter_android_application.bzl", "flutter_android_bundle")
load("//flutter/private:flutter_android_registrant.bzl", "flutter_android_registrant")

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

    path = compute_android_jni_path("my_app", "arm64-v8a", "libapp.so")
    asserts.equals(env, "my_app_jni/arm64-v8a/libapp.so", path)

    return unittest.end(env)

def _android_jni_path_x86_64_test_impl(ctx):
    """x86_64 ABI produces correct JNI path."""
    env = unittest.begin(ctx)

    path = compute_android_jni_path("my_app", "x86_64", "libapp.so")
    asserts.equals(env, "my_app_jni/x86_64/libapp.so", path)

    return unittest.end(env)

def _android_jni_path_custom_basename_test_impl(ctx):
    """Custom basename (FFI lib) works correctly."""
    env = unittest.begin(ctx)

    path = compute_android_jni_path("my_app", "arm64-v8a", "libfoo.so")
    asserts.equals(env, "my_app_jni/arm64-v8a/libfoo.so", path)

    return unittest.end(env)

def _android_jni_path_scoped_per_target_test_impl(ctx):
    """Two targets in one package get distinct JNI paths.

    Regression guard: an unscoped `jni/<abi>/libapp.so` made two Android
    bundles in the same package conflicting actions, breaking
    `bazel build //...` for any package holding two apps.
    """
    env = unittest.begin(ctx)

    asserts.false(
        env,
        compute_android_jni_path("free", "arm64-v8a", "libapp.so") ==
        compute_android_jni_path("pro", "arm64-v8a", "libapp.so"),
    )

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

# -- Android platform transition tests --

def _fake_android_app_impl(ctx):
    if not ctx.attr.is_android:
        fail("Expected application to be analyzed in an Android target configuration")
    if ctx.attr.target_cpu != ctx.attr.expected_cpu:
        fail("Expected target_cpu %r, got %r" % (ctx.attr.expected_cpu, ctx.attr.target_cpu))
    plugin = struct(
        name = "test_android_plugin",
        platforms = {
            "android": {
                "package": "com.example.test_plugin",
                "pluginClass": "TestAndroidPlugin",
            },
        },
    )
    return [
        FlutterApplicationInfo(
            kernel_dill = None,
            aot_output = None,
            flutter_assets = None,
            native_libs = [],
            plugins = [plugin],
            bundled_code_assets = depset(),
        ),
    ]

_fake_android_app = rule(
    implementation = _fake_android_app_impl,
    attrs = {
        "is_android": attr.bool(mandatory = True),
        "target_cpu": attr.string(mandatory = True),
        "expected_cpu": attr.string(mandatory = True),
    },
)

def _android_registrant_transition_test_impl(ctx):
    """flutter_android_registrant transitions application to the target Android ABI platform."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    asserts.equals(env, 1, len(actions))
    asserts.true(
        env,
        "com.example.test_plugin.TestAndroidPlugin" in actions[0].content,
        "Expected GeneratedPluginRegistrant.java to register TestAndroidPlugin",
    )
    return analysistest.end(env)

_android_registrant_transition_test = analysistest.make(_android_registrant_transition_test_impl)

def _split_dynamic_mode_transition_impl(_settings, _attr):
    return {
        "assets_path": {"//command_line_option:dynamic_mode": "default"},
        "deps_path": {"//command_line_option:dynamic_mode": "off"},
    }

_split_dynamic_mode_transition = transition(
    implementation = _split_dynamic_mode_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:dynamic_mode"],
)

def _android_split_probe_impl(ctx):
    if len(ctx.attr.targets) != 1:
        fail("Expected dynamic_mode=default and dynamic_mode=off split arms to collapse to 1 configured target, got %d: %r" % (
            len(ctx.attr.targets),
            [t.files.to_list() for t in ctx.attr.targets],
        ))
    return [DefaultInfo(files = depset(ctx.files.targets))]

_android_split_probe = rule(
    implementation = _android_split_probe_impl,
    attrs = {
        "targets": attr.label_list(
            cfg = _split_dynamic_mode_transition,
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

def _android_single_config_across_dynamic_mode_test_impl(ctx):
    """Reaching Android targets via dynamic_mode=default and dynamic_mode=off produces one config."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, 1, len(target[DefaultInfo].files.to_list()))
    return analysistest.end(env)

_android_single_config_across_dynamic_mode_test = analysistest.make(
    _android_single_config_across_dynamic_mode_test_impl,
)

def _fake_android_bundle_app_impl(ctx):
    assets = ctx.actions.declare_directory(ctx.label.name + "_assets")
    ctx.actions.run(
        executable = ctx.executable._bundle_tool,
        arguments = [],
        outputs = [assets],
    )
    kernel = None
    if ctx.attr.with_kernel:
        kernel = ctx.actions.declare_file(ctx.label.name + ".dill")
        ctx.actions.write(kernel, "")
    aot = None
    if ctx.attr.with_aot:
        aot = ctx.actions.declare_file(ctx.label.name + "_libapp.so")
        ctx.actions.write(aot, "")
    return [
        FlutterApplicationInfo(
            kernel_dill = kernel,
            aot_output = aot,
            flutter_assets = assets,
            native_libs = [],
            plugins = [],
            bundled_code_assets = depset(),
        ),
    ]

_fake_android_bundle_app = rule(
    implementation = _fake_android_bundle_app_impl,
    attrs = {
        "with_kernel": attr.bool(default = False),
        "with_aot": attr.bool(default = False),
        "_bundle_tool": attr.label(
            default = Label("//flutter/private/tools:android_bundle"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def _android_bundle_debug_actions_test_impl(ctx):
    """Debug flutter_android_bundle registers Dart tool actions for debug assets and empty jar."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    by_mnemonic = {a.mnemonic: a for a in actions}
    asserts.true(env, "FlutterAndroidDebugAssets" in by_mnemonic)
    asserts.true(env, "FlutterEmptyNativeLibsJar" in by_mnemonic)

    debug_action = by_mnemonic["FlutterAndroidDebugAssets"]
    asserts.true(env, "debug-assets" in debug_action.argv)
    asserts.true(env, "--assets-dir" in debug_action.argv)
    asserts.true(env, "--output-dir" in debug_action.argv)
    asserts.true(env, "--kernel" in debug_action.argv)

    empty_jar_action = by_mnemonic["FlutterEmptyNativeLibsJar"]
    asserts.true(env, "empty-jar" in empty_jar_action.argv)
    asserts.true(env, "--output" in empty_jar_action.argv)
    return analysistest.end(env)

_android_bundle_debug_actions_test = analysistest.make(_android_bundle_debug_actions_test_impl)

def _android_bundle_release_actions_test_impl(ctx):
    """Release flutter_android_bundle registers Dart tool action for FlutterNativeLibsJar."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    by_mnemonic = {a.mnemonic: a for a in actions}
    asserts.true(env, "FlutterNativeLibsJar" in by_mnemonic)

    jar_action = by_mnemonic["FlutterNativeLibsJar"]
    asserts.true(env, "native-libs-jar" in jar_action.argv)
    asserts.true(env, "--abi" in jar_action.argv)
    asserts.true(env, "arm64-v8a" in jar_action.argv)
    asserts.true(env, "--machine" in jar_action.argv)
    asserts.true(env, "183" in jar_action.argv)
    return analysistest.end(env)

_android_bundle_release_actions_test = analysistest.make(_android_bundle_release_actions_test_impl)

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
_t11_test = unittest.make(_android_jni_path_scoped_per_target_test_impl)

def platform_bundle_test_suite(name):
    _fake_android_app(
        name = "_fake_app_arm64",
        is_android = select({
            "@platforms//os:android": True,
            "//conditions:default": False,
        }),
        target_cpu = select({
            "@platforms//cpu:arm64": "arm64",
            "@platforms//cpu:x86_64": "x86_64",
            "//conditions:default": "other",
        }),
        expected_cpu = "arm64",
        tags = ["manual"],
    )

    flutter_android_registrant(
        name = "_registrant_arm64_under_test",
        application = ":_fake_app_arm64",
        android_abi = "arm64-v8a",
        tags = ["manual"],
    )

    _android_registrant_transition_test(
        name = name + "_registrant_arm64_transition",
        target_under_test = ":_registrant_arm64_under_test",
    )

    _android_split_probe(
        name = "_split_dynamic_mode_probe",
        targets = [":_registrant_arm64_under_test"],
        tags = ["manual"],
    )

    _android_single_config_across_dynamic_mode_test(
        name = name + "_single_config_across_dynamic_mode",
        target_under_test = ":_split_dynamic_mode_probe",
    )

    _fake_android_app(
        name = "_fake_app_x64",
        is_android = select({
            "@platforms//os:android": True,
            "//conditions:default": False,
        }),
        target_cpu = select({
            "@platforms//cpu:arm64": "arm64",
            "@platforms//cpu:x86_64": "x86_64",
            "//conditions:default": "other",
        }),
        expected_cpu = "x86_64",
        tags = ["manual"],
    )

    flutter_android_registrant(
        name = "_registrant_x64_under_test",
        application = ":_fake_app_x64",
        android_abi = "x86_64",
        tags = ["manual"],
    )

    _android_registrant_transition_test(
        name = name + "_registrant_x64_transition",
        target_under_test = ":_registrant_x64_under_test",
    )

    _fake_android_bundle_app(
        name = "_fake_bundle_debug_app",
        with_kernel = True,
        tags = ["manual"],
    )

    flutter_android_bundle(
        name = "_bundle_debug_under_test",
        application = ":_fake_bundle_debug_app",
        android_abi = "arm64-v8a",
        tags = ["manual"],
    )

    _android_bundle_debug_actions_test(
        name = name + "_android_bundle_debug_actions",
        target_under_test = ":_bundle_debug_under_test",
    )

    _fake_android_bundle_app(
        name = "_fake_bundle_release_app",
        with_aot = True,
        tags = ["manual"],
    )

    flutter_android_bundle(
        name = "_bundle_release_under_test",
        application = ":_fake_bundle_release_app",
        android_abi = "arm64-v8a",
        tags = ["manual"],
    )

    _android_bundle_release_actions_test(
        name = name + "_android_bundle_release_actions",
        target_under_test = ":_bundle_release_under_test",
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
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_registrant_arm64_transition",
            ":" + name + "_registrant_x64_transition",
            ":" + name + "_single_config_across_dynamic_mode",
            ":" + name + "_android_bundle_debug_actions",
            ":" + name + "_android_bundle_release_actions",
        ],
    )
