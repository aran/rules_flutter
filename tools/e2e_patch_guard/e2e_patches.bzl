"""Repository rule exposing the e2e workspaces' patch files to the root module.

`e2e/` is in `.bazelignore` (each workspace is its own Bazel project), so the
root cannot name those files as labels. This rule links every
`e2e/<workspace>/patches/*.patch` into a repo as `<workspace>/<file>` and
writes `index.txt`, one `<workspace>/<file>` per line.
"""

def _impl(rctx):
    e2e = rctx.path(Label("//:MODULE.bazel")).dirname.get_child("e2e")
    rctx.watch(e2e)
    index = []
    for workspace in sorted([d for d in e2e.readdir() if d.is_dir], key = lambda d: d.basename):
        patches = workspace.get_child("patches")
        if not patches.exists:
            continue
        rctx.watch(patches)
        for patch in sorted(patches.readdir(), key = lambda p: p.basename):
            if not patch.basename.endswith(".patch"):
                continue
            name = "%s/%s" % (workspace.basename, patch.basename)
            rctx.symlink(patch, name)
            index.append(name)
    rctx.file("index.txt", "\n".join(index) + "\n")
    rctx.file("BUILD.bazel", """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "patches",
    srcs = glob(["*/*.patch"]) + ["index.txt"],
)
""")

e2e_patches = repository_rule(
    implementation = _impl,
    local = True,
    doc = "Links `e2e/*/patches/*.patch` into a repo, with an `index.txt` listing them.",
)
