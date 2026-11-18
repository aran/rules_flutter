"""An Android library that links prebuilt shared libraries, as one over a `cc_library` does."""

load("@rules_android//providers:providers.bzl", "AndroidCcLinkParamsInfo")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")

def _cc_like_impl(ctx):
    # The host's toolchain: analysis needs one to describe a library, and the
    # fixture has no NDK.
    cc_toolchain = ctx.attr._cc_toolchain[cc_common.CcToolchainInfo]
    feature_configuration = cc_common.configure_features(ctx = ctx, cc_toolchain = cc_toolchain)
    libraries = [
        cc_common.create_library_to_link(
            actions = ctx.actions,
            feature_configuration = feature_configuration,
            cc_toolchain = cc_toolchain,
            dynamic_library = f,
        )
        for f in ctx.files.shared
    ]
    own = CcInfo(linking_context = cc_common.create_linking_context(linker_inputs = depset([
        cc_common.create_linker_input(owner = ctx.label, libraries = depset(libraries)),
    ])))
    link_params = cc_common.merge_cc_infos(cc_infos = [own] + [
        d[AndroidCcLinkParamsInfo].link_params
        for d in ctx.attr.deps
    ])
    return [
        ctx.attr.lib[JavaInfo],
        AndroidCcLinkParamsInfo(link_params = link_params),
    ]

cc_like = rule(
    implementation = _cc_like_impl,
    attrs = {
        "lib": attr.label(mandatory = True, providers = [JavaInfo]),
        "shared": attr.label_list(allow_files = [".so"]),
        "deps": attr.label_list(
            doc = "Other `cc_like` libraries whose shared libraries this one links.",
            providers = [AndroidCcLinkParamsInfo],
        ),
        "_cc_toolchain": attr.label(
            default = "@rules_cc//cc:current_cc_toolchain",
            cfg = "exec",
        ),
    },
    fragments = ["cpp"],
    doc = "Forwards `lib` and links the shared libraries `shared` and those of `deps`.",
)
