"""The first-party sources an app's native libraries are built from.

A hot reload cannot see that a native library went stale unless something tells
it where that library comes from. For an app whose reload runs a bazel build of
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

NativeSourcesInfo = provider(
    doc = "Source files a native library below this target is built from.",
    fields = {"sources": "depset[File]"},
)

# The attributes a native library reaches its own sources through. Named rather
# than `*`: a walk over everything follows toolchains and their sources too, and
# a `bazel-out` path among them would be stat-ed on every reload forever.
_SOURCE_ATTRS = [
    "deps",
    "dynamic_deps",
    "exports",
    "implementation_deps",
    "library",
    "roots",
    "proc_macro_deps",
    "crate",
]

def _native_sources_aspect_impl(_target, ctx):
    direct = []
    for attr in ("srcs", "hdrs", "textual_hdrs", "compile_data", "data"):
        for f in getattr(ctx.rule.files, attr, []):
            # `is_source` keeps generated files out: a build output cannot be
            # edited between reloads, and the build that writes it is what the
            # library check already compares.
            if f.is_source and f.owner.workspace_name == "":
                direct.append(f)

    transitive = []
    for attr in _SOURCE_ATTRS:
        value = getattr(ctx.rule.attr, attr, None)
        for dep in value if type(value) == "list" else [value]:
            if type(dep) == "Target" and NativeSourcesInfo in dep:
                transitive.append(dep[NativeSourcesInfo].sources)
    return [NativeSourcesInfo(sources = depset(direct, transitive = transitive))]

native_sources_aspect = aspect(
    implementation = _native_sources_aspect_impl,
    attr_aspects = _SOURCE_ATTRS,
    doc = "Collects the first-party sources a `native_deps` entry (or a Native Asset library) is built from.",
)

def collect_native_sources(targets):
    """The sources below [targets], as one depset.

    Args:
        targets: Targets the `native_sources_aspect` was applied to.

    Returns:
        depset[File] of first-party source files.
    """
    return depset(transitive = [
        target[NativeSourcesInfo].sources
        for target in targets
        if NativeSourcesInfo in target
    ])

# Mirrors `_NATIVE_LIBRARY_EXTENSIONS` in `flutter_native_library.bzl`: the
# files a `native_deps` entry contributes to a bundle.
_LIBRARY_EXTENSIONS = ("so", "dylib", "dll")

def collect_native_source_pairs(native_deps):
    """Pair each `native_deps` entry's libraries with the sources they are built from.

    The same shape as `collect_binding_contracts`, and for the same reason: the
    dev tool's question is per library.

    Args:
        native_deps: The `native_deps` targets, wrapped or bare.

    Returns:
        List of `struct(library = File, sources = tuple[File])`.
    """
    pairs = []
    for dep in native_deps:
        sources = tuple(collect_native_sources([dep]).to_list())
        for f in dep[DefaultInfo].files.to_list():
            if f.extension in _LIBRARY_EXTENSIONS:
                pairs.append(struct(library = f, sources = sources))
    return pairs
