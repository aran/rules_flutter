"""Tests for several code-asset ids served by one shared library.

An application (or a test) that names a library for an id in `code_assets`
loads it in place of what `deps` supply under that id. When several ids name one
library, every platform must bundle it once and every id's manifest entry must
name that one file: two copies would be two images in the process, each with its
own static state. Over `//flutter/tests/shared_code_asset_fixture`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo", "DartPackageInfo")
load("@rules_dart//dart:utils.bzl", "PROGRAM_ASSETS_TOOLCHAINS", "program_assets_attrs")
load("//flutter:native_hot_patch.bzl", "HOT_PATCH_OUTPUT_GROUP", "flutter_native_hot_patch_aspect")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//flutter/private:flutter_native_assets.bzl", "candidate_code_asset_libraries", "resolve_native_assets")
load(":action_content.bzl", "written_json")

_FIXTURE = "//flutter/tests/shared_code_asset_fixture:"
_A = "package:shared_a/a"
_B = "package:shared_b/b"

_DBG = {"//command_line_option:compilation_mode": "dbg"}

def _platform(name):
    # The Android platform is named for its ABI directory.
    label = "@rules_android//:arm64-v8a" if name == "android_arm64" else "//flutter/platforms:" + name
    return {"//command_line_option:platforms": str(Label(label))}

# Per platform: the Dart target key and the library's extension there.
_PLATFORMS = {
    "android_arm64": ("android_arm64", "so"),
    "ios_arm64": ("ios_arm64", "dylib"),
    "linux_x64": ("linux_x64", "so"),
    "macos_arm64": ("macos_arm64", "dylib"),
    "windows_x64": ("windows_x64", "dll"),
}

# -- The application: what it bundles, and what its manifest names -------------

def _layout_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    dart_target, ext = _PLATFORMS[ctx.attr.platform]

    bundled = candidate_code_asset_libraries(target[FlutterApplicationInfo].program_assets)
    asserts.equals(
        env,
        sorted(["lib%s.%s" % (name, ext) for name in ctx.attr.libraries]),
        sorted([f.basename for f in bundled]),
        "each library bundled once",
    )

    # The manifest is written by an action, from the code assets by name: it
    # names each id's library and reads none of them.
    actions = analysistest.target_actions(env)
    writes = [a for a in actions if a.mnemonic == "FlutterNativeAssetsManifest"]
    asserts.equals(env, 1, len(writes), "one manifest action")
    if len(writes) != 1:
        return analysistest.end(env)
    argv = writes[0].argv
    asserts.equals(env, "manifest", argv[argv.index("--os") - 1])
    asserts.equals(env, ctx.attr.platform.split("_")[0], argv[argv.index("--os") + 1])
    asserts.equals(env, dart_target, argv[argv.index("--target") + 1])
    asserts.equals(env, "code-names", argv[argv.index("--holds") + 1])
    for asset_id, library in [(_A, ctx.attr.libraries[0]), (_B, ctx.attr.libraries[-1])]:
        at = argv.index(asset_id)
        asserts.equals(env, ["dynamic_loading_bundle", "lib%s.%s" % (library, ext)], argv[at + 1:at + 3])
    asserts.equals(
        env,
        [],
        [f.basename for f in writes[0].inputs.to_list() if f.extension in ("so", "dylib", "dll")],
        "the manifest reads no library",
    )

    # The asset bundle ships the manifest and reads no library either.
    bundles = [a for a in actions if a.mnemonic == "FlutterAssetBundle"]
    asserts.equals(env, 1, len(bundles), "one asset bundle")
    for bundle in bundles:
        inputs = bundle.inputs.to_list()
        asserts.true(env, writes[0].outputs.to_list()[0] in inputs, "the asset bundle ships the manifest")
        asserts.equals(env, [], [f.basename for f in inputs if f.extension in ("so", "dylib", "dll")], "the asset bundle reads no library")
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

def _code_asset_inputs(env, package):
    """Distinct libraries of this package that any action of the target reads."""
    return sorted({
        f.basename: None
        for a in analysistest.target_actions(env)
        for f in a.inputs.to_list()
        if f.owner != None and f.owner.package == package and f.extension in ("so", "dylib", "dll")
    }.keys())

def _bundler_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, ctx.attr.libraries, _code_asset_inputs(env, Label(_FIXTURE + "app").package))
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
    pkg = DartPackageInfo(
        label = ctx.label,
        package_name = ctx.attr.package_name,
        package_root = "%s/%s" % (ctx.label.package, ctx.label.name),
        # Stated, as a pub hub states it, so two records of one name at two
        # roots are one package.
        version = "1.0.0",
        language_version = "",
        code_assets = ctx.attr.code_assets,
    )
    return [DartInfo(
        packages = (pkg,),
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
    doc = "A pub package record (version 1.0.0) carrying code assets, each the package's own.",
)

def _fake_cycle_impl(ctx):
    names = ctx.attr.package_names
    assets = ctx.attr.code_assets
    if len(names) != len(assets):
        fail("%s: one code asset per package" % ctx.label)
    packages = tuple([
        DartPackageInfo(
            label = ctx.label,
            package_name = name,
            package_root = "%s/%s" % (ctx.label.package, name),
            language_version = "",
            code_assets = [asset],
        )
        for name, asset in zip(names, assets)
    ])
    return [DartInfo(
        packages = packages,
        transitive_srcs = depset(),
        transitive_resources = depset(),
        transitive_packages = depset(packages),
    )]

fake_cycle = rule(
    implementation = _fake_cycle_impl,
    attrs = {
        "code_assets": attr.label_list(providers = [DartCodeAssetInfo]),
        "package_names": attr.string_list(mandatory = True),
    },
    doc = "One target contributing several packages, as rules_dart builds a pub dependency cycle; package `i` owns code asset `i`.",
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
        package = None,
        deps = ctx.attr.deps,
        code_assets = [t[DartCodeAssetInfo] for t in ctx.attr.code_assets],
    )
    got = {a.asset_id: a.file.basename for a in resolved.assets}
    if got != ctx.attr.expected:
        fail("%s: expected %s, resolved %s" % (ctx.label, ctx.attr.expected, got))
    return [DefaultInfo()]

resolve_probe = rule(
    implementation = _resolve_probe_impl,
    attrs = program_assets_attrs() | {
        "code_assets": attr.label_list(providers = [DartCodeAssetInfo]),
        "deps": attr.label_list(),
        # Asset id to the basename of the staged library.
        "expected": attr.string_dict(),
    },
    toolchains = PROGRAM_ASSETS_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = ["cpp"],
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

_REFUSES_ATTRS = {"message": attr.string()}
_refuses_ios_arm64_test = analysistest.make(_refuses_impl, attrs = _REFUSES_ATTRS, expect_failure = True, config_settings = _platform("ios_arm64"))
_refuses_linux_x64_test = analysistest.make(_refuses_impl, attrs = _REFUSES_ATTRS, expect_failure = True, config_settings = _platform("linux_x64") | _DBG)
_refuses_macos_arm64_test = analysistest.make(_refuses_impl, attrs = _REFUSES_ATTRS, expect_failure = True, config_settings = _platform("macos_arm64"))
_builds_macos_arm64_test = analysistest.make(_builds_impl, config_settings = _platform("macos_arm64"))

_REFUSES_ON = {
    "ios_arm64": _refuses_ios_arm64_test,
    "linux_x64": _refuses_linux_x64_test,
    "macos_arm64": _refuses_macos_arm64_test,
}

_BUILDS_ON = {"macos_arm64": _builds_macos_arm64_test}

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
        target_under_test = "//flutter/tests/shared_code_asset_fixture/test:shared_test.program",
        target_compatible_with = ["@platforms//os:macos"],
    )
    tests.append(name + "_test_on_its_host")

    # Two packages claiming one id with different libraries is refused, as in
    # rules_dart, unless the target names the one to use.
    fake_package(
        name = name + "_claims_a_own",
        package_name = "shared_a",
        code_assets = [_FIXTURE + "a_own"],
        tags = ["manual"],
    )
    fake_package(
        name = name + "_claims_a_combined",
        package_name = "shared_a",
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

    # A target that carries several packages (a pub dependency cycle built as
    # one library) serves the code assets of every one of them, not only the
    # first.
    fake_cycle(
        name = name + "_cycle",
        package_names = ["shared_a", "shared_b"],
        code_assets = [_FIXTURE + "a_own", _FIXTURE + "b_own"],
        tags = ["manual"],
    )
    resolve_probe(
        name = name + "_cycle_probe",
        deps = [name + "_cycle"],
        expected = {_A: "liba_own.dylib", _B: "libb_own.dylib"},
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:macos"],
    )
    _builds_test(
        name = name + "_every_package_of_a_target_serves_its_assets",
        target_under_test = name + "_cycle_probe",
        target_compatible_with = ["@platforms//os:macos"],
    )
    tests.append(name + "_every_package_of_a_target_serves_its_assets")

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

    # The one check that no two libraries an application could bundle land on
    # one path, over every candidate whichever ships: by file name on every
    # platform, and by framework name on iOS.
    for app, platform, message in [
        ("app_same_file_name", "macos_arm64", "two native libraries would both be bundled as `libcombined.dylib`"),
        ("app_same_file_name", "linux_x64", "two native libraries would both be bundled as `libcombined.so`"),
        ("app_same_framework_name", "ios_arm64", "would both be bundled as the framework `combined.framework`"),
    ]:
        _REFUSES_ON[platform](
            name = "%s_%s_%s_refused" % (name, app, platform),
            target_under_test = _FIXTURE + app,
            message = message,
            target_compatible_with = ["@platforms//os:macos"],
        )
        tests.append("%s_%s_%s_refused" % (name, app, platform))
    _BUILDS_ON["macos_arm64"](
        name = name + "_framework_names_matter_on_ios_only",
        target_under_test = _FIXTURE + "app_same_framework_name",
        target_compatible_with = ["@platforms//os:macos"],
    )
    tests.append(name + "_framework_names_matter_on_ios_only")

    # An id the application names in its `code_assets` is not loaded from the
    # packages below, so their disagreeing about it is no conflict, in a debug
    # build's description of its libraries as in the resolution.
    _builds_debug_test(
        name = name + "_conflict_named_in_a_debug_app",
        target_under_test = _FIXTURE + "app_conflict_named",
        target_compatible_with = ["@platforms//os:macos"],
    )
    tests.append(name + "_conflict_named_in_a_debug_app")

    native.test_suite(name = name, tests = tests)
