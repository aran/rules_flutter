"""A native library plus the contract its generated bindings were built against.

A `native_deps` entry is ordinarily just a shared library: the app bundles it,
the Dart side `dlopen`s it, and nothing anywhere says what calling into it is
supposed to look like. That is enough to run, and not enough to reload. The dev
tool can see that a rebuild moved the library's bytes, but not whether the
bindings it is about to inject still match it — so it has to assume the worst and
withhold the increment, which is correct and blunt (see `NativeLibsWatch` in the
dev tool).

Wrapping the library here is how a build says what the dev tool cannot infer.
[binding_contract] names the files whose bytes decide what the generated Dart may
call and how it encodes a call — a binding generator's interface description,
or for a hand-written FFI binding, the C header the signatures live in. Equal
bytes mean the bindings are unchanged, so the library the running process
already has can still serve them: the reload goes through and reports the
library's *code* as stale rather than refusing the edit.

Deliberately a wrapper the app author composes rather than a provider the
library's own rule must produce. A bridge generator has no reason to depend on a
Flutter ruleset — most are usable from plain Dart — and an app that wants the
faster reload is the one that knows which of its native deps has a contract and
where it lives. A `native_deps` entry that is not wrapped keeps today's
behaviour exactly.
"""

load("//flutter:providers.bzl", "FlutterNativeLibraryInfo")

_SHARED_LIB_EXTENSIONS = ("so", "dylib", "dll")

def _flutter_native_library_impl(ctx):
    default = ctx.attr.library[DefaultInfo]
    libraries = [
        f
        for f in default.files.to_list()
        if f.extension in _SHARED_LIB_EXTENSIONS
    ]
    if not libraries:
        fail((
            "%s names `library = %s`, which produces no shared library " +
            "(.so/.dylib/.dll). `native_deps` bundles shared libraries, so " +
            "there would be nothing for this wrapper to carry a contract for."
        ) % (ctx.label, ctx.attr.library.label))
    if not ctx.files.binding_contract:
        fail((
            "%s declares an empty `binding_contract`. A wrapper with no " +
            "contract says nothing the bare library does not, and the dev " +
            "tool would withhold a reload after any rebuild of it anyway — " +
            "name the files the bindings are generated from, or drop the " +
            "wrapper and use `%s` directly."
        ) % (ctx.label, ctx.attr.library.label))

    return [
        # Forwarded whole, so every consumer of a `native_deps` entry — the
        # bundlers, which read the files by extension — sees exactly what it
        # would see if the app had named the library directly.
        DefaultInfo(files = default.files, runfiles = default.default_runfiles),
        FlutterNativeLibraryInfo(
            libraries = depset(libraries),
            binding_contract = depset(ctx.files.binding_contract),
        ),
    ]

flutter_native_library = rule(
    implementation = _flutter_native_library_impl,
    doc = """A `native_deps` entry that declares what its bindings were built against.

Put the wrapper in `native_deps` where the library itself would have gone:

```starlark
flutter_native_library(
    name = "bridge",
    library = "@my_bridge//bridge:bridge_shared",
    binding_contract = ["@my_bridge//bridge:codegen.ir"],
)

flutter_application(
    name = "app",
    native_deps = [":bridge"],
    # ...
)
```

What this buys is a hot reload that still works when only the library's *code*
changed. A rebuilt native library can never reach a running process — it keeps
the image it `dlopen`ed — so the dev tool's question is narrower: are the
bindings about to be injected still ones that library can serve? An unchanged
contract answers yes, and the reload is delivered with the stale native code
reported. A changed contract answers no, and the increment is withheld rather
than injected over machine code that cannot decode it.

Both targets must be visible to this rule: a contract in another package or
module needs that package's `visibility` to include it, like any other label.
""",
    attrs = {
        "library": attr.label(
            doc = "The shared library target, as it would appear in `native_deps`.",
            mandatory = True,
            providers = [DefaultInfo],
        ),
        "binding_contract": attr.label_list(
            doc = """Files whose bytes decide what the generated bindings may call.

A binding generator's interface description (frustrate's `codegen.ir`, and the
equivalent from any generator that has one), or the C header a hand-written FFI
binding is written against. The dev tool compares these bytes and nothing else —
it never parses them — so what matters is that every wire-affecting change
reaches them, and that changes which do not affect the wire do not.
""",
            allow_files = True,
            mandatory = True,
        ),
    },
)
