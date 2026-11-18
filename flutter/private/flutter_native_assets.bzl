"""Code assets: what a program loads, and its native-assets manifests.

An app ships `flutter_assets/NativeAssetsManifest.json`, which the engine
reads at startup, as `flutter build` ships it. It maps each code asset that
ships to how the engine loads it (`["absolute", <path>]` for a bundled
library, `["system", <uri>]`, `["executable"]`, `["process"]`), per Dart
target:

    {
      "format-version": [1, 0, 0],
      "native-assets": {
        "macos_arm64": {
          "package:objective_c/objective_c.dylib": ["absolute", "objective_c.dylib"],
          "package:libsqlite3/libsqlite3.so": ["system", "libsqlite3.so.0"]
        }
      }
    }

A release build's link hooks choose which code assets ship, so the app's
manifest is written by an action (`code_assets.dart manifest`), and each
platform's bundler places the libraries from the same reading of the program's
assets. A bundled library is named by its path in the platform's code-asset
directory:

  * macOS:   `<App>.app/Contents/Frameworks/<basename>`
  * iOS:     `<App>.app/Frameworks/<name>.framework/<name>`: iOS forbids loose
             embedded dylibs, so each library is wrapped in a framework of its
             own (flutter_tools' `frameworkUri`), which the manifest names by
             its install name, `@rpath/<name>.framework/<name>`
  * Linux:   `<bundle>/lib/<basename>`
  * Windows: next to the runner exe
  * Android: `lib/<abi>/<basename>` inside the APK

Several asset ids may name one library. It is bundled once, one file or one
framework on iOS, and every id's entry names it, so the loader opens one image
for all of them.

A `flutter_test` keeps upstream's `flutter test` route: its manifest, written
here (`write_native_assets_manifest`), is the `NativeAssetsManifest.json` of the
test's assets directory, which flutter_tester reads.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING", "dart_program_assets_actions", "program_kernel_code_assets")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "portable_tools")

visibility("//flutter/...")

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
packages in `deps` supply under that id, as
`code_assets` does on rules_dart's `dart_binary` and `dart_test`. Ids no entry
names keep the asset `deps` supply.

Several entries may name one library, to serve several packages' ids from one
shared library. It is bundled once (one file; one framework on iOS) and every
id's manifest entry names it, so the process loads one image of it: one copy of
its static state, whichever id a call goes through.

```starlark
dart_code_asset(name = "a_combined", asset_id = "package:a/a", file = ":combined")
dart_code_asset(name = "b_combined", asset_id = "package:b/b", file = ":combined")

flutter_application(
    name = "app",
    deps = ["//a", "//b"],
    code_assets = [":a_combined", ":b_combined"],
)
```
"""

_FRAMEWORK_NAME_CHARACTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"

def native_asset_framework_name(filename):
    """Derive the framework name for a bundled native-asset dylib on Apple.

    Mirrors flutter_tools' `frameworkUri` (native_assets_host.dart): strip a
    trailing `.dylib` and then a leading `lib`, and keep only
    `[A-Za-z0-9._-]`, the characters a bundle identifier may hold. A file that
    is not a `.dylib` keeps its `lib`: `libfoo.so` is `libfoo.so`.
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
    return "".join([c for c in name.elems() if c in _FRAMEWORK_NAME_CHARACTERS])

# The file the iOS app's framework rule writes `ios_framework_names` to, which
# `flutter_native_hot_patch_aspect` hands the dev tool.
IOS_FRAMEWORK_NAMES_FILE = "rules_flutter_ios_frameworks.json"

IosFrameworkNamesInfo = provider(
    doc = "The framework each bundled library of an iOS app ships in.",
    fields = {"file": "File: `IOS_FRAMEWORK_NAMES_FILE`, a JSON object from library file name to framework name."},
)

def ios_framework_names(libraries):
    """The framework each of an iOS app's bundled libraries ships in, by file name.

    flutter_tools' `frameworkUri` (native_assets_host.dart) over the libraries
    in the order of their file names: each is named by
    `native_asset_framework_name`, and a name an earlier one took gains `1`,
    `2`, ... up to 999, as `foo.dylib` and `libfoo.dylib` ship as `foo` and
    `foo1`. flutter_tools names them in the order its build hooks reported
    them; file-name order is the one every rule that names a framework can
    reproduce from the same libraries, so the bundle, the manifest, the list
    of frameworks to drop and the dev tool agree.

    Args:
      libraries: Files: every library the app bundles, its `native_deps` and
        every code-asset candidate, repeats allowed.

    Returns:
      A dict from file name to framework name.
    """
    taken = {}
    names = {}
    for file_name in sorted({library.basename: None for library in libraries}.keys()):
        base = native_asset_framework_name(file_name)
        name = base
        if name in taken:
            for i in range(1, 1000):
                name = "%s%d" % (base, i)
                if name not in taken:
                    break
            if name in taken:
                fail("Failed to rename %s in native assets packaging." % base)
        taken[name] = True
        names[file_name] = name
    return names

def app_ios_framework_names(native_libs, program_assets):
    """`ios_framework_names` of an app: its `native_deps` libraries and every code-asset candidate.

    Args:
      native_libs: The app's `native_deps` libraries (`FlutterApplicationInfo.native_libs`).
      program_assets: The app's `DartProgramAssetsInfo`.

    Returns:
      A dict from file name to framework name.
    """
    return ios_framework_names(list(native_libs) + candidate_code_asset_libraries(program_assets))

def add_ios_framework_args(args, names):
    """Adds `--framework <file name> <name>` to `args` for each of `names`, as `code_assets.dart` reads them."""
    for file_name, name in sorted(names.items()):
        args.add_all("--framework", [file_name, name])

def _path_list_for(asset, layout):
    """Return the manifest path-list shape for `asset`.

    For `dynamic_loading_bundle` the engine's `KernelAssetAbsolutePath` is the
    path it `dlopen`s. An app's manifest names it in its bundle
    (`code_assets.dart`, which ships it in `flutter_assets`); this one is a
    test's, in the test's assets directory.

    Under `layout = "runfiles"` there is no bundle — a `flutter_test` runs out
    of Bazel's runfiles tree — so the entry is the library's runfiles-relative
    path. A path with a separator in it is resolved by the loader against the
    process's working directory, and Bazel runs a test with that set to the
    runfiles root, so the same string works for every asset without the runner
    having to rewrite the manifest (it is baked into the kernel at build time
    and cannot be rewritten later).

    Windows has no such tree by default: without `--enable_runfiles` Bazel
    there writes a runfiles *manifest* only, so no such relative path exists on
    disk to resolve against. A Windows `flutter_test` uses `library_path`
    instead, as a `flutter_tester_binary` does on every host.
    """
    if asset.link_mode == "dynamic_loading_bundle":
        if layout == "library_path":
            # Found by name on the loader's search path, which the runner sets
            # to the one directory the libraries are staged in (PATH on
            # Windows), so the program may run from any working directory.
            return ["system", asset.bundle_filename]
        if layout == "runfiles":
            # `dlopen` searches its loader paths for a name with no separator
            # in it, rather than opening it as a file. A consumer in the
            # workspace root package declares the symlink there, so `short_path`
            # is a bare basename; `./` makes it a path again.
            path = asset.file.short_path
            return ["absolute", path if "/" in path else "./" + path]
        fail("flutter_native_assets_manifest: unknown layout %r" % layout)
    if asset.link_mode == "dynamic_loading_system":
        return ["system", asset.uri]
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
        layout):
    """Write a test's `--native-assets` JSON manifest.

    Groups `native_assets` (from `resolve_native_assets`, one per asset id)
    under the Dart Target string for the platform being built and serializes
    the result to `output_file`.

    When the input list is empty, the manifest is still written but with
    an empty `native-assets` map — keeping the frontend_server
    invocation uniform.

    Args:
      ctx: Rule context. Used only for `ctx.actions.write`.
      output_file: The File to write the manifest into.
      native_assets: The assets `resolve_native_assets` returns.
      target_os: Target OS string (`macos`, `ios`, `linux`, `windows`,
        `android`). Empty string means "no platform context" — emits
        an empty manifest.
      target_arch: Target architecture string (`arm64`, `x64`, etc.).
        Empty defers to the host arch implicitly via an empty
        manifest map.
      layout: Where the test's libraries are at run time: `"runfiles"`
        writes each library's runfiles-relative path, for a `flutter_test`;
        `"library_path"` names each by its file name, for a
        `flutter_tester_binary` and for a `flutter_test` on Windows, whose
        runner puts the directory they are staged in on the loader's path.
    """
    target_string = native_assets_target_string(target_os, target_arch)

    section = {}
    for asset in native_assets:
        section[asset.asset_id] = _path_list_for(asset, layout)

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
      native_assets: The assets `resolve_native_assets` returns.

    Returns:
      A `depset[File]` carrying every shared library that needs to be
      placed into the platform application's bundle slot.
    """
    return depset(direct = [
        asset.file
        for asset in native_assets
        if asset.link_mode == "dynamic_loading_bundle" and asset.file != None
    ])

def code_asset_candidates(program_assets):
    """Every code asset a program could ship: those that always do, and every one a link hook chooses among.

    Which of them ships is known only to an action reading the program's
    assets file (`program_assets_action_args`), so analysis uses these for
    what must hold of every candidate: an action's declared inputs, and the
    checks that no two could land on one path.

    Args:
      program_assets: The program's `DartProgramAssetsInfo`.

    Returns:
      A list of `DartCodeAssetInfo`, one per id.
    """
    return program_kernel_code_assets(program_assets)

def candidate_code_asset_libraries(program_assets):
    """The library of every bundled code-asset candidate (`code_asset_candidates`), each once.

    Args:
      program_assets: The program's `DartProgramAssetsInfo`.

    Returns:
      A list of Files.
    """
    return list({
        asset.file: None
        for asset in code_asset_candidates(program_assets)
        if asset.link_mode == "dynamic_loading_bundle" and asset.file != None
    }.keys())

def check_bundled_library_names(label, libraries):
    """Fails when two of an app's bundled libraries have one file name.

    Two different libraries under one file name cannot both ship, as
    flutter_tools' application check fails on two code assets of one file
    name. (On iOS two file names may lead to one framework name; the second
    is renamed, `ios_framework_names`.) Checked over every candidate, kept or
    not, because which a link hook keeps is known only when the bundle is
    built: the check holds whatever it keeps.

    Args:
      label: The application's label, for the message.
      libraries: Files: the code-asset candidates' libraries and the
        `native_deps` libraries, in any order, repeats allowed.
    """
    by_name = {}
    for library in libraries:
        name = library.basename
        what = "`%s`" % name
        other = by_name.get(name)
        if other == None:
            by_name[name] = library
            continue
        if other == library:
            continue
        if other.owner == library.owner:
            fail((
                "%s: %s reaches this target in two configurations " +
                "(%s and %s), so two builds of it would both be " +
                "bundled as %s. Name the one to ship in this " +
                "target's `code_assets`, or reset the setting that " +
                "changes on the way to the other."
            ) % (label, library.owner, other.path, library.path, what))
        fail((
            "%s: two native libraries would both be bundled as %s: " +
            "%s and %s. A bundle places each library by its file name, " +
            "so only one of them can ship. Rename one, or serve both ids " +
            "from one library by naming it in this target's `code_assets`."
        ) % (label, what, other.owner, library.owner))

def resolve_native_assets(ctx, package, deps, code_assets):
    """The one asset per id a program loads, with each library staged once.

    Assets arrive two ways, and on a shared id the more deliberate one wins:

      * named in the consuming target's own `code_assets` — a choice made for
        this program, so it replaces whatever arrives under its id below.
        rules_dart's `dart_binary` and `dart_test` give their `code_assets` the
        same meaning;
      * owned by a Dart package (its `dart_package_metadata`'s `code_assets`)
        and lifted off the package graph, the program's own package among
        them.

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

    The assets are every one the program's unlinked assets operation
    (`dart_program_assets_actions`) can load, known at analysis time as the
    kernel compile's `--native-assets` needs them. A package's
    `linked_code_assets` are linked for this program there.

    Args:
      ctx: The consuming rule's context, carrying `program_assets_attrs()`,
        `PROGRAM_ASSETS_TOOLCHAINS`, `PORTABLE_EXEC_GROUPS` and the `cpp`
        fragment.
      package: The program's own `DartPackageInfo` (`program_package`), or
        None for a program in no package. Its `code_assets` count as any
        package's, whether or not a library in `deps` names the same
        declaration.
      deps: Targets whose Dart packages may carry code assets.
      code_assets: `DartCodeAssetInfo` the target names itself.

    Returns:
      A struct with `assets`, every asset the program loads, one per id, each
      a struct of `asset_id`, `link_mode`, `file` (the staged library, or
      None), `bundle_filename` (its basename, or empty) and `uri`; and
      `libraries`, each id's library as built, before staging (None for an
      asset with no library).
    """
    return stage_native_assets(ctx, program_kernel_code_assets(dart_program_assets_actions(
        ctx,
        package,
        [dep for dep in deps if DartInfo in dep],
        ctx.label.name + "_program_assets",
        code_assets = code_assets,
    ).info))

def stage_native_assets(ctx, resolved):
    """The code assets a program loads, as `resolve_native_assets` returns them.

    Args:
      ctx: The consuming rule's context.
      resolved: The `DartCodeAssetInfo` its program assets operation ships.

    Returns:
      What `resolve_native_assets` returns.
    """
    return struct(
        assets = _stage_code_assets(ctx, resolved),
        libraries = {asset.asset_id: asset.file for asset in resolved},
    )

def _stage_code_assets(ctx, assets):
    """The assets as `resolve_native_assets` returns them, each distinct library linked once."""
    links = {}
    by_basename = {}
    staged = []
    for asset in assets:
        library = asset.file
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
        staged.append(struct(
            asset_id = asset.asset_id,
            link_mode = asset.link_mode,
            file = link,
            bundle_filename = library.basename if library != None else "",
            uri = asset.uri,
        ))
    return staged

# What a rule running `run_code_assets_tool` declares.
CODE_ASSETS_TOOL_ATTRS = {
    "_code_assets_tool": attr.label(
        default = "//flutter/private/tools:code_assets.dart",
        allow_single_file = True,
    ),
    "_code_assets_tool_imports": attr.label(
        default = "//flutter/private/tools:code_assets_imports",
    ),
}

def run_code_assets_tool(ctx, command, arguments, inputs, outputs, mnemonic, progress_message):
    """Runs `code_assets.dart <command>` in the `PORTABLE` exec group.

    Args:
      ctx: Rule context with `CODE_ASSETS_TOOL_ATTRS` and `PORTABLE_EXEC_GROUPS`.
      command: The tool's command (`place`, `ios-post-processor`, `xcframeworks`).
      arguments: Its `Args`, in order: the program-assets file's among them.
      inputs: A depset of the Files they name.
      outputs: The declared outputs.
      mnemonic: The action's mnemonic.
      progress_message: The action's progress message.
    """
    tools = portable_tools(ctx)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [ctx.actions.args().add(ctx.file._code_assets_tool).add(command)] + arguments,
        inputs = depset(
            [ctx.file._code_assets_tool] + ctx.files._code_assets_tool_imports,
            transitive = [inputs, tools.sdk_files.run],
        ),
        outputs = outputs,
        mnemonic = mnemonic,
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = progress_message,
    )

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
    doc = "Re-exposes the native-assets manifest a flutter_application ships (`flutter_assets/NativeAssetsManifest.json`) as a standalone target.",
)
