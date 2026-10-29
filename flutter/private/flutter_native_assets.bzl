"""`flutter_native_assets_manifest` — emits the `--native-assets` JSON
manifest the Flutter frontend_server reads.

The frontend_server's `--native-assets` flag points at a JSON file in
the format produced by Flutter's frontend_server (see
`packages/flutter_tools/lib/src/isolated/native_assets/dart_hook_result.dart`
in the flutter/flutter repository). Per-target
section, per-asset entry:

    {
      "format-version": [1, 0, 0],
      "native-assets": {
        "macos_arm64": {
          "package:objective_c/objective_c.dylib": ["absolute", "objective_c.dylib"],
          "package:libsqlite3/libsqlite3.so": ["system", "libsqlite3.so.0"]
        }
      }
    }

The manifest is always emitted, even when the depset is empty
(`{"format-version":[1,0,0],"native-assets":{}}`). That keeps the
kernel-compile path uniform — no `if manifest:` branches downstream.

The Flutter engine reads the relative-path entries verbatim and
`dlopen`s them inside the platform bundle slot:

  * macOS: `<App>.app/Contents/Frameworks/<basename>` (loose dylib)
  * iOS:   `<App>.app/Frameworks/<name>.framework/<name>` — iOS forbids
           loose embedded dylibs, so each `dynamic_loading_bundle` library is
           wrapped in its own `.framework` (matching flutter_tools'
           `frameworkUri`). The manifest entry is the framework-relative path.

Several asset ids may name one library. It is bundled once — one file, or one
framework on iOS — and every id's entry names it, so the loader opens one image
for all of them.
  * Linux: `<bundle>/lib/<basename>` (resolved relative to the runner)
  * Windows: next to the runner exe
  * Android: `lib/<abi>/<basename>` inside the APK

Multi-arch Apple builds are out of scope: rules_flutter targets one
arch per `bazel build` invocation. Universal binaries flow through
`apple_universal_binary` over the dylib outputs at the user's
discretion.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_transitive_code_assets", "resolve_code_assets")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterNativeAssetInfo")

# Map (target_os, arch) → the Target string Dart's
# `Target.fromArchitectureAndOS` would produce. Keep this mirrored
# with the `hooks_runner` package's `lib/src/model/target.dart`
# (published on pub.dev). The string format is `<os>_<arch>` with
# OS lowercased and architecture lowercased (e.g. `macos_arm64`,
# `ios_arm64`, `linux_x64`, `windows_x64`, `android_arm64`).
_OS_ARCH_TO_TARGET = {
    ("macos", "arm64"): "macos_arm64",
    ("macos", "x64"): "macos_x64",
    ("ios", "arm64"): "ios_arm64",
    ("ios", "x64"): "ios_x64",
    ("linux", "arm64"): "linux_arm64",
    ("linux", "x64"): "linux_x64",
    ("linux", "arm"): "linux_arm",
    ("windows", "arm64"): "windows_arm64",
    ("windows", "x64"): "windows_x64",
    ("android", "arm64"): "android_arm64",
    ("android", "arm"): "android_arm",
    ("android", "x64"): "android_x64",
}

CODE_ASSETS_DOC = """Code assets this program loads, each replacing the asset `deps` supply under its id.

Each entry provides `DartCodeAssetInfo`: a `dart_code_asset`, a
`flutter_native_library` wrapping one, or any rule that provides it. An entry is
this program's choice of library for its asset id, so it replaces whatever the
packages in `deps` (or a `flutter_native_asset`) supply under that id, as
`code_assets` does on rules_dart's `dart_binary` and `dart_test`. Ids no entry
names keep the asset `deps` supply.

Several entries may name one library, to serve several packages' ids from one
shared library. It is bundled once (one file; one framework on iOS) and every
id's manifest entry names it, so the process loads one image of it: one copy of
its static state, whichever id a call goes through.

```starlark
dart_code_asset(name = "a_combined", asset_id = "package:a/a", shared_library = ":combined")
dart_code_asset(name = "b_combined", asset_id = "package:b/b", shared_library = ":combined")

flutter_application(
    name = "app",
    deps = ["//a", "//b"],
    code_assets = [":a_combined", ":b_combined"],
)
```
"""

def native_asset_framework_name(filename):
    """Derive the framework name for a bundled native-asset dylib on Apple.

    Mirrors flutter_tools' `frameworkUri` (native_assets_host.dart): strip a
    trailing `.dylib`, drop a leading `lib`, and sanitize to `[A-Za-z0-9_-]`.
    iOS embeds each `dynamic_loading_bundle` dylib as `<name>.framework/<name>`.
    The manifest path and the framework-assembly rule both call this so they
    agree on the name.

    Args:
      filename: The dylib's basename (e.g. `objective_c.dylib`).

    Returns:
      The sanitized framework name (e.g. `objective_c`).
    """
    name = filename
    if name.endswith(".dylib"):
        name = name[:-len(".dylib")]
        if name.startswith("lib"):
            name = name[len("lib"):]
    sanitized = ""
    for c in name.elems():
        if c.isalnum() or c == "_" or c == "-":
            sanitized += c
    return sanitized

def _path_list_for(asset, target_os, layout):
    """Return the manifest path-list shape for `asset`.

    For `dynamic_loading_bundle` the engine's `KernelAssetAbsolutePath` is the
    path it `dlopen`s. Under `layout = "bundle"` that is resolved inside the
    platform bundle slot: on iOS the dylib is wrapped in a `.framework`, so the
    path is `<name>.framework/<name>`; every other OS places a loose
    dylib/so/dll and uses the bare basename.

    Under `layout = "runfiles"` there is no bundle — a `flutter_test` runs out
    of Bazel's runfiles tree — so the entry is the library's runfiles-relative
    path. A path with a separator in it is resolved by the loader against the
    process's working directory, and Bazel runs a test with that set to the
    runfiles root, so the same string works for every asset without the runner
    having to rewrite the manifest (it is baked into the kernel at build time
    and cannot be rewritten later).

    That last part is why this is unverified on Windows: without
    `--enable_runfiles` Bazel there uses a runfiles *manifest* instead of a
    symlink tree, so no such relative path exists on disk to resolve against.
    A Windows `flutter_test` reaching a `dynamic_loading_bundle` asset is
    expected to fail at the first `@Native` call rather than silently — the
    engine reports the unresolved id — but nothing here has been run on
    Windows to confirm the shape of that failure.
    """
    if asset.link_mode == "dynamic_loading_bundle":
        if layout == "library_path":
            # Found by name on the loader's search path, which the runner sets
            # to the one directory the libraries are staged in, so the program
            # may run from any working directory.
            return ["system", asset.bundle_filename]
        if layout == "runfiles":
            # `dlopen` searches its loader paths for a name with no separator
            # in it, rather than opening it as a file. A consumer in the
            # workspace root package declares the symlink there, so `short_path`
            # is a bare basename; `./` makes it a path again.
            path = asset.file.short_path
            return ["absolute", path if "/" in path else "./" + path]
        if target_os == "ios":
            fw = native_asset_framework_name(asset.bundle_filename)
            return ["absolute", "%s.framework/%s" % (fw, fw)]
        return ["absolute", asset.bundle_filename]
    if asset.link_mode == "dynamic_loading_system":
        return ["system", asset.system_uri]
    if asset.link_mode == "dynamic_loading_executable":
        return ["executable"]
    if asset.link_mode == "dynamic_loading_process":
        return ["process"]
    fail("flutter_native_assets_manifest: unsupported link_mode %r" % asset.link_mode)

def native_assets_target_string(target_os, target_arch):
    """Return the Dart Target string for a (target_os, arch) pair, or "".

    Used by `flutter_application` to label the per-target manifest
    section. Returns "" when the pair isn't supported, in which case
    the caller emits an empty `native-assets` dict (which is still
    valid for the engine).
    """
    if not target_os or not target_arch:
        return ""
    return _OS_ARCH_TO_TARGET.get((target_os, target_arch), "")

def write_native_assets_manifest(
        ctx,
        output_file,
        native_assets,
        target_os,
        target_arch,
        layout = "bundle"):
    """Write the canonical `--native-assets` JSON manifest.

    Groups `native_assets` (a list of `FlutterNativeAssetInfo`) under the
    Dart Target string for the platform being built and serializes the
    result to `output_file`.

    Asset ids are unique within a manifest: an id claimed by two
    *differing* declarations fails the build rather than letting one
    shadow the other. Byte-identical declarations never reach here —
    they collapse earlier, in the `FlutterInfo.native_assets` depset —
    so a repeated asset reached through a diamond is not an error.

    When the input list is empty, the manifest is still written but with
    an empty `native-assets` map — keeping the frontend_server
    invocation uniform.

    Args:
      ctx: Rule context. Used only for `ctx.actions.write`.
      output_file: The File to write the manifest into.
      native_assets: Iterable of `FlutterNativeAssetInfo` providers.
      target_os: Target OS string (`macos`, `ios`, `linux`, `windows`,
        `android`). Empty string means "no platform context" — emits
        an empty manifest.
      target_arch: Target architecture string (`arm64`, `x64`, etc.).
        Empty defers to the host arch implicitly via an empty
        manifest map.
      layout: Where the bundled libraries will be at run time. `"bundle"`
        (the default) writes paths relative to the platform application's
        bundle slot; `"runfiles"` writes each library's runfiles-relative
        path, for a `flutter_test`, which has no bundle; `"library_path"`
        names each by its bundle filename, for a `flutter_tester_binary`, whose
        runner puts the directory they are staged in on the loader's path.
    """
    target_string = native_assets_target_string(target_os, target_arch)

    section = {}
    for asset in native_assets:
        if asset.asset_id in section:
            fail(
                "flutter_native_assets_manifest: duplicate native asset id %r. " % asset.asset_id +
                "Two `flutter_native_asset` targets in this application's " +
                "dependency graph claim the same id, so both the manifest " +
                "entry and the bundled library would be whichever one the " +
                "aggregator happened to visit last. Declare the per-platform " +
                "variants under a `select()` on " +
                "`flutter_plugin(native_assets = ...)` so exactly one of them " +
                "reaches the application in any given configuration.",
            )
        section[asset.asset_id] = _path_list_for(asset, target_os, layout)

    # Assets in the graph with no resolvable `<os>_<arch>` key means the
    # manifest would silently omit them and every `@Native` binding
    # would fail at runtime, far from the cause. Break loudly instead.
    if section and not target_string:
        fail(
            "flutter_native_assets_manifest: %d native asset(s) reached this " % len(section) +
            "application on %r but the target architecture could not be " % target_os +
            "determined (got %r). " % target_arch +
            "The --native-assets manifest would silently omit them and " +
            "@Native bindings would fail at runtime. This is a rules_flutter " +
            "bug in host_target_arch's cpu detection — please report the " +
            "bazel-out cpu segment of this build.",
        )

    manifest = {
        "format-version": [1, 0, 0],
        "native-assets": (
            {target_string: section} if (target_string and section) else {}
        ),
    }

    ctx.actions.write(output_file, json.encode_indent(manifest, indent = "  "))

def collect_bundled_code_asset_files(native_assets):
    """Return a single depset of files that should be embedded in the bundle.

    Keeps the `link_mode = dynamic_loading_bundle` assets; the remaining
    link modes contribute manifest entries only — no files to bundle.

    Args:
      native_assets: Iterable of `FlutterNativeAssetInfo` providers.

    Returns:
      A `depset[File]` carrying every shared library that needs to be
      placed into the platform application's bundle slot.
    """
    return depset(direct = [
        asset.file
        for asset in native_assets
        if asset.link_mode == "dynamic_loading_bundle" and asset.file != None
    ])

def resolve_native_assets(ctx, declared, deps, code_assets):
    """The one asset per id a program loads, with each library staged once.

    Assets arrive three ways, and on a shared id the more deliberate one wins:

      * named in the consuming target's own `code_assets` — a choice made for
        this program, so it replaces whatever arrives under its id below.
        rules_dart's `dart_binary` and `dart_test` give their `code_assets` the
        same meaning;
      * declared with `flutter_native_asset` and propagated on `FlutterInfo`;
      * owned by a Dart package and lifted off the package graph.

    Two packages claiming one id with different libraries fail, as in
    rules_dart, unless the target names the one to use: the Dart VM resolves
    an id to exactly one library, and keeping either would pick a native
    library by graph-traversal order.

    Several ids may name one library, as when one shared library serves
    several packages. They share one staged file, so every bundle carries the
    library once and every manifest entry names that one file, and the OS
    loader returns one image — one copy of the library's static state — for
    all of them. Two files would load two copies.

    A library is staged under a directory named after the consuming target,
    because the bare basename in its package is a path someone else may
    already own: the library's own rule, when it sits in the same package (a
    `cc_shared_library` named `sub` writes `libsub.dylib` there), or a second
    application in the package whose action differs. It also takes the
    library out of `_solib_<arch>/`, which trips rules_apple's
    `bundle_paths.owner_relative_path`. Every bundler places the library by its
    basename, which this keeps.

    Args:
      ctx: The consuming rule's context.
      declared: `FlutterNativeAssetInfo` from `flutter_native_asset`
        declarations reaching the target.
      deps: Targets whose Dart packages may carry code assets.
      code_assets: `DartCodeAssetInfo` the target names itself.

    Returns:
      A struct with `assets`, every `FlutterNativeAssetInfo` the program loads,
      one per id; `lifted`, the subset that came from `DartCodeAssetInfo`
      (lifted or named) rather than from `flutter_native_asset`; and
      `libraries`, each lifted id's library as built, before staging (None for
      an asset with no library).
    """
    named = {asset.asset_id: True for asset in code_assets}
    declared = [asset for asset in declared if asset.asset_id not in named]
    declared_ids = {asset.asset_id: True for asset in declared}
    transitive = collect_transitive_code_assets([dep for dep in deps if DartInfo in dep])
    resolved = resolve_code_assets(
        ctx.label,
        [asset for asset in transitive if asset.asset_id not in declared_ids],
        code_assets,
    )
    lifted = _stage_code_assets(ctx, resolved)
    return struct(
        assets = declared + lifted,
        lifted = lifted,
        libraries = {asset.asset_id: asset.dynamic_library for asset in resolved},
    )

def _stage_code_assets(ctx, assets):
    """`FlutterNativeAssetInfo` for `assets`, each distinct library linked once."""
    links = {}
    by_basename = {}
    staged = []
    for asset in assets:
        library = asset.dynamic_library
        link = None
        if library != None:
            link = links.get(library)
            if link == None:
                other = by_basename.get(library.basename)
                if other == None:
                    link = ctx.actions.declare_file(
                        "%s_code_assets/%s" % (ctx.label.name, library.basename),
                    )
                    ctx.actions.symlink(output = link, target_file = library)
                    by_basename[library.basename] = struct(library = library, link = link)
                elif other.library.owner == library.owner:
                    fail((
                        "%s: %s reaches this target in two configurations " +
                        "(%s and %s), so two builds of it would both be " +
                        "bundled as `%s`. Name the one to ship in this " +
                        "target's `code_assets`, or reset the setting that " +
                        "changes on the way to the other."
                    ) % (ctx.label, library.owner, other.library.path, library.path, library.basename))
                else:
                    fail((
                        "%s: two code-asset libraries would both be bundled as " +
                        "`%s`: %s and %s. A bundle places each library by its " +
                        "file name, so only one of them can ship. Rename one, " +
                        "or serve both ids from one library by naming it in " +
                        "this target's `code_assets`."
                    ) % (ctx.label, library.basename, other.library.owner, library.owner))
                links[library] = link
        staged.append(FlutterNativeAssetInfo(
            asset_id = asset.asset_id,
            link_mode = asset.link_mode,
            file = link,
            bundle_filename = library.basename if library != None else "",
            system_uri = asset.system_uri,
        ))
    return staged

# -- Tier 2 standalone rule ----------------------------------------------------

def _flutter_native_assets_manifest_impl(ctx):
    if FlutterApplicationInfo not in ctx.attr.application:
        fail("flutter_native_assets_manifest: `application` must provide FlutterApplicationInfo.")
    app_info = ctx.attr.application[FlutterApplicationInfo]
    if app_info.native_assets_manifest == None:
        fail(
            "flutter_native_assets_manifest: the application target's " +
            "FlutterApplicationInfo carries no native_assets_manifest. " +
            "This should never happen — flutter_application always emits one.",
        )
    return [DefaultInfo(files = depset([app_info.native_assets_manifest]))]

flutter_native_assets_manifest = rule(
    implementation = _flutter_native_assets_manifest_impl,
    attrs = {
        "application": attr.label(
            doc = "A `flutter_application` target. The manifest produced by " +
                  "the application is re-exposed via this rule's DefaultInfo " +
                  "for callers that want a standalone manifest target.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
    },
    doc = "Re-exposes a flutter_application's `--native-assets` manifest as a standalone target.",
)
