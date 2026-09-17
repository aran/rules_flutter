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

On web the same wrapper goes in a web bundle's `native_modules` instead, where
declaring it does a second job: the bundle directory also holds Flutter's own
`main.dart.wasm`, which changes on every Dart edit, so a watch that recognised a
module by its extension would flag every reload. Nothing can infer which served
file is a native module — only the build knows.

Deliberately a wrapper the app author composes rather than a provider the
library's own rule must produce. A bridge generator has no reason to depend on a
Flutter ruleset — most are usable from plain Dart — and an app that wants the
faster reload is the one that knows which of its native deps has a contract and
where it lives. A `native_deps` entry that is not wrapped keeps today's
behaviour exactly.
"""

load("//flutter:providers.bzl", "FlutterNativeLibraryInfo")

# A wasm module belongs here for the same reason a dylib does: the page
# instantiates it once and a hot reload cannot replace the instance, so the
# bindings about to be injected have to be ones that instance can serve. What
# differs is only how it reaches the app — served by URL rather than bundled and
# `dlopen`ed — and that difference is the web rule's, not this one's.
_NATIVE_LIBRARY_EXTENSIONS = ("so", "dylib", "dll", "wasm")

# The one file in a `hot_patch` target the dev tool looks for by name. Everything
# else that target builds rides along for the command the manifest names.
_HOT_PATCH_MANIFEST_SUFFIX = ".hot_patch.json"

def _flutter_native_library_impl(ctx):
    default = ctx.attr.library[DefaultInfo]
    libraries = [
        f
        for f in default.files.to_list()
        if f.extension in _NATIVE_LIBRARY_EXTENSIONS
    ]
    if not libraries:
        fail((
            "%s names `library = %s`, which produces no native library " +
            "(.so/.dylib/.dll/.wasm), so there would be nothing for this " +
            "wrapper to carry a contract for."
        ) % (ctx.label, ctx.attr.library.label))
    if not ctx.files.binding_contract:
        fail((
            "%s declares an empty `binding_contract`. A wrapper with no " +
            "contract says nothing the bare library does not, and the dev " +
            "tool would withhold a reload after any rebuild of it anyway — " +
            "name the files the bindings are generated from, or drop the " +
            "wrapper and use `%s` directly."
        ) % (ctx.label, ctx.attr.library.label))

    hot_patch = None
    if ctx.attr.hot_patch:
        patch_files = ctx.attr.hot_patch[DefaultInfo].files
        manifests = [
            f
            for f in patch_files.to_list()
            if f.basename.endswith(_HOT_PATCH_MANIFEST_SUFFIX)
        ]
        if len(manifests) != 1:
            fail((
                "%s names `hot_patch = %s`, which produces %d `*%s` files. " +
                "The dev tool reads exactly one manifest per library: it says " +
                "which library the patches are for and how to build them."
            ) % (ctx.label, ctx.attr.hot_patch.label, len(manifests), _HOT_PATCH_MANIFEST_SUFFIX))
        hot_patch = struct(manifest = manifests[0], files = patch_files)

    return [
        # Forwarded whole, so every consumer of a `native_deps` entry — the
        # bundlers, which read the files by extension — sees exactly what it
        # would see if the app had named the library directly.
        DefaultInfo(files = default.files, runfiles = default.default_runfiles),
        FlutterNativeLibraryInfo(
            libraries = depset(libraries),
            binding_contract = depset(ctx.files.binding_contract),
            hot_patch = hot_patch,
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

`hot_patch` goes further: it lets a hot reload deliver the library's new *code*
into the running process, where a bare contract can only report it stale. See the
attribute for what the named target has to build.
""",
    attrs = {
        "library": attr.label(
            doc = """The native library target, as it would appear in `native_deps` (or in a web bundle's `native_modules`).

A shared library on a native platform; a `.wasm` module on web. Usually a rule's
output, and a checked-in prebuilt file works too.
""",
            allow_files = True,
            mandatory = True,
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
        "hot_patch": attr.label(
            doc = """A target that builds patches of `library` for a running app. Optional.

A process can never replace a library it has `dlopen`ed, but it can load a second
one and send calls there. A toolchain that knows how to build such a patch from
the edited sources, and a library whose calls can be redirected into it, name the
target that does it here, and a hot reload then delivers the edit instead of
reporting the running code stale. The patch format and the redirection belong to
the library's language and bridge; the dev tool only builds, delivers, loads and
reports.

The target is built in the same configuration as `library` — the device's, not
the host's — and must put exactly one `*.hot_patch.json` file in its
`DefaultInfo`. The dev tool builds everything in that `DefaultInfo`, reads the
manifest, and runs the command it names from the execution root:

```json
{
  "version": 1,
  "library": "<exec-root path of the library this patches>",
  "sources": ["<workspace-relative files whose edit can change the library>"],
  "command": ["<exec-root-relative argv>"]
}
```

`command snapshot --state <dir>` runs once per launch and prints one JSON line,
`{"status": "ok"}` or `{"status": "failed", "message": ...}`. `command patch
--state <dir> --symbol flutter_hot_patch_apply=0x<address> --out <dir>` runs on
each hot reload that finds the library or a source moved, and prints one JSON
line — `unchanged`, `patched` (with the patch `file`), `restart` (with
human-readable `reasons`), or `failed` (with a `message`). stderr is for
diagnostics; the dev tool quotes the JSON. The library exports `uint32_t flutter_hot_patch_abi(void)`,
returning 1, and `int32_t flutter_hot_patch_apply(const char *patch_path, char
*message, size_t message_capacity)`, which the app calls with the delivered file
and which returns 0 or writes why it refused. A null `patch_path` sends calls back
to the code the library launched with: that is how the dev tool undoes a patched
edit that was reverted, which `patch` answers as `unchanged`.

The library must carry its linker's identity — `LC_UUID` on Mach-O (ld64 writes
one by default), a GNU build-id on ELF (`-Wl,--build-id`). A build can produce
the same library in more than one configuration, and the identity is how the dev
tool finds the one the app bundled.

Only files are built, not runfiles trees: the command has to run with nothing but
the files this target builds.
""",
        ),
    },
)
