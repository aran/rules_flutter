"""A code-asset rule that is not `dart_code_asset`, as a bridge generator writes one.

A generator that does not depend on rules_flutter hands its library to Dart as a
`DartCodeAssetInfo` from a rule of its own, beside a `DefaultInfo` carrying the
library. This is that shape and nothing more, so the fixture proves the wrapper
reads the provider rather than a particular rule.
"""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo")

def _stand_in_code_asset_impl(ctx):
    library = None
    if ctx.attr.library:
        library = [
            f
            for f in ctx.attr.library[DefaultInfo].files.to_list()
            if f.extension in ("so", "dylib", "dll")
        ][0]
    return [
        DefaultInfo(files = depset([library] if library else [])),
        DartCodeAssetInfo(
            asset_id = ctx.attr.asset_id,
            link_mode = ctx.attr.link_mode,
            dynamic_library = library,
            system_uri = ctx.attr.system_uri,
        ),
    ]

stand_in_code_asset = rule(
    implementation = _stand_in_code_asset_impl,
    attrs = {
        "asset_id": attr.string(mandatory = True),
        "library": attr.label(),
        "link_mode": attr.string(default = "dynamic_loading_bundle"),
        "system_uri": attr.string(),
    },
)
