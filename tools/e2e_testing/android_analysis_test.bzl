"""Analysis tests of an Android app's split debug info.

An obfuscated app's stack traces read back only through the `.symbols` of the
snapshot it ships. `android_binary` builds its `flutter_android_bundle` once
for each ABI, in configurations of its own, so each `.symbols` must come from
the configuration whose `libapp.so` the app packages: the application built at
the top level compiles another snapshot.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_android//providers:providers.bzl", "AndroidNativeLibsInfo")

_ShippedLibsInfo = provider(
    doc = "The native library zips of the Flutter bundles an app packages, each in the configuration it is packaged from.",
    fields = {"zips": "Depset of the bundles' `libs.zip` files."},
)

# From a release target, an App Bundle, an AAR's repository or module, to the
# Flutter bundles they package.
_EDGES = ["app_bundle", "bundle", "base_module", "module"]

def _targets(value):
    if value == None:
        return []
    return value if type(value) == "list" else [value]

def _flutter_zips(target):
    if AndroidNativeLibsInfo not in target:
        return []
    return [
        f
        for f in target[AndroidNativeLibsInfo].native_libs.to_list()
        if f.path.endswith("_native_libs/libs.zip")
    ]

def _shipped_libs_impl(_target, ctx):
    attrs = ctx.rule.attr
    direct = []
    transitive = []
    for edge in ["deps"] + _EDGES:
        for dep in _targets(getattr(attrs, edge, None)):
            direct += _flutter_zips(dep)
            if _ShippedLibsInfo in dep:
                transitive.append(dep[_ShippedLibsInfo].zips)
    return [_ShippedLibsInfo(zips = depset(direct, transitive = transitive))]

_shipped_libs = aspect(
    implementation = _shipped_libs_impl,
    attr_aspects = _EDGES,
)

def _probe_impl(ctx):
    app = ctx.attr.app
    groups = app[OutputGroupInfo]
    return [OutputGroupInfo(
        debug_info = groups.debug_info if "debug_info" in groups else depset(),
        shipped = app[_ShippedLibsInfo].zips,
    )]

# The app's `debug_info` group, and the native libraries it packages.
_probe = rule(
    implementation = _probe_impl,
    attrs = {"app": attr.label(
        mandatory = True,
        aspects = [_shipped_libs],
    )},
)

def _split_debug_info_impl(ctx):
    env = analysistest.begin(ctx)
    groups = analysistest.target_under_test(env)[OutputGroupInfo]
    symbols = groups.debug_info.to_list()
    asserts.equals(
        env,
        sorted(ctx.attr.symbols),
        sorted([f.basename for f in symbols]),
        "`debug_info` should hold one `.symbols` an ABI, named as `flutter build` names it",
    )

    # Each in the configuration of a `libapp.so` the app packages, one a
    # configuration.
    shipped = sorted({f.root.path: None for f in groups.shipped.to_list()}.keys())
    asserts.equals(env, len(ctx.attr.symbols), len(shipped), "one packaged bundle an ABI: %s" % shipped)
    asserts.equals(
        env,
        shipped,
        sorted([f.root.path for f in symbols]),
        "each `.symbols` should be the one of a snapshot the app packages, built in its bundle's configuration",
    )
    return analysistest.end(env)

_SETTINGS = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:obfuscate")): True,
    str(Label("@rules_dart//dart:split_debug_info")): True,
}

_ALL_ABIS = {str(Label("@rules_android//flags:android_platforms")): [
    str(Label("@rules_android//:armeabi-v7a")),
    str(Label("@rules_android//:arm64-v8a")),
    str(Label("@rules_android//:x86_64")),
]}

_split_debug_info_test = analysistest.make(
    _split_debug_info_impl,
    attrs = {"symbols": attr.string_list(mandatory = True)},
    config_settings = _SETTINGS,
)

_split_debug_info_fat_test = analysistest.make(
    _split_debug_info_impl,
    attrs = {"symbols": attr.string_list(mandatory = True)},
    config_settings = _SETTINGS | _ALL_ABIS,
)

def android_split_debug_info_test(name, target, symbols, all_abis = False):
    """A test that `target`'s `debug_info` group holds the `.symbols` of each snapshot it packages.

    Built `-c opt`, obfuscated, with `--@rules_dart//dart:split_debug_info`.
    Each file must come from the configuration of a `libapp.so` the target
    packages, which the test finds by following the target's edges to the
    Flutter bundles (`app_bundle`, `bundle`, `base_module`, `module`, `deps`).

    Args:
        name: The test's name.
        target: The app: an AAR repository (`flutter_android_aar`), or an
            APK, App Bundle or release.
        symbols: The files' basenames, one an ABI (`app.android-arm64.symbols`).
        all_abis: Build for every ABI rules_flutter builds, a fat APK, rather
            than the command line's `--@rules_android//flags:android_platforms`.
    """
    probe = name + "_probe"
    _probe(name = probe, app = target, tags = ["manual"])
    rule = _split_debug_info_fat_test if all_abis else _split_debug_info_test
    rule(name = name, target_under_test = probe, symbols = symbols)
