"""Tests for several code-asset ids served by one shared library.

An application (or a test) that names a library for an id in `code_assets`
loads it in place of what `deps` supply under that id. When several ids name one
library, every platform must bundle it once and every id's manifest entry must
name that one file: two copies would be two images in the process, each with its
own static state. Over `//flutter/tests/shared_code_asset_fixture`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo", "DartPackageInfo")
load("//flutter:native_hot_patch.bzl", "HOT_PATCH_OUTPUT_GROUP", "flutter_native_hot_patch_aspect")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:flutter_native_assets.bzl", "resolve_native_assets")
load(":action_content.bzl", "written_json")

_FIXTURE = "//flutter/tests/shared_code_asset_fixture:"
_A = "package:shared_a/a"
_B = "package:shared_b/b"

_DBG = {"//command_line_option:compilation_mode": "dbg"}

def _platform(name):
    return {"//command_line_option:platforms": str(Label("//flutter/platforms:" + name))}

# Per platform: the Dart target key, the library's extension there, and the
# manifest path an entry for `lib<name>` takes.
_PLATFORMS = {
    "android_arm64": ("android_arm64", "so", lambda name: "lib%s.so" % name),
    "ios_arm64": ("ios_arm64", "dylib", lambda name: "%s.framework/%s" % (name, name)),
    "linux_x64": ("linux_x64", "so", lambda name: "lib%s.so" % name),
    "macos_arm64": ("macos_arm64", "dylib", lambda name: "lib%s.dylib" % name),
    "windows_x64": ("windows_x64", "dll", lambda name: "lib%s.dll" % name),
}

# -- The application: what it bundles, and what its manifest names -------------

def _layout_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    dart_target, ext, entry = _PLATFORMS[ctx.attr.platform]

    bundled = target[FlutterApplicationInfo].bundled_code_assets.to_list()
    asserts.equals(
        env,
        sorted(["lib%s.%s" % (name, ext) for name in ctx.attr.libraries]),
        sorted([f.basename for f in bundled]),
        "each library bundled once",
    )

    manifest = written_json(env, ".native_assets.json")
    if manifest == None:
        return analysistest.end(env)
    section = manifest["native-assets"].get(dart_target, {})
    asserts.equals(
        env,
        {
            _A: ["absolute", entry(ctx.attr.libraries[0])],
            _B: ["absolute", entry(ctx.attr.libraries[-1])],
        },
        section,
    )
    return analysistest.end(env)

_LAYOUT_ATTRS = {
    # The library serving `_A`, then the one serving `_B`; one name when both
    # share it.
    "libraries": attr.string_list(mandatory = True),
    "platform": attr.string(mandatory = True),
}

# A transition's settings are fixed when the test rule is made, so one rule per
# platform. Debug, because a release build refuses to cross-compile between
# desktop platforms, and the layout is the same in every mode.
_layout_android_arm64_test = analysistest.make(_layout_impl, attrs = _LAYOUT_ATTRS, config_settings = _platform("android_arm64") | _DBG)
_layout_ios_arm64_test = analysistest.make(_layout_impl, attrs = _LAYOUT_ATTRS, config_settings = _platform("ios_arm64") | _DBG)
_layout_linux_x64_test = analysistest.make(_layout_impl, attrs = _LAYOUT_ATTRS, config_settings = _platform("linux_x64") | _DBG)
_layout_macos_arm64_test = analysistest.make(_layout_impl, attrs = _LAYOUT_ATTRS, config_settings = _platform("macos_arm64") | _DBG)
_layout_windows_x64_test = analysistest.make(_layout_impl, attrs = _LAYOUT_ATTRS, config_settings = _platform("windows_x64") | _DBG)

# -- What a debug app tells the dev tool, and what a patch build builds --------

def _basenames(paths):
    return sorted([p.rsplit("/", 1)[-1] for p in paths])

def _dev_config_impl(ctx):
    env = analysistest.begin(ctx)
    config = written_json(env, "_dev_config.json")
    if config == None:
        return analysistest.end(env)
    libs = config["nativeLibs"]
    asserts.equals(env, ["libcombined.dylib"], _basenames(libs))
    if len(libs) != 1:
        return analysistest.end(env)
    asserts.equals(env, ctx.attr.contract, _basenames(config["nativeLibContracts"][libs[0]]))
    return analysistest.end(env)

_dev_config_test = analysistest.make(
    _dev_config_impl,
    attrs = {"contract": attr.string_list()},
    config_settings = _DBG,
)

def _hot_patch_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = getattr(target[OutputGroupInfo], HOT_PATCH_OUTPUT_GROUP).to_list()
    asserts.equals(env, ctx.attr.expected, sorted([f.basename for f in files]))
    return analysistest.end(env)

_hot_patch_test = analysistest.make(
    _hot_patch_impl,
    attrs = {"expected": attr.string_list()},
    extra_target_under_test_aspects = [flutter_native_hot_patch_aspect],
    config_settings = _DBG,
)

# -- The platform bundlers -----------------------------------------------------

def _code_asset_inputs(env, application):
    """Distinct code-asset libraries any action of the target reads."""
    own = "/%s_code_assets/" % application
    return sorted({
        f.basename: None
        for a in analysistest.target_actions(env)
        for f in a.inputs.to_list()
        if own in f.path
    }.keys())

def _bundler_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, ctx.attr.libraries, _code_asset_inputs(env, ctx.attr.application))
    if ctx.attr.frameworks:
        asserts.equals(
            env,
            ctx.attr.frameworks,
            sorted([
                a.outputs.to_list()[0].basename
                for a in analysistest.target_actions(env)
                if a.mnemonic == "FlutterIOSNativeAssetFramework"
            ]),
            "one framework per library",
        )
    return analysistest.end(env)

_BUNDLER_ATTRS = {
    # The name of the application the bundler reads, which names the
    # directory its libraries are staged in.
    "application": attr.string(mandatory = True),
    "frameworks": attr.string_list(),
    "libraries": attr.string_list(mandatory = True),
}

_bundler_android_arm64_test = analysistest.make(_bundler_impl, attrs = _BUNDLER_ATTRS, config_settings = _platform("android_arm64") | _DBG)
_bundler_ios_arm64_test = analysistest.make(_bundler_impl, attrs = _BUNDLER_ATTRS, config_settings = _platform("ios_arm64") | _DBG)
_bundler_macos_arm64_test = analysistest.make(_bundler_impl, attrs = _BUNDLER_ATTRS, config_settings = _platform("macos_arm64") | _DBG)

# -- A test, built for its target ----------------------------------------------

def _test_layout_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    found = [
        f
        for f in target[DefaultInfo].default_runfiles.files.to_list()
        if f.basename.startswith("libcombined.")
    ]
    asserts.equals(env, 1, len(found), "the combined library once in runfiles: %s" % found)
    manifest = written_json(env, ".native_assets.json")
    if manifest == None or len(found) != 1:
        return analysistest.end(env)
    sections = manifest["native-assets"].values()
    asserts.equals(env, 1, len(sections))
    path = ["absolute", found[0].short_path]
    asserts.equals(env, {_A: path, _B: path}, sections[0] if sections else None)
    return analysistest.end(env)

_test_layout_test = analysistest.make(_test_layout_impl)

# -- Resolution itself ---------------------------------------------------------

def _fake_package_impl(ctx):
    assets = tuple([t[DartCodeAssetInfo] for t in ctx.attr.code_assets])
    pkg = DartPackageInfo(
        package_name = ctx.attr.package_name,
        lib_root = ctx.label.package,
        code_assets = assets,
    )
    return [DartInfo(
        package_name = ctx.attr.package_name,
        lib_root = ctx.label.package,
        transitive_srcs = depset(),
        transitive_resources = depset(),
        transitive_packages = depset([pkg]),
    )]

fake_package = rule(
    implementation = _fake_package_impl,
    attrs = {
        "code_assets": attr.label_list(providers = [DartCodeAssetInfo]),
        "package_name": attr.string(mandatory = True),
    },
    doc = "A Dart package record carrying code assets, with no ownership check.",
)

def _opt_mode_transition_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "opt"}

_opt_mode_transition = transition(
    implementation = _opt_mode_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _opt_mode_impl(ctx):
    return [ctx.attr.dep[0][DartCodeAssetInfo]]

opt_mode = rule(
    implementation = _opt_mode_impl,
    attrs = {"dep": attr.label(providers = [DartCodeAssetInfo], cfg = _opt_mode_transition)},
    doc = "Forwards a code asset built with `-c opt`.",
)

def _resolve_probe_impl(ctx):
    resolved = resolve_native_assets(
        ctx,
        declared = [],
        deps = ctx.attr.deps,
        code_assets = [t[DartCodeAssetInfo] for t in ctx.attr.code_assets],
    )
    got = {a.asset_id: a.file.basename for a in resolved.assets}
    if got != ctx.attr.expected:
        fail("%s: expected %s, resolved %s" % (ctx.label, ctx.attr.expected, got))
    return [DefaultInfo()]

resolve_probe = rule(
    implementation = _resolve_probe_impl,
    attrs = {
        "code_assets": attr.label_list(providers = [DartCodeAssetInfo]),
        "deps": attr.label_list(),
        # Asset id to the basename of the staged library.
        "expected": attr.string_dict(),
    },
    doc = "Runs `resolve_native_assets` and checks which library serves each id.",
)

def _refuses_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_refuses_test = analysistest.make(
    _refuses_impl,
    attrs = {"message": attr.string()},
    expect_failure = True,
)

def _builds_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

_builds_test = analysistest.make(_builds_impl)

_builds_debug_test = analysistest.make(_builds_impl, config_settings = _DBG)

_LAYOUT_TESTS = {
    "android_arm64": _layout_android_arm64_test,
    "ios_arm64": _layout_ios_arm64_test,
    "linux_x64": _layout_linux_x64_test,
    "macos_arm64": _layout_macos_arm64_test,
    "windows_x64": _layout_windows_x64_test,
}

_BUNDLER_TESTS = {
    "android_arm64": _bundler_android_arm64_test,
    "ios_arm64": _bundler_ios_arm64_test,
    "macos_arm64": _bundler_macos_arm64_test,
}

def shared_code_asset_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    tests = []

    # Both ids from one library on every platform; each package's own library
    # without the override; and one id moved while the other stays.
    for platform in _PLATFORMS:
        for app, libraries in [
            ("app", ["combined"]),
            ("app_own", ["a_own", "b_own"]),
            ("app_partial", ["combined", "b_own"]),
        ]:
            test = "%s_%s_%s" % (name, app, platform)
            _LAYOUT_TESTS[platform](
                name = test,
                target_under_test = _FIXTURE + app,
                libraries = libraries,
                platform = platform,
                # Analysed from a Mac, the one host with a Flutter toolchain
                # for every platform.
                target_compatible_with = ["@platforms//os:macos"],
            )
            tests.append(test)

    for platform, bundler in [
        ("android_arm64", "android_bundle"),
        ("ios_arm64", "ios_frameworks"),
        ("macos_arm64", "macos_libs"),
    ]:
        for app, libraries in [
            ("app", ["libcombined"]),
            ("app_own", ["liba_own", "libb_own"]),
        ]:
            ext = _PLATFORMS[platform][1]
            test = "%s_%s_%s" % (name, app, bundler)
            _BUNDLER_TESTS[platform](
                name = test,
                target_under_test = _FIXTURE + app + "_" + bundler,
                application = app,
                libraries = ["%s.%s" % (lib, ext) for lib in libraries],
                frameworks = [lib.removeprefix("lib") for lib in libraries] if platform == "ios_arm64" else [],
                target_compatible_with = ["@platforms//os:macos"],
            )
            tests.append(test)

    # Each id's contract on the one library they share; none when any id's
    # bindings are undescribed.
    for app, contract in [
        ("app", ["a.json", "b.json"]),
        ("app_bare", []),
        ("app_mixed", []),
    ]:
        _dev_config_test(
            name = name + "_dev_config_" + app,
            target_under_test = _FIXTURE + app,
            contract = contract,
            target_compatible_with = ["@platforms//os:macos"],
        )
        tests.append(name + "_dev_config_" + app)

    # One patch builder for the shared library, reached through both wrappers.
    _hot_patch_test(
        name = name + "_hot_patch",
        target_under_test = _FIXTURE + "app",
        expected = ["combined.hot_patch.json", "libcombined.dylib"],
        target_compatible_with = ["@platforms//os:macos"],
    )
    _refuses_test(
        name = name + "_two_patchers",
        target_under_test = _FIXTURE + "app_two_patchers",
        message = "name 2 different `hot_patch` targets",
    )
    tests += [name + "_hot_patch", name + "_two_patchers"]

    _test_layout_test(
        name = name + "_test_on_its_host",
        target_under_test = "//flutter/tests/shared_code_asset_fixture/test:shared_test",
        target_compatible_with = ["@platforms//os:macos"],
    )
    tests.append(name + "_test_on_its_host")

    # Two packages claiming one id with different libraries is refused, as in
    # rules_dart, unless the target names the one to use.
    fake_package(
        name = name + "_claims_a_own",
        package_name = "claim_one",
        code_assets = [_FIXTURE + "a_own"],
        tags = ["manual"],
    )
    fake_package(
        name = name + "_claims_a_combined",
        package_name = "claim_two",
        code_assets = [_FIXTURE + "a_combined_asset"],
        tags = ["manual"],
    )
    claims = [name + "_claims_a_own", name + "_claims_a_combined"]
    resolve_probe(
        name = name + "_conflict",
        deps = claims,
        tags = ["manual"],
    )
    _refuses_test(
        name = name + "_conflict_refused",
        target_under_test = name + "_conflict",
        message = "is claimed twice with different definitions",
    )
    resolve_probe(
        name = name + "_conflict_named",
        deps = claims,
        code_assets = [_FIXTURE + "b_combined_asset", _FIXTURE + "a_combined_asset"],
        expected = {_A: "libcombined.dylib", _B: "libcombined.dylib"},
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:macos"],
    )
    _builds_test(
        name = name + "_conflict_resolved_by_naming",
        target_under_test = name + "_conflict_named",
        target_compatible_with = ["@platforms//os:macos"],
    )
    tests += [name + "_conflict_refused", name + "_conflict_resolved_by_naming"]

    # One library reached in two configurations is two builds of it, which
    # cannot both ship under its file name: refused, as in rules_dart.
    opt_mode(
        name = name + "_a_combined_opt",
        dep = _FIXTURE + "a_combined_asset",
        tags = ["manual"],
    )
    resolve_probe(
        name = name + "_two_configurations",
        code_assets = [name + "_a_combined_opt", _FIXTURE + "b_combined_asset"],
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:macos"],
    )
    _refuses_test(
        name = name + "_two_configurations_refused",
        target_under_test = name + "_two_configurations",
        message = "reaches this target in two configurations",
        target_compatible_with = ["@platforms//os:macos"],
    )
    tests.append(name + "_two_configurations_refused")

    # An id a `flutter_native_asset` declares is not loaded from the packages
    # below, so their disagreeing about it is no conflict, in a debug build's
    # description of its libraries as in the resolution.
    _builds_debug_test(
        name = name + "_conflict_resolved_by_declaring",
        target_under_test = _FIXTURE + "app_declared",
        target_compatible_with = ["@platforms//os:macos"],
    )
    tests.append(name + "_conflict_resolved_by_declaring")

    native.test_suite(name = name, tests = tests)
