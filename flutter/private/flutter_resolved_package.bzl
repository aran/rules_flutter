"""Spoke for a package `flutter_pub.from_lock(resolve = ...)` maps to a workspace target.

The package's files are in the user's repository, built there by a
`flutter_library`, `flutter_plugin` or `dart_library`. This repository holds one
target, `<package>`, a `resolved_package` over that target (see
`resolved_package.bzl`), so `@<hub>//:<package>` and a hosted package that
depends on the package both reach the one target. It is a forwarding target and
not a copy of the files: a copy would build the package a second time under a
second label, and an edit to the package would not reach the copy until the
repository was fetched again. The locked package, when the lock has it from a
registry or git, is never fetched.

The extension checks the map against the lock when it reads it, and
`resolved_package` checks at analysis that the target declares the package's
name. Neither the target's location nor the lock's version is checked: the map
says where Bazel gets the package.
"""

visibility("//flutter/...")

def _flutter_resolved_package_impl(rctx):
    attr = rctx.attr
    rctx.file("BUILD.bazel", """\
load("@rules_flutter//flutter/private:generated_repos.bzl", "resolved_package")

resolved_package(
    name = {name},
    deps = {actual},
    package_name = {name},
    lock = {lock},
    visibility = ["//visibility:public"],
)
""".format(
        name = repr(attr.package_name),
        actual = repr(attr.actual),
        lock = repr(attr.lock),
    ))

flutter_resolved_package = repository_rule(
    implementation = _flutter_resolved_package_impl,
    attrs = {
        "package_name": attr.string(mandatory = True, doc = "The pub package's name."),
        "actual": attr.string(mandatory = True, doc = "The canonical label of the target that builds the package."),
        "lock": attr.string(mandatory = True, doc = "The lock's label, for messages."),
    },
    doc = "A hub spoke that stands for a lock's package with the workspace target `flutter_pub.from_lock(resolve = ...)` maps it to.",
)
