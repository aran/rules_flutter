"""Unit and analysis tests for flutter_shader_compile.bzl and shader aspect sharing."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter:defs.bzl", "flutter_application", "flutter_test")
load(
    "//flutter:providers.bzl",
    "FlutterCompiledShadersInfo",
)
load(
    "//flutter/private:common.bzl",
    "HOST_COMPATIBLE",
    "flutter_app_shader_aspect",
    "flutter_tester_shader_aspect",
    "flutter_web_shader_aspect",
)
load(
    "//flutter/private:flutter_shader_compile.bzl",
    "SHADER_PLATFORM_FLAGS",
    "get_shader_platform_flags",
)
load("//flutter/private:flutter_web_application.bzl", "flutter_web_bundle")
load(":action_content.bzl", "written_json")

def _compiled_shaders_bundle_impl(ctx):
    files = [
        entry.file
        for dep in ctx.attr.deps
        if FlutterCompiledShadersInfo in dep
        for entry in dep[FlutterCompiledShadersInfo].compiled_shaders.to_list()
    ]
    return [DefaultInfo(files = depset(files))]

_compiled_app_shaders = rule(
    implementation = _compiled_shaders_bundle_impl,
    attrs = {
        "deps": attr.label_list(aspects = [flutter_app_shader_aspect]),
    },
)

_compiled_web_shaders = rule(
    implementation = _compiled_shaders_bundle_impl,
    attrs = {
        "deps": attr.label_list(aspects = [flutter_web_shader_aspect]),
    },
)

_compiled_tester_shaders = rule(
    implementation = _compiled_shaders_bundle_impl,
    attrs = {
        "deps": attr.label_list(aspects = [flutter_tester_shader_aspect]),
    },
)

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

def _assert_no_workspace_include(env, action):
    include_flags = [arg for arg in action.argv if arg.startswith("--include=")]
    asserts.equals(
        env,
        [],
        [f for f in include_flags if f == "--include=flutter/tests/shared_shader_fixture/shaders"],
        "shader compile without shader_includes must not pass workspace --include directory: %s" % include_flags,
    )

def _consumer_with_own_shader_compiles_own_impl(ctx):
    env = analysistest.begin(ctx)
    shader_compiles = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterShaderCompile"
    ]
    asserts.equals(env, 1, len(shader_compiles), "consumer should compile only its own shader")
    for action in shader_compiles:
        _assert_no_workspace_include(env, action)
    config = written_json(env, ".asset_bundle_config.json")
    if config != None:
        asserts.true(env, "shaders/test_shader.frag" in config["copies"])
        asserts.true(env, "packages/shared_shader_fixture/shaders/pkg_shader.frag" in config["copies"])
        asserts.true(env, "shared_shader_fixture/shaders/test_shader.frag" in config["copies"])
    return analysistest.end(env)

def _consumer_sksl_required_compiles_locally_impl(ctx):
    env = analysistest.begin(ctx)
    shader_compiles = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterShaderCompile"
    ]
    asserts.equals(env, 2, len(shader_compiles), "require_sksl_shaders should compile all shaders locally")
    for action in shader_compiles:
        _assert_no_workspace_include(env, action)
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

def _assert_shader_with_includes_action(env, action):
    input_short_paths = [f.short_path for f in action.inputs.to_list()]
    input_paths = [f.path for f in action.inputs.to_list()]
    asserts.true(
        env,
        "flutter/tests/shared_shader_fixture/shaders/with_include.frag" in input_short_paths,
        "shader source missing from FlutterShaderCompile inputs: %s" % input_short_paths,
    )
    asserts.true(
        env,
        "flutter/tests/shared_shader_fixture/shaders/common.glsl" in input_short_paths,
        "declared shader_includes missing from FlutterShaderCompile inputs: %s" % input_short_paths,
    )
    asserts.true(
        env,
        any([p.endswith(".iplr.includes/flutter/tests/shared_shader_fixture/shaders/common.glsl") for p in input_paths]),
        "staged shader_includes symlink missing from FlutterShaderCompile inputs: %s" % input_paths,
    )
    include_flags = [arg[len("--include="):] for arg in action.argv if arg.startswith("--include=")]
    user_include_dirs = [d for d in include_flags if not d.endswith("/shader_lib")]
    asserts.true(
        env,
        len(user_include_dirs) > 0,
        "expected staged --include directory for declared shader_includes, got %s" % include_flags,
    )
    for d in user_include_dirs:
        asserts.true(
            env,
            ".iplr.includes/" in d,
            "--include must point at staged include directory, never workspace directory: %s" % d,
        )
        asserts.false(
            env,
            d == "flutter/tests/shared_shader_fixture/shaders",
            "--include must never point at workspace directory: %s" % d,
        )

def _library_shader_includes_aspect_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, FlutterCompiledShadersInfo in target, "FlutterCompiledShadersInfo missing from aspect target")
    if FlutterCompiledShadersInfo in target:
        shaders = target[FlutterCompiledShadersInfo].compiled_shaders.to_list()
        asserts.equals(env, 1, len(shaders), "shader_with_includes_lib should provide 1 compiled shader via aspect")
        if shaders:
            asserts.equals(env, "shaders/with_include.frag", shaders[0].bundle_path)
            asserts.true(env, shaders[0].file.basename.endswith(".iplr"))
    return analysistest.end(env)

def _consumer_forwards_library_shader_includes_impl(ctx):
    env = analysistest.begin(ctx)
    shader_compiles = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterShaderCompile"
    ]
    asserts.equals(env, 1, len(shader_compiles), "expected 1 local FlutterShaderCompile action when require_sksl_shaders is True")
    if shader_compiles:
        _assert_shader_with_includes_action(env, shader_compiles[0])
    dev_config = written_json(env, "_dev_config.json")
    if dev_config != None:
        shader_map = dev_config.get("shaders", {})
        asserts.equals(
            env,
            [
                "flutter/tests/shared_shader_fixture/shaders/with_include.frag",
                "flutter/tests/shared_shader_fixture/shaders/common.glsl",
            ],
            shader_map.get("shaders/with_include.frag"),
            "dev_config.json shaders entry must include library shader_includes: %s" % shader_map,
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
_library_shader_includes_app_aspect_test = analysistest.make(
    _library_shader_includes_aspect_impl,
    config_settings = _DBG,
    extra_target_under_test_aspects = [flutter_app_shader_aspect],
)
_library_shader_includes_web_aspect_test = analysistest.make(
    _library_shader_includes_aspect_impl,
    config_settings = _DBG,
    extra_target_under_test_aspects = [flutter_web_shader_aspect],
)
_library_shader_includes_tester_aspect_test = analysistest.make(
    _library_shader_includes_aspect_impl,
    config_settings = _DBG,
    extra_target_under_test_aspects = [flutter_tester_shader_aspect],
)
_consumer_forwards_library_shader_includes_test = analysistest.make(
    _consumer_forwards_library_shader_includes_impl,
    config_settings = _DBG,
)

def shader_compile_test_suite(name):
    """Defines unit, analysis, and execution tests for shader compilation and aspect sharing.

    Args:
      name: The test_suite target name.
    """
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

    flutter_application(
        name = "_app_consumer_with_includes_sksl_required",
        package_name = "app_consumer_with_includes_sksl_required",
        main = "lib/web_fixture_main.dart",
        deps = ["//flutter/tests/shared_shader_fixture:shader_with_includes_lib"],
        require_sksl_shaders = True,
        tags = ["manual"],
    )

    flutter_web_bundle(
        name = "_web_consumer_with_includes",
        package_name = "web_consumer_with_includes",
        main = "lib/web_fixture_main.dart",
        deps = ["//flutter/tests/shared_shader_fixture:shader_with_includes_lib"],
        tags = ["manual"],
    )

    _compiled_app_shaders(
        name = "_compiled_app_shaders_with_includes",
        deps = ["//flutter/tests/shared_shader_fixture:shader_with_includes_lib"],
        tags = ["manual"],
    )

    _compiled_web_shaders(
        name = "_compiled_web_shaders_with_includes",
        deps = ["//flutter/tests/shared_shader_fixture:shader_with_includes_lib"],
        tags = ["manual"],
    )

    _compiled_tester_shaders(
        name = "_compiled_tester_shaders_with_includes",
        deps = ["//flutter/tests/shared_shader_fixture:shader_with_includes_lib"],
        tags = ["manual"],
    )

    build_test(
        name = name + "_shader_with_includes_build_test",
        target_compatible_with = HOST_COMPATIBLE,
        targets = [
            ":_compiled_app_shaders_with_includes",
            ":_compiled_web_shaders_with_includes",
            ":_compiled_tester_shaders_with_includes",
            ":_web_consumer_with_includes",
        ],
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
    _library_shader_includes_app_aspect_test(
        name = name + "_library_shader_includes_app_aspect",
        target_under_test = "//flutter/tests/shared_shader_fixture:shader_with_includes_lib",
    )
    _library_shader_includes_web_aspect_test(
        name = name + "_library_shader_includes_web_aspect",
        target_under_test = "//flutter/tests/shared_shader_fixture:shader_with_includes_lib",
    )
    _library_shader_includes_tester_aspect_test(
        name = name + "_library_shader_includes_tester_aspect",
        target_under_test = "//flutter/tests/shared_shader_fixture:shader_with_includes_lib",
    )
    _consumer_with_own_shader_test(
        name = name + "_app_consumer_own_shader",
        target_under_test = ":_app_consumer_own_shader",
    )
    _consumer_sksl_required_test(
        name = name + "_app_consumer_sksl_required",
        target_under_test = ":_app_consumer_sksl_required",
    )
    _consumer_forwards_library_shader_includes_test(
        name = name + "_app_consumer_forwards_library_shader_includes",
        target_under_test = ":_app_consumer_with_includes_sksl_required",
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
            ":" + name + "_library_shader_includes_app_aspect",
            ":" + name + "_library_shader_includes_web_aspect",
            ":" + name + "_library_shader_includes_tester_aspect",
            ":" + name + "_app_consumer_own_shader",
            ":" + name + "_app_consumer_sksl_required",
            ":" + name + "_app_consumer_forwards_library_shader_includes",
            ":" + name + "_shader_with_includes_build_test",
        ],
    )
