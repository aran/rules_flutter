"""What the build knows of a `native_deps` entry's native libraries, one record a target.

One aspect walks below each `native_deps` entry (and each code asset's
library) and gives every target it visits a `NativeLibraryFactsInfo`: the
facts a record in `FlutterInfo.native_libraries` holds that only the graph
below the library can say (`native_libraries.bzl`).

`sources`: the first-party sources the library is built from. A hot reload
cannot see that a native library went stale unless something tells it where
that library comes from. For an app whose reload runs a bazel build of
its own — one with generated sources — the build itself moves the library and
the dev tool compares it (`NativeLibsWatch`). Every other app runs no bazel on a
reload at all, so a `.c` or `.rs` edit reached nothing and was reported as
nothing: the reload said "successful" while the app went on running the machine
code it launched with.

These are the files that answer it, collected off the graph below each native
library and stated in `_dev_config.json`. A reload stats them, which is what a
Dart-only edit already pays for its own sources, and a moved one means the app's
native code is behind its sources.

First-party only: a file in another repository is a dependency this app pins, not
something being edited between reloads, and the list is walked on every reload.

Per library, not per app: an app bundles libraries from several places — its own
`native_deps`, a plugin's, a pub package's prebuilt — and an edit to one says
nothing about the others. Answering for all of them would withhold a reload over
a library nobody touched, which is what a shared list did when it was tried.
"""

load("//flutter/private:rule_edges.bzl", "rule_attr_targets")

visibility("//flutter/...")

NativeLibraryFactsInfo = provider(
    doc = "What the build knows of the native libraries at or below this target.",
    fields = {"sources": "depset[File]: The first-party sources they are built from."},
)

# The attributes a native library reaches its own sources through. Named rather
# than `*`: a walk over everything follows toolchains and their sources too, and
# a `bazel-out` path among them would be stat-ed on every reload forever.
#
# `src` and `srcs` are how a wrapper takes the library it passes on — a
# `copy_file` that moves a library under `vendor/lib/`, a genrule that renames
# or stamps one. Without them the walk stops at the wrapper, the library has no
# sources a reload can stat, and an edit to them is reported as nothing.
#
# `file` is how rules_dart's `dart_code_asset` takes its library.
_SOURCE_ATTRS = [
    "src",
    "srcs",
    "deps",
    "dynamic_deps",
    "exports",
    "implementation_deps",
    "library",
    "roots",
    "proc_macro_deps",
    "crate",
    "file",
]

def _native_library_aspect_impl(_target, ctx):
    direct = []
    for attr in ("srcs", "hdrs", "textual_hdrs", "compile_data", "data"):
        for f in getattr(ctx.rule.files, attr, []):
            # `is_source` keeps generated files out: a build output cannot be
            # edited between reloads, and the build that writes it is what the
            # library check already compares.
            if f.is_source and f.owner.workspace_name == "":
                direct.append(f)

    transitive = []
    for dep in rule_attr_targets(ctx.rule.attr, _SOURCE_ATTRS):
        if NativeLibraryFactsInfo in dep:
            transitive.append(dep[NativeLibraryFactsInfo].sources)
    return [NativeLibraryFactsInfo(sources = depset(direct, transitive = transitive))]

native_library_aspect = aspect(
    implementation = _native_library_aspect_impl,
    attr_aspects = _SOURCE_ATTRS,
    doc = "Gives each target below a `native_deps` entry (or a Native Asset library) what the build knows of its native libraries.",
)
