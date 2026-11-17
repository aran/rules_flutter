"""The target a `flutter_pub.from_lock(resolve = ...)` package's label is.

The hub's label for a mapped package reaches the user's target through this
rule instead of an `alias`, so that it can check what an alias cannot: the
target builds the package it stands for. The Dart package names the target
declares (`DartInfo.packages`) must include the key it is mapped under, or an
import of `package:<key>/...` would resolve to nothing, or to another package,
in a build that otherwise succeeds. Everything else a Flutter package target
carries is handed on as it is.

The target is held in `deps`, the attribute rules_dart's aspects and
rules_android's dex aspect follow, so they reach the real target through this
one.
"""

load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_info_forwarding.bzl", "flutter_info_forwarding_aspect")

# What a `flutter_library`, `flutter_plugin` or `dart_library` can carry beyond
# `DefaultInfo`, which every target has. A provider the target lacks is left
# out. (`JavaInfo` is not among them: a plugin's Android libraries are reached
# through its `exports` edge, which the aspect follows from the real target.)
_FORWARDED = [DartInfo, DartAnalyzableInfo, FlutterInfo, OutputGroupInfo]

def _resolved_package_impl(ctx):
    target = ctx.attr.deps
    package_name = ctx.attr.package_name

    declared = [p.package_name for p in target[DartInfo].packages]
    if package_name not in declared:
        fail("{target} stands in for the pub package \"{package}\" (flutter_pub.from_lock(resolve = ...) in {lock}), but it declares {declared}. Set its package_name to \"{package}\".".format(
            target = target.label,
            package = package_name,
            lock = ctx.attr.lock,
            declared = "no package" if not declared else "the package " + ", ".join(["\"{}\"".format(d) for d in declared]),
        ))

    return [target[DefaultInfo]] + [target[p] for p in _FORWARDED if p in target]

resolved_package = rule(
    implementation = _resolved_package_impl,
    attrs = {
        "deps": attr.label(
            mandatory = True,
            providers = [DartInfo],
            doc = "The target that builds the package.",
            aspects = [flutter_info_forwarding_aspect],
        ),
        "package_name": attr.string(mandatory = True, doc = "The pub package's name: the key it is mapped under."),
        "lock": attr.string(doc = "The lock's label, for messages."),
    },
    doc = "A package target that is the user's, and fails analysis when it declares another package name. See the file docstring.",
)
