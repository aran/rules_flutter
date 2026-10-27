"""Tests for a `flutter_native_library` whose library is a Dart code asset.

A library that reaches an app as a code asset is bundled under the application's
own name for it, not the path its rule wrote. What the wrapper declares has to
arrive on that name in `_dev_config.json` — the contract and the sources, as for
a `native_deps` entry — and its `hot_patch` has to be reachable from the launch
target, whichever package rule owns the asset and whatever attribute carries
it. Over `//flutter/tests/code_asset_fixture`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo")
load("//flutter:native_hot_patch.bzl", "HOT_PATCH_OUTPUT_GROUP", "flutter_native_hot_patch_aspect")
load("//flutter:providers.bzl", "FlutterNativeLibraryInfo")
load(":action_content.bzl", "written_json")

_FIXTURE = "//flutter/tests/code_asset_fixture:"
_DBG = {"//command_line_option:compilation_mode": "dbg"}

def _basenames(paths):
    return sorted([p.rsplit("/", 1)[-1] for p in paths])

def _dev_config_impl(ctx):
    env = analysistest.begin(ctx)
    config = written_json(env, "_dev_config.json")
    if config == None:
        return analysistest.end(env)

    # One library, under the application's own name for it: the bundled copy is
    # what the dev tool compares, and the keys of every per-library map are its
    # path. Under a directory of the application's own, so neither the
    # library's rule nor a second application in the package writes it too.
    libs = config["nativeLibs"]
    asserts.equals(env, 1, len(libs), "expected one bundled library, got %s" % libs)
    if len(libs) != 1:
        return analysistest.end(env)
    lib = libs[0]
    label = analysistest.target_under_test(env).label
    own = "/%s/%s_code_assets/" % (label.package, label.name)
    asserts.true(env, own in lib, "expected the library under %s, got %s" % (own, lib))
    asserts.equals(env, ctx.attr.contract, _basenames(config["nativeLibContracts"][lib]))
    asserts.equals(env, ctx.attr.sources, _basenames(config["nativeLibSources"][lib]))
    return analysistest.end(env)

_dev_config_test = analysistest.make(
    _dev_config_impl,
    attrs = {
        "contract": attr.string_list(),
        "sources": attr.string_list(),
    },
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

def _forwards_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asset = target[DartCodeAssetInfo]
    asserts.equals(env, "package:code_asset_owner/bridge", asset.asset_id)
    asserts.equals(env, "dynamic_loading_bundle", asset.link_mode)

    # The library the contract describes is the one the asset loads, by
    # identity rather than by extension.
    asserts.equals(
        env,
        [asset.dynamic_library],
        target[FlutterNativeLibraryInfo].libraries.to_list(),
    )
    asserts.equals(env, [asset.dynamic_library], target[DefaultInfo].files.to_list())
    return analysistest.end(env)

_forwards_test = analysistest.make(_forwards_impl)

def _test_host_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    # The test re-declares the library into its own namespace as a symlink;
    # what was built is the symlink's input.
    symlinked = {}
    for a in analysistest.target_actions(env):
        if a.mnemonic == "Symlink":
            for out in a.outputs.to_list():
                symlinked[out.path] = a.inputs.to_list()[0]
    found = [
        f
        for f in target[DefaultInfo].default_runfiles.files.to_list()
        if f.basename.startswith("libbridge.")
    ]
    asserts.equals(env, 1, len(found), "the wrapped library in the test's runfiles: %s" % found)
    if found:
        built = symlinked.get(found[0].path, found[0])
        asserts.false(env, "-exec" in built.path, "built for the test's target, got %s" % built.path)
    return analysistest.end(env)

# A test's `deps` are built for its target, the wrapper — `hot_patch` and
# all — included, and the test loads that library as a plain code asset.
_test_host_test = analysistest.make(_test_host_impl)

def _refuses_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_refuses_test = analysistest.make(
    _refuses_impl,
    attrs = {"message": attr.string()},
    expect_failure = True,
)

_refuses_in_debug_test = analysistest.make(
    _refuses_impl,
    attrs = {"message": attr.string()},
    expect_failure = True,
    config_settings = _DBG,
)

def _analyzes_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

_analyzes_test = analysistest.make(_analyzes_impl)

def code_asset_native_library_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    sources = ["bridge.c", "bridge.h", "helper.c"]
    tests = []

    # Owned by a Flutter package rule, by a Dart one, and by one a rule
    # forwards under `exports`: the walk follows every attribute, so the edge
    # the package arrives on does not matter.
    for owner in ["dart_owner", "plugin_owner", "forwarded_owner"]:
        _dev_config_test(
            name = name + "_dev_config_" + owner,
            target_under_test = _FIXTURE + "app_" + owner,
            contract = ["interface.json"],
            sources = sources,
        )
        _hot_patch_test(
            name = name + "_hot_patch_" + owner,
            target_under_test = _FIXTURE + "app_" + owner,
            expected = ["bridge.hot_patch.json"] + select({
                "@platforms//os:macos": ["libbridge.dylib"],
                "@platforms//os:windows": ["libbridge.dll"],
                "//conditions:default": ["libbridge.so"],
            }),
        )
        tests += [name + "_dev_config_" + owner, name + "_hot_patch_" + owner]

    # Bare: the library is still known by its sources, so a native edit is
    # noticed, and nothing describes its bindings, so the dev tool will not
    # guess that a rebuild of it can serve them.
    _dev_config_test(
        name = name + "_dev_config_bare",
        target_under_test = _FIXTURE + "app_bare_owner",
        contract = [],
        sources = sources,
    )

    # A package that makes its asset with no target of its own leaves nothing
    # for the walk to find. A debug build refuses it rather than describe it as
    # a library with no sources; a build the dev tool never runs bundles it.
    _refuses_in_debug_test(
        name = name + "_refuses_undescribed_in_debug",
        target_under_test = _FIXTURE + "app_inline_owner",
        message = "no target that provides the code asset is reachable",
    )
    _analyzes_test(
        name = name + "_bundles_undescribed_outside_debug",
        target_under_test = _FIXTURE + "app_inline_owner",
    )

    # One library under one id, wrapped in one package and bare in another:
    # which description survived would be graph order.
    _refuses_test(
        name = name + "_refuses_disagreeing_records",
        target_under_test = _FIXTURE + "app_disagreeing_owners",
        message = "disagree about it",
    )
    _forwards_test(
        name = name + "_forwards_the_code_asset",
        target_under_test = _FIXTURE + "wrapped",
    )
    _refuses_test(
        name = name + "_refuses_an_unbundled_asset",
        target_under_test = _FIXTURE + "wrapped_system",
        message = "dynamic_loading_system",
    )
    _test_host_test(
        name = name + "_test_built_for_its_target",
        target_under_test = "//flutter/tests/code_asset_fixture/test:wrapped_code_asset_test",
        target_compatible_with = ["@platforms//os:macos"],
    )
    tests += [
        name + "_test_built_for_its_target",
        name + "_dev_config_bare",
        name + "_forwards_the_code_asset",
        name + "_refuses_an_unbundled_asset",
        name + "_refuses_undescribed_in_debug",
        name + "_bundles_undescribed_outside_debug",
        name + "_refuses_disagreeing_records",
    ]
    native.test_suite(name = name, tests = tests)
