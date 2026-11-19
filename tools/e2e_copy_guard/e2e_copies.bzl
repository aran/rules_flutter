"""Repository rule exposing files the e2e workspaces each carry a copy of.

`e2e/` is in `REPO.bazel`'s `ignore_directories` (each workspace is its own
Bazel project), so the root cannot name those files as labels. This rule links
two kinds of file into a repo, for `//tools/e2e_copy_guard:copies_identical_test` to compare:

* every `e2e/<workspace>/patches/*.patch`, as `<workspace>/<file>`, listed one
  per line in `index.txt`;
* the files of each group in `MIRRORED` (`mirrored.bzl`), as `mirrored/<path>`, listed as
  `<group>\\t<path>` in `mirrored.txt`, and the `.bazelversion` of the root and
  of every e2e workspace (a directory with a `MODULE.bazel`), as one more group;
* the `.bazelrc` of the root and of every e2e workspace, as `bazelrc/<path>`,
  listed in `bazelrcs.txt`. A `.bazelrc` is not a copy as a whole, but the
  `--incompatible_*` flags in it are, and the test compares those.
"""

load(":mirrored.bzl", "MIRRORED")

def _workspaces(root, directory):
    """The repo-root-relative paths of the e2e workspaces under `directory`.

    A directory with a `MODULE.bazel` is a workspace, and the walk stops
    there. A directory without one is searched a level down, as
    `findWorkspaces` (`tools/e2e_workspaces`) would find a workspace there.
    Starlark cannot recurse, and nothing nests deeper.
    """
    found = []
    for entry in sorted(root.get_child(directory).readdir(), key = lambda e: e.basename):
        if not _is_candidate(entry):
            continue
        path = directory + "/" + entry.basename
        if entry.get_child("MODULE.bazel").exists:
            found.append(path)
            continue
        for inner in sorted(entry.readdir(), key = lambda e: e.basename):
            if _is_candidate(inner) and inner.get_child("MODULE.bazel").exists:
                found.append(path + "/" + inner.basename)
    return found

def _is_candidate(entry):
    name = entry.basename
    return entry.is_dir and not (name.startswith(".") or name.startswith("bazel-") or name == "node_modules")

def _impl(rctx):
    root = rctx.path(Label("//:MODULE.bazel")).dirname
    e2e = root.get_child("e2e")
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

    groups = dict(MIRRORED)
    groups[".bazelversion"] = [".bazelversion"] + [
        "%s/.bazelversion" % workspace
        for workspace in _workspaces(root, "e2e")
    ]

    mirrored = []
    for group, paths in sorted(groups.items()):
        for path in paths:
            source = root.get_child(path)
            if not source.exists:
                fail("mirrored group %r names %s, which does not exist" % (group, path))
            rctx.watch(source)
            rctx.symlink(source, "mirrored/" + path)
            mirrored.append("%s\t%s" % (group, path))
    rctx.file("mirrored.txt", "\n".join(mirrored) + "\n")

    bazelrcs = []
    for path in [".bazelrc"] + ["%s/.bazelrc" % workspace for workspace in _workspaces(root, "e2e")]:
        source = root.get_child(path)
        if not source.exists:
            fail("%s does not exist: the root and every e2e workspace has a .bazelrc" % path)
        rctx.watch(source)
        rctx.symlink(source, "bazelrc/" + path)
        bazelrcs.append(path)
    rctx.file("bazelrcs.txt", "\n".join(bazelrcs) + "\n")

    rctx.file("BUILD.bazel", """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "copies",
    srcs = glob(["*/*.patch", "mirrored/**", "bazelrc/**"]) + ["index.txt", "mirrored.txt", "bazelrcs.txt"],
)
""")

e2e_copies = repository_rule(
    implementation = _impl,
    local = True,
    doc = "Links `e2e/*/patches/*.patch`, the files of each `MIRRORED` group and the `.bazelrc` files into a repo, with indexes listing them.",
)
