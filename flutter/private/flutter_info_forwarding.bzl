"""Forwards `FlutterInfo` through Dart targets that do not build it.

Only Flutter's rules build `FlutterInfo`. A Dart target of another rule set
(rules_dart's `dart_library`, the `pub_library` a pure-Dart pub package is
built as) does not, so what lies below one (a plugin, the assets, fonts,
shaders and native libraries of a package) would reach no application above
it, with nothing failing. flutter_tools sees every package an application
reaches, whatever the packages between are.

Every attribute of rules_flutter that reads `FlutterInfo` from its
dependencies applies this aspect. On a Dart target without `FlutterInfo`,
it returns the merge of its `deps`' (their own, or this aspect's on them),
so a reader indexes `dep[FlutterInfo]` and sees everything below the edge,
whichever rule built the target. A target that builds `FlutterInfo` merges
its own dependencies' already; the aspect returns nothing on it, and nothing
on a target whose `deps` carry none.

A Dart target of the main repository states its dependencies as the
application's direct ones (`app_dependencies`), as a `flutter_library` of
the main repository does.

A rules_dart `pub_library` names its packages in `members`, which have no
dependencies of their own. A Flutter pub package (`flutter_pub_member`) among
them contributes what it would to a `flutter_pub_library`.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_info.bzl", "direct_package_names", "flutter_info")
load("//flutter/private:flutter_pub_member_info.bzl", "member_contributions")

def _targets_of(ctx, name):
    # An attribute of that name may be a single label, or absent.
    value = getattr(ctx.rule.attr, name, None)
    if value == None:
        return []
    if type(value) != "list":
        value = [value]
    return [t for t in value if type(t) == "Target"]

def _flutter_info_forwarding_impl(target, ctx):
    if FlutterInfo in target or DartInfo not in target:
        return []
    all_deps = _targets_of(ctx, "deps")
    deps = [d for d in all_deps if FlutterInfo in d]
    contributions = member_contributions(_targets_of(ctx, "members"))
    if not deps and not contributions:
        return []
    return [flutter_info(
        deps = deps,
        # As a `flutter_library`'s: a Dart target of the main repository is
        # the application's own code, whose dependencies are the
        # application's direct ones.
        app_dependencies = [] if target.label.repo_name else direct_package_names(all_deps),
        **contributions
    )]

flutter_info_forwarding_aspect = aspect(
    implementation = _flutter_info_forwarding_impl,
    attr_aspects = ["deps"],
    doc = "Returns, on a Dart target without `FlutterInfo`, the merge of its `deps`' `FlutterInfo` and its Flutter `members`' contributions.",
)
