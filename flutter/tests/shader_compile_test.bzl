"""Unit and analysis tests for flutter_shader_compile.bzl and shader aspect sharing."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:defs.bzl", "flutter_application", "flutter_library", "flutter_test")
load(
    "//flutter:providers.bzl",
    "FlutterCompiledShadersInfo",
)
load(
    "//flutter/private:common.bzl",
    "HOST_COMPATIBLE",
    "flutter_app_shader_aspect",
    "flutter_tester_shader_aspect",
)
load(
    "//flutter/private:flutter_shader_compile.bzl",
    "SHADER_PLATFORM_FLAGS",
    "get_shader_platform_flags",
)
load(":action_content.bzl", "written_json")

def _ios_flags_test_impl(ctx):
    """iOS shaders use Metal only."""
    env = unittest.begin(ctx)
    flags = get_shader_platform_flags("ios")
    asserts.equals(env, ["--runtime-stage-metal"], flags)
    return unittest.end(env)

def _macos_flags_test_impl(ctx):
    """macOS shaders use SKSL + Metal."""
    env = unittest.begin(ctx)
    flags = get_shader_platform_flags("macos")
    asserts.true(env, "--sksl" in flags, "macos should include --sksl")
    asserts.true(env, "--runtime-stage-metal" in flags, "macos should include --runtime-stage-metal")
    return unittest.end(env)

def _android_flags_test_impl(ctx):
    """Android shaders use SKSL + GLES + GLES3 + Vulkan."""
    env = unittest.begin(ctx)
    flags = get_shader_platform_flags("android")
    asserts.true(env, "--sksl" in flags)
    asserts.true(env, "--runtime-stage-gles" in flags)
    asserts.true(env, "--runtime-stage-gles3" in flags)
    asserts.true(env, "--runtime-stage-vulkan" in flags)
    return unittest.end(env)

def _linux_matches_android_test_impl(ctx):
    """Linux and Android should have the same shader flags."""
    env = unittest.begin(ctx)
    asserts.equals(env, get_shader_platform_flags("android"), get_shader_platform_flags("linux"))
    return unittest.end(env)

def _windows_matches_android_test_impl(ctx):
    """Windows and Android should have the same shader flags."""
    env = unittest.begin(ctx)
    asserts.equals(env, get_shader_platform_flags("android"), get_shader_platform_flags("windows"))
    return unittest.end(env)

def _web_flags_test_impl(ctx):
    """Web shaders use SKSL only."""
    env = unittest.begin(ctx)
    flags = get_shader_platform_flags("web")
    asserts.equals(env, ["--sksl"], flags)
    return unittest.end(env)

def _tester_flags_test_impl(ctx):
    """flutter_tester gets SKSL + Vulkan, as `flutter test` compiles for it."""
    env = unittest.begin(ctx)
    asserts.equals(env, ["--sksl", "--runtime-stage-vulkan"], get_shader_platform_flags("tester"))
    return unittest.end(env)

def _all_platforms_covered_test_impl(ctx):
    """All expected platforms are in the flags dict."""
    env = unittest.begin(ctx)
    expected = ["ios", "macos", "android", "linux", "windows", "web", "tester"]
    for p in expected:
        asserts.true(env, p in SHADER_PLATFORM_FLAGS, "Platform '%s' should be in SHADER_PLATFORM_FLAGS" % p)
    return unittest.end(env)

_t0_test = unittest.make(_ios_flags_test_impl)
_t1_test = unittest.make(_macos_flags_test_impl)
_t2_test = unittest.make(_android_flags_test_impl)
_t3_test = unittest.make(_linux_matches_android_test_impl)
_t4_test = unittest.make(_windows_matches_android_test_impl)
_t5_test = unittest.make(_web_flags_test_impl)
_t6_test = unittest.make(_all_platforms_covered_test_impl)
_t7_test = unittest.make(_tester_flags_test_impl)

# Analysis tests for shared shader compilation via aspects

def _consumer_no_local_shader_compiles_impl(ctx):
    env = analysistest.begin(ctx)
    shader_compiles = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterShaderCompile"
    ]
    asserts.equals(env, 0, len(shader_compiles), "consumer should not compile shared shaders locally")
    config = written_json(env, ".asset_bundle_config.json")
    if config != None:
        asserts.true(env, "shaders/test_shader.frag" in config["copies"], "SDK/library shader missing from bundle copies")
        asserts.true(env, "packages/shared_shader_fixture/shaders/pkg_shader.frag" in config["copies"], "pkg_shader missing from bundle copies")
        asserts.true(env, config["copies"]["shaders/test_shader.frag"].endswith(".iplr"), "shader output should be .iplr")
    return analysistest.end(env)

def _consumer_with_own_shader_compiles_own_impl(ctx):
    env = analysistest.begin(ctx)
    shader_compiles = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterShaderCompile"
    ]
    asserts.equals(env, 1, len(shader_compiles), "consumer should compile only its own shader")
    config = written_json(env, ".asset_bundle_config.json")
    if config != None:
        asserts.true(env, "shaders/test_shader.frag" in config["copies"])
        asserts.true(env, "packages/shared_shader_fixture/shaders/pkg_shader.frag" in config["copies"])
        asserts.true(env, "flutter/tests/shared_shader_fixture/shaders/test_shader.frag" in config["copies"])
    return analysistest.end(env)

def _consumer_sksl_required_compiles_locally_impl(ctx):
    env = analysistest.begin(ctx)
    shader_compiles = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterShaderCompile"
    ]
    asserts.equals(env, 2, len(shader_compiles), "require_sksl_shaders should compile all shaders locally")
    return analysistest.end(env)

def _aspect_compiles_on_library_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, FlutterCompiledShadersInfo in target, "FlutterCompiledShadersInfo missing from aspect target")
    if FlutterCompiledShadersInfo in target:
        shaders = target[FlutterCompiledShadersInfo].compiled_shaders.to_list()
        asserts.equals(env, 2, len(shaders), "library should provide 2 compiled shaders via aspect")
        bundle_paths = [s.bundle_path for s in shaders]
        asserts.true(env, "shaders/test_shader.frag" in bundle_paths)
        asserts.true(
            env,
            "packages/shared_shader_fixture/shaders/pkg_shader.frag" in bundle_paths or
            "packages/shared_shader_fixture_2/shaders/pkg_shader.frag" in bundle_paths,
        )
    return analysistest.end(env)

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}

_consumer_no_local_shader_compiles_test = analysistest.make(_consumer_no_local_shader_compiles_impl, config_settings = _DBG)
_consumer_with_own_shader_test = analysistest.make(_consumer_with_own_shader_compiles_own_impl, config_settings = _DBG)
_consumer_sksl_required_test = analysistest.make(_consumer_sksl_required_compiles_locally_impl, config_settings = _DBG)
_aspect_compiles_on_library_test = analysistest.make(
    _aspect_compiles_on_library_impl,
    config_settings = _DBG,
    extra_target_under_test_aspects = [flutter_app_shader_aspect],
)

def shader_compile_test_suite(name):
    unittest.suite(
        name + "_flags_pure",
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
    )

    flutter_application(
        name = "_app_consumer_1",
        package_name = "app_consumer_1",
        main = "lib/web_fixture_main.dart",
        deps = ["//flutter/tests/shared_shader_fixture:shared_shader_lib"],
        tags = ["manual"],
    )

    flutter_application(
        name = "_app_consumer_2",
        package_name = "app_consumer_2",
        main = "lib/web_fixture_main.dart",
        deps = ["//flutter/tests/shared_shader_fixture:shared_shader_lib"],
        tags = ["manual"],
    )

    flutter_test(
        name = "_test_consumer_1",
        package_name = "test_consumer_1",
        main = "lib/web_fixture_main.dart",
        deps = [
            "//flutter/tests/shared_shader_fixture:shared_shader_lib",
            "//flutter/tests/flutter_test_analyze_fixture/fake_test_api",
        ],
        tags = ["manual"],
    )

    flutter_test(
        name = "_test_consumer_2",
        package_name = "test_consumer_2",
        main = "lib/web_fixture_main.dart",
        deps = [
            "//flutter/tests/shared_shader_fixture:shared_shader_lib",
            "//flutter/tests/flutter_test_analyze_fixture/fake_test_api",
        ],
        tags = ["manual"],
    )

    flutter_application(
        name = "_app_consumer_own_shader",
        package_name = "app_consumer_own_shader",
        main = "lib/web_fixture_main.dart",
        deps = ["//flutter/tests/shared_shader_fixture:shared_shader_lib"],
        shaders = ["//flutter/tests/shared_shader_fixture:shaders/test_shader.frag"],
        tags = ["manual"],
    )

    flutter_application(
        name = "_app_consumer_sksl_required",
        package_name = "app_consumer_sksl_required",
        main = "lib/web_fixture_main.dart",
        deps = ["//flutter/tests/shared_shader_fixture:shared_shader_lib"],
        require_sksl_shaders = True,
        tags = ["manual"],
    )

    _consumer_no_local_shader_compiles_test(
        name = name + "_app_consumer_1_no_shader_actions",
        target_under_test = ":_app_consumer_1",
    )
    _consumer_no_local_shader_compiles_test(
        name = name + "_app_consumer_2_no_shader_actions",
        target_under_test = ":_app_consumer_2",
    )
    _consumer_no_local_shader_compiles_test(
        name = name + "_test_consumer_1_no_shader_actions",
        target_compatible_with = HOST_COMPATIBLE,
        target_under_test = ":_test_consumer_1",
    )
    _consumer_no_local_shader_compiles_test(
        name = name + "_test_consumer_2_no_shader_actions",
        target_compatible_with = HOST_COMPATIBLE,
        target_under_test = ":_test_consumer_2",
    )
    _aspect_compiles_on_library_test(
        name = name + "_aspect_compiles_on_library",
        target_under_test = "//flutter/tests/shared_shader_fixture:shared_shader_lib",
    )
    _aspect_compiles_on_library_test(
        name = name + "_aspect_compiles_on_library_2",
        target_under_test = "//flutter/tests/shared_shader_fixture:shared_shader_lib_2",
    )
    _consumer_with_own_shader_test(
        name = name + "_app_consumer_own_shader",
        target_under_test = ":_app_consumer_own_shader",
    )
    _consumer_sksl_required_test(
        name = name + "_app_consumer_sksl_required",
        target_under_test = ":_app_consumer_sksl_required",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_flags_pure",
            ":" + name + "_app_consumer_1_no_shader_actions",
            ":" + name + "_app_consumer_2_no_shader_actions",
            ":" + name + "_test_consumer_1_no_shader_actions",
            ":" + name + "_test_consumer_2_no_shader_actions",
            ":" + name + "_aspect_compiles_on_library",
            ":" + name + "_aspect_compiles_on_library_2",
            ":" + name + "_app_consumer_own_shader",
            ":" + name + "_app_consumer_sksl_required",
        ],
    )
