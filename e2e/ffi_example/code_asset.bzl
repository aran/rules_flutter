"""A code asset from a rule that is not `dart_code_asset`, as a fixture.

A bridge generator that does not depend on rules_flutter hands its library to
Dart from a rule of its own: a `DartCodeAssetInfo` naming the library, and a
`DefaultInfo` carrying it. This is that shape and nothing more.
"""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo")

def _stand_in_code_asset_impl(ctx):
    libraries = [
        f
        for f in ctx.attr.library[DefaultInfo].files.to_list()
        if f.extension in ("so", "dylib", "dll")
    ]
    if len(libraries) != 1:
        fail("library must build exactly one shared library")
    return [
        DefaultInfo(files = depset(libraries)),
        DartCodeAssetInfo(
            asset_id = ctx.attr.asset_id,
            link_mode = "dynamic_loading_bundle",
            dynamic_library = libraries[0],
            system_uri = "",
        ),
    ]

stand_in_code_asset = rule(
    implementation = _stand_in_code_asset_impl,
    attrs = {
        "asset_id": attr.string(mandatory = True, doc = "The id the owning package's bindings use."),
        "library": attr.label(mandatory = True, doc = "The shared library the asset loads."),
    },
)
