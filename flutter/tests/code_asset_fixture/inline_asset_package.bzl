"""A Dart package rule that makes its code asset itself, as no target of its own.

The package's `DartInfo` carries a `DartCodeAssetInfo` built from a library
the rule takes directly, so the application bundles the library, and no target
anywhere provides the asset for a walk of the build graph to find. This is the
shape a build cannot describe: nothing says what the library is built from.
"""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo", "DartPackageInfo")

def _inline_asset_package_impl(ctx):
    library = [
        f
        for f in ctx.attr.library[DefaultInfo].files.to_list()
        if f.extension in ("so", "dylib", "dll")
    ][0]
    asset = DartCodeAssetInfo(
        asset_id = "package:%s/bridge" % ctx.attr.package_name,
        link_mode = "dynamic_loading_bundle",
        dynamic_library = library,
        system_uri = "",
    )
    return [DartInfo(
        package_name = ctx.attr.package_name,
        lib_root = ctx.label.package,
        transitive_srcs = depset(),
        transitive_resources = depset(),
        transitive_packages = depset([DartPackageInfo(
            package_name = ctx.attr.package_name,
            lib_root = ctx.label.package,
            code_assets = (asset,),
        )]),
    )]

inline_asset_package = rule(
    implementation = _inline_asset_package_impl,
    attrs = {
        "library": attr.label(mandatory = True),
        "package_name": attr.string(mandatory = True),
    },
)
