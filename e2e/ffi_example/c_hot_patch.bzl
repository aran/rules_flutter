"""A `flutter_native_library.hot_patch` target for a C library, as a fixture.

Writes the manifest the dev tool reads and builds everything its command needs:
the patch library (a second build of the patchable source, in the app's own
configuration) and the tool that decides what a reload may do with it (built for
the machine the dev tool runs on).
"""

def _c_hot_patch_impl(ctx):
    library = [
        f
        for f in ctx.attr.library[DefaultInfo].files.to_list()
        if f.extension in ("so", "dylib", "dll")
    ]
    patch = [
        f
        for f in ctx.attr.patch_library[DefaultInfo].files.to_list()
        if f.extension in ("so", "dylib", "dll")
    ]
    if len(library) != 1 or len(patch) != 1:
        fail("library and patch_library must each build exactly one shared library")
    tool = ctx.executable.tool

    manifest = ctx.actions.declare_file(ctx.label.name + ".hot_patch.json")
    ctx.actions.write(manifest, json.encode({
        "version": 1,
        "library": library[0].path,
        "sources": [f.path for f in ctx.files.sources],
        "command": [
            tool.path,
            "--library",
            patch[0].path,
            "--contract",
            ctx.file.contract.path,
        ],
    }))
    return [DefaultInfo(files = depset([manifest, tool, patch[0], ctx.file.contract]))]

c_hot_patch = rule(
    implementation = _c_hot_patch_impl,
    attrs = {
        "library": attr.label(mandatory = True, doc = "The library the app bundles."),
        "patch_library": attr.label(mandatory = True, doc = "A build of the patchable code on its own."),
        "contract": attr.label(mandatory = True, allow_single_file = True, doc = "The header a change to which needs a restart."),
        "sources": attr.label_list(allow_files = True, doc = "What a reload stats to decide whether to ask."),
        "tool": attr.label(mandatory = True, executable = True, cfg = "exec"),
    },
)
