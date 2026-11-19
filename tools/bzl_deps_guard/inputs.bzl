"""The files `//tools/bzl_deps_guard` reads, gathered package by package.

The guard checks every `.bzl` file a consumer's copy of the module has, so
the set of packages it reads is derived, not listed: each package declares
`bzl_library_inputs()`, which holds its own BUILD file and `.bzl` files and
those of every package directly below it. `//:bzl_library_inputs` starts the
walk at the root. A package that does not declare it fails its parent's, so a
new package cannot be left out without the build saying so.

A package that exists only in one checkout, an untracked directory with a
BUILD file, fails the same way. Leave it out of that checkout's builds with
`--deleted_packages=<package>` in its untracked `.bazelrc.user`.
"""

def bzl_library_inputs(name = "bzl_library_inputs", exclude = []):
    """Declares this package's BUILD file and `.bzl` files, and its subpackages'.

    Args:
        name: The target's name, which every package gives it.
        exclude: Patterns of subpackages to leave out, relative to this
            package, as `subpackages()` takes them: those a consumer's copy
            of the module does not have (`.gitattributes`).
    """
    native.filegroup(
        name = name,
        srcs = ["BUILD.bazel"] + native.glob(["*.bzl"], allow_empty = True) + [
            "//%s/%s:%s" % (native.package_name(), package, name)
            for package in native.subpackages(include = ["**"], exclude = exclude, allow_empty = True)
        ],
        visibility = ["//:__subpackages__"],
    )
