"""The libraries a `native_deps` library loads at run time, which an app bundles beside it.

A `cc_shared_library` that names another in `dynamic_deps` links against it
rather than into it: the library it makes records the other by name, and the
loader looks for that name when it loads it. Its `DefaultInfo` holds its own
library only, so an app that bundled the files of its `native_deps` and
nothing else shipped a library that fails to load on any platform but the one
the build ran on, where the loader may still find the other in the build tree.
The same goes for a library its `deps` reach only as a shared library (a
`cc_import` of one), which rules_cc links against and keeps in its
`CcSharedLibraryInfo.linker_input` beside its own. A native build that links
them installs them beside it, and `flutter build` installs what its CMake
links: an app bundles each of them as it does a `native_deps` library.

This aspect follows `dynamic_deps` below each `native_deps` entry, through
the attributes a wrapper passes a library on by, and gives each library it
finds what its record holds (`native_libraries.bzl`): its sources, as
`native_library_aspect` collects them below it, and its link, as
`native_link_aspect` finds it, both of which it requires.
"""

load("@rules_cc//cc/common:cc_shared_library_info.bzl", "CcSharedLibraryInfo")
load("//flutter/private:constants.bzl", "SHARED_LIBRARY_EXTENSIONS")
load("//flutter/private:native_library_aspect.bzl", "NativeLibraryFactsInfo", "native_library_aspect")
load("//flutter/private:native_link_aspect.bzl", "NativeLinkInfo", "native_link_aspect")
load("//flutter/private:rule_edges.bzl", "rule_attr_targets")

visibility("//flutter/...")

NativeDynamicDepsInfo = provider(
    doc = "The libraries the native libraries at or below this target load at run time, which an app bundles beside them.",
    fields = {
        "libraries": "depset[struct]: One for each library, with `library` (File), `sources`, `link_inputs`, `dsym` and `link_inputs_unset_reason`, as a record in `FlutterInfo.native_libraries` holds them.",
    },
)

# The attributes a wrapper takes the library it passes on by, as
# `native_link_aspect` follows them.
_LIBRARY_ATTRS = ["library", "file", "srcs", "src"]

def _shared_libraries(target):
    return [f for f in target[DefaultInfo].files.to_list() if f.extension in SHARED_LIBRARY_EXTENSIONS]

def _of_target(dep):
    """The facts of each library `dep`, a `cc_shared_library`, makes."""
    sources = tuple(dep[NativeLibraryFactsInfo].sources.to_list()) if NativeLibraryFactsInfo in dep else ()
    link = dep[NativeLinkInfo]
    return [
        struct(
            library = f,
            sources = sources,
            link_inputs = link.link_inputs,
            dsym = link.dsym,
            link_inputs_unset_reason = link.link_inputs_unset_reason,
        )
        for f in _shared_libraries(dep)
    ]

def _precompiled(target):
    """The shared libraries `target` links against that no `dynamic_deps` entry makes.

    rules_cc lists them after the target's own library in its linker input.
    A checked-in one was linked from nothing in the build, as a prebuilt
    `native_deps` library was; the link of a generated one is not followed.
    """
    own = {f: True for f in target[DefaultInfo].files.to_list()}
    found = []
    for lib in target[CcSharedLibraryInfo].linker_input.libraries:
        f = lib.resolved_symlink_dynamic_library or lib.dynamic_library
        if f == None or f in own or lib.dynamic_library in own:
            continue
        if f.is_source:
            link_inputs, reason = depset(), None
        else:
            link_inputs, reason = None, (
                "%s links against %s, which %s reaches as a precompiled library, so what it was " +
                "linked from is unknown. Name the target that links it in `dynamic_deps`."
            ) % (target.label, f.short_path, target.label)
        found.append(struct(
            library = f,
            sources = (),
            link_inputs = link_inputs,
            dsym = None,
            link_inputs_unset_reason = reason,
        ))
    return found

def _native_dynamic_deps_aspect_impl(target, ctx):
    direct = []
    transitive = []
    if CcSharedLibraryInfo in target:
        for dep in getattr(ctx.rule.attr, "dynamic_deps", []):
            direct.extend(_of_target(dep))
            transitive.append(dep[NativeDynamicDepsInfo].libraries)
        direct.extend(_precompiled(target))
    for dep in rule_attr_targets(ctx.rule.attr, _LIBRARY_ATTRS):
        if NativeDynamicDepsInfo in dep:
            transitive.append(dep[NativeDynamicDepsInfo].libraries)
    return [NativeDynamicDepsInfo(libraries = depset(direct, transitive = transitive))]

native_dynamic_deps_aspect = aspect(
    implementation = _native_dynamic_deps_aspect_impl,
    attr_aspects = _LIBRARY_ATTRS + ["dynamic_deps"],
    # A label naming the library file itself reaches the rule that wrote it.
    apply_to_generating_rules = True,
    requires = [native_library_aspect, native_link_aspect],
    doc = "Gives each target below a `native_deps` entry the libraries its libraries load at run time from `dynamic_deps`.",
)
