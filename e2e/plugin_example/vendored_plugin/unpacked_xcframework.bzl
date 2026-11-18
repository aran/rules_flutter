"""An xcframework as a vendored one arrives in a Bazel build: its files, one by one.

A pod's `vendored_frameworks` or a Swift package's `binaryTarget` is a
directory in a source tree, which `apple_dynamic_xcframework_import` takes as
the files a glob of it lists. A glob follows links, so a versioned (macOS)
framework's links (`Versions/Current`, and the top-level entries into it) are
files too. This unpacks `apple_xcframework`'s archive into those files, so
the fixture is built from source and still arrives as a vendored one does.
"""

def _unpacked_xcframework_impl(ctx):
    prefix = "%s/%s.xcframework/" % (ctx.label.name, ctx.attr.xcframework)
    extracted = [ctx.actions.declare_file(prefix + path) for path in ctx.attr.files]
    by_path = dict(zip(ctx.attr.files, extracted))

    # The archive's own entries. A link in the archive would be extracted as a
    # file holding its target's path, so only real files are named here.
    root = extracted[0].path[:extracted[0].path.index(prefix)]
    args = ctx.actions.args()
    args.add("x")
    args.add(ctx.file.archive)
    args.add("-d", root + ctx.label.name)
    args.add_all(["%s.xcframework/%s" % (ctx.attr.xcframework, path) for path in ctx.attr.files])
    ctx.actions.run(
        executable = ctx.executable._zipper,
        arguments = [args],
        inputs = [ctx.file.archive],
        outputs = extracted,
        mnemonic = "UnpackXCFramework",
        progress_message = "Unpacking %s.xcframework" % ctx.attr.xcframework,
    )

    # A path through a link, which a glob lists as the file it leads to.
    linked = []
    for path, target in sorted(ctx.attr.links.items()):
        link = ctx.actions.declare_file(prefix + path)
        ctx.actions.symlink(output = link, target_file = by_path[target])
        linked.append(link)
    return [DefaultInfo(files = depset(extracted + linked))]

unpacked_xcframework = rule(
    implementation = _unpacked_xcframework_impl,
    attrs = {
        "archive": attr.label(
            doc = "The `apple_xcframework`'s `.xcframework.zip`.",
            allow_single_file = [".zip"],
            mandatory = True,
        ),
        "files": attr.string_list(
            doc = "The xcframework's files in the archive, by their paths in the xcframework.",
            mandatory = True,
        ),
        "links": attr.string_dict(
            doc = "Paths through the archive's links (a versioned framework's), each to the file of `files` it leads to.",
        ),
        "xcframework": attr.string(
            doc = "The xcframework's name, without the extension.",
            mandatory = True,
        ),
        "_zipper": attr.label(
            default = "@bazel_tools//tools/zip:zipper",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "The files of an `apple_xcframework`'s archive, as a vendored xcframework's glob lists them.",
)
