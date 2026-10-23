"""Android binary proxy: scope rules_go pure mode to Flutter Android apps.

rules_android's Go host tools (`src/tools/ak` and friends, all cgo-free)
link through rules_go's cgo path, which resolves the hermetic LLVM C++ toolchain
and compiles its runtimes (compiler-rt builtins, libc++, libc++abi, libunwind)
from source: hundreds of C++ actions in every clean Android build.
`--@rules_go//go/config:pure=true` removes them, but as a global flag it would
also force pure mode on a consumer's own cgo Go code, so it is not something to
ask users to set.

`flutter_android_app` therefore puts this proxy rule where the `android_binary`
used to be, and the proxy's outgoing edge transition sets
`@rules_go//go/config:pure` on the binary behind it. The setting is
universal-scoped, so it propagates from the binary's target configuration into
the execution configuration the Go host tools build in (rules_go's own tool
transitions inherit it too). Nothing outside the proxy's subtree sees it:
desktop apps and the consumer's own Go targets keep their configuration.

The proxy forwards the binary's providers and exposes the signed APK under the
proxy's own `<name>.apk` name, so `bazel build`, `data = [...]` consumers and
APK-verifying tests see the same files as before. The binary behind the proxy
is tagged `manual`, so wildcard builds (`//...`) only build the app once,
through the proxy; nothing should reference the private
`__<name>_binary` target directly.
"""

load("@rules_android//providers:providers.bzl", "AndroidFeatureFlagSet", "AndroidInstrumentationInfo", "ApkInfo", "StarlarkApkInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")

def _pure_go_transition_impl(settings, _attr):
    """Set rules_go pure mode for the Android binary subtree, unless opted out.

    Args:
        settings: The incoming configuration. Only `//flutter:android_pure_go`
            is read; everything else passes through untouched.
        _attr: Unused (the opt-out is a flag, not a rule attribute).

    Returns:
        `{"@rules_go//go/config:pure": True}` by default, `{}` when the user
        opts out with `--@rules_flutter//flutter:android_pure_go=false`
        (an empty dict leaves the configuration exactly as it was).
    """
    if settings["//flutter:android_pure_go"]:
        return {"@rules_go//go/config:pure": True}
    return {}

flutter_android_pure_go_transition = transition(
    implementation = _pure_go_transition_impl,
    inputs = ["//flutter:android_pure_go"],
    outputs = ["@rules_go//go/config:pure"],
)

def _flutter_android_binary_proxy_impl(ctx):
    # NOTE: an attribute with a Starlark transition arrives as a single-element
    # list (same as rules_go's go_reset_target: `ctx.attr.dep[0]`).
    binary = ctx.attr.binary[0]
    signed_apk = binary[ApkInfo].signed_apk

    # The binary's own outputs are named after the private binary target
    # (`<name>__binary.apk`); re-expose the signed APK under the proxy's name
    # so the file users build has the name it always had (`<name>.apk`).
    apk = ctx.actions.declare_file(ctx.label.name + ".apk")
    ctx.actions.symlink(output = apk, target_file = signed_apk)

    binary_default = binary[DefaultInfo]
    default_runfiles = binary_default.default_runfiles.merge(
        ctx.runfiles(files = [apk]),
    )
    if binary_default.data_runfiles:
        data_runfiles = binary_default.data_runfiles.merge(
            ctx.runfiles(files = [apk]),
        )
    else:
        data_runfiles = default_runfiles

    providers = [
        DefaultInfo(
            files = depset([apk]),
            default_runfiles = default_runfiles,
            data_runfiles = data_runfiles,
        ),
        binary[ApkInfo],
        binary[JavaInfo],
    ]
    if OutputGroupInfo in binary:
        providers.append(binary[OutputGroupInfo])
    if AndroidFeatureFlagSet in binary:
        providers.append(binary[AndroidFeatureFlagSet])
    if StarlarkApkInfo in binary:
        providers.append(binary[StarlarkApkInfo])
    if AndroidInstrumentationInfo in binary:
        providers.append(binary[AndroidInstrumentationInfo])
    return providers

flutter_android_binary_proxy = rule(
    implementation = _flutter_android_binary_proxy_impl,
    attrs = {
        "binary": attr.label(
            doc = "The APK target built behind this proxy (the apk overlay), in pure-Go configuration.",
            mandatory = True,
            providers = [ApkInfo],
            cfg = flutter_android_pure_go_transition,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = """Builds an android_binary with rules_go pure mode scoped to its subtree.

Forwards the binary's providers and re-exposes its signed APK as `<name>.apk`.
Created by the `flutter_android_app` macro; not for direct use.
""",
)

testing = struct(
    pure_go_transition_impl = _pure_go_transition_impl,
    pure_go_transition = flutter_android_pure_go_transition,
)
