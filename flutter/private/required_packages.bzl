"""The check that a program's dependencies bring the Dart packages its generated code imports."""

load("@rules_dart//dart:providers.bzl", "DartInfo")

visibility("//flutter/...")

def check_required_packages(label, deps, required):
    """Fails unless the program's dependencies bring each of `required`.

    Stated for what the program needs and the compile would otherwise report as
    an unresolved import in a file the user did not write.

    Args:
        label: The target the failure names.
        deps: The program's dependency targets.
        required: Dart package names the program imports.
    """
    if not required:
        return
    have = {}
    for dep in deps:
        if DartInfo in dep:
            for package in dep[DartInfo].transitive_packages.to_list():
                have[package.package_name] = True
    for name in required:
        if name not in have:
            fail((
                "%s: the program needs `package:%s`, which no dependency of it brings; " +
                "add `@<hub>//:%s` (your pub hub's target for it) to `deps`."
            ) % (label, name, name))
