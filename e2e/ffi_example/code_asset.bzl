"""A code asset from a rule that is not `dart_code_asset`, as a fixture.

A bridge generator that does not depend on rules_flutter hands its library to
Dart from a rule of its own: a `DartCodeAssetInfo` naming the library, and a
`DefaultInfo` carrying it, and what the library was linked from, which an Apple
app's dSYM of it is read from. This is that shape and nothing more.

It builds `DartCodeAssetInfo` itself, so it sets `link_inputs` itself, from the
action that linked the library; `DartLinkInputsInfo` is what a rule states to a
`dart_code_asset` that binds its library.
"""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo")

_LinkInputsInfo = provider(
    doc = "The inputs of the action that linked a library.",
    fields = {"link_inputs": "depset[File]"},
)

def _link_inputs_aspect_impl(target, _ctx):
    links = [
        action.inputs
        for action in target.actions
        if action.mnemonic in ("CppLink", "ObjcLink")
    ]
    if len(links) != 1:
        fail("%s must link exactly one library" % target.label)
    return [_LinkInputsInfo(link_inputs = links[0])]

# The inputs of the action that linked the library.
_link_inputs_aspect = aspect(implementation = _link_inputs_aspect_impl)

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
            file = libraries[0],
            uri = "",
            link_inputs = ctx.attr.library[_LinkInputsInfo].link_inputs,
        ),
    ]

stand_in_code_asset = rule(
    implementation = _stand_in_code_asset_impl,
    attrs = {
        "asset_id": attr.string(mandatory = True, doc = "The id the owning package's bindings use."),
        "library": attr.label(mandatory = True, aspects = [_link_inputs_aspect], doc = "The shared library the asset loads."),
    },
)
