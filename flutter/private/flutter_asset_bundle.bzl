"""Flutter asset bundle generation.

Produces a `flutter_assets/` tree artifact containing:
- AssetManifest.bin  (StandardMessageCodec binary manifest)
- FontManifest.json  (font family declarations)
- NOTICES.Z          (gzip-compressed license text; `NOTICES` for the web)
- Copied asset files (images, etc.)
"""

load("@rules_dart//dart:utils.bzl", "PATH_MAPPING", "program_assets_action_args")
load("//flutter/private:asset_variants.bzl", "variant_scale")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_info_forwarding.bzl", "flutter_info_forwarding_aspect")
load("//flutter/private:flutter_library.bzl", "aggregate_pub_contributions", "package_root_of", "path_in_package")
load("//flutter/private:notices.bzl", "NOTICES_ATTRS", "additional_licenses_of", "flutter_notices_action", "notices_asset_key", "package_licenses_of")
load("//flutter/private:path_mapping.bzl", "file_ref", "json_config_args")

visibility("//flutter/...")

_TOOL = Label("//flutter/private/tools:generate_asset_manifest.dart")

def detect_dpr(path):
    """Detect the device pixel ratio from the directory a file is in.

    A file is a resolution variant of the file of the same name one directory
    up when its immediate parent directory is named for a scale (`2x`, `1.5x`,
    `0.75x`; see `variant_scale`). A directory further up, or below, makes no
    variant of it.

    Args:
        path: Asset path string (e.g. "assets/2.0x/icon.png").

    Returns:
        (base_path, dpr) tuple.  base_path has the DPR dir removed (e.g.
        "assets/icon.png").  dpr is a float or None if not a variant.
    """
    parts = path.split("/")
    if len(parts) >= 2:
        dpr = variant_scale(parts[-2])
        if dpr != None:
            return "/".join(parts[:-2] + parts[-1:]), dpr
    return path, None

def build_asset_manifest(assets):
    """Build the asset manifest structure from a list of asset paths.

    Args:
        assets: list of asset path strings relative to package root.

    Returns:
        dict mapping logical key → list of variant dicts.
    """
    manifest = {}

    # Group by base path.
    for path in sorted(assets):
        base, dpr = detect_dpr(path)
        if base not in manifest:
            manifest[base] = []
        entry = {"asset": path}
        if dpr != None:
            entry["dpr"] = dpr
        manifest[base].append(entry)

    # Ensure the main (1x) variant is first in each list.
    for base in manifest:
        variants = manifest[base]
        main_idx = None
        for i, v in enumerate(variants):
            if v["asset"] == base:
                main_idx = i
                break
        if main_idx != None and main_idx != 0:
            main = variants.pop(main_idx)
            variants.insert(0, main)

    return manifest

def flutter_asset_bundle_action(
        ctx,
        dart,
        dart_files,
        assets = [],
        fonts = [],
        output_dir = None,
        font_subset = None,
        recorded_uses = [],
        optional_code_points = [],
        extra_asset_copies = [],
        unlisted_asset_copies = [],
        owner = None,
        program_assets = None):
    """Create an action that generates the flutter_assets/ tree artifact.

    Args:
        ctx: Rule context.
        dart: The `dart` executable File from the Flutter SDK.
        dart_files: The files `dart` needs to run `generate_asset_manifest.dart`
            from source: the `run` set of the SDK (`DartSdkFilesInfo.run`).
        assets: list of File objects of the target's package to include in the
            bundle, each under its path from that package's root
            (`assets/a.png`).
        fonts: list of font declaration dicts (FontManifest.json schema).
        output_dir: The already-declared directory (tree artifact) File to
            write the bundle into. Declared by the caller rather than here
            because an application has to know where its assets will land
            *before* this action runs — the path is baked into the app as
            `rules_flutter.build_info.assetsDir`, which the dev tool matches
            against the tree it watches and rebuilds. Declaring an output and
            registering the action that fills it are separate steps in
            Starlark, so hoisting the declaration introduces no cycle even
            though icon tree shaking makes this action depend on the compile.
        font_subset: File for font-subset binary (enables icon tree shaking).
        recorded_uses: The recorded-uses JSON Files of the program's
            compiles, whose `IconData` instances are the icons it uses
            (enables icon tree shaking).
        optional_code_points: Code points every subset icon font keeps if the
            font has a glyph for them, used or not (`optional:<n>` to
            font-subset).
        extra_asset_copies: list of (key, File) for assets that need a specific
            key (e.g. "fonts/MaterialIcons-Regular.otf"). They are listed in the
            asset manifest.
        unlisted_asset_copies: the same, for files that are bundled without
            being an entry of the asset manifest.
        owner: What has the package `assets` are keyed in: anything with a
            `label`, `ctx` when None. A program rebuilt under another target
            (`flutter_application_variant`) keeps its own package's keys.
        program_assets: Optional `DartProgramAssetsInfo`. The tool places each
            data asset the program ships at `packages/<package>/<name>`,
            the key flutter_tools gives a hook's data asset and the one
            `rootBundle` loads it by, and lists it in the asset manifest.

    Returns:
        The `output_dir` it was given, so callers can chain.
    """
    if output_dir == None:
        fail("flutter_asset_bundle_action: `output_dir` is required — declare it with ctx.actions.declare_directory().")
    tool = ctx.file._asset_bundle_tool

    # Every path in the config is a `file_ref`, which Bazel fills in when it
    # writes the config, path-mapped where the action is.
    refs = []

    # Every file is claimed under its key. A key stands for one file: a second,
    # different file claiming it would have the bundle hold one and the
    # manifest name the other, so it fails here, naming both. The same file
    # reached twice (a package behind two dependencies) is one claim.
    claims = {}
    listed = {}
    owner = owner or ctx
    owner_root = package_root_of(owner)
    claimed = [(path_in_package(owner.label, owner_root, f), f, True) for f in assets]
    claimed += [(key, f, True) for key, f in extra_asset_copies]
    claimed += [(key, f, False) for key, f in unlisted_asset_copies]
    for key, f, in_manifest in claimed:
        seen = claims.get(key)
        if seen != None and seen != f:
            fail("%s: two files claim the asset key %s: %s and %s. A bundle can hold one of them." % (ctx.label, key, seen.short_path, f.short_path))
        claims[key] = f
        if in_manifest:
            listed[key] = True

    # Build asset paths and copy map relative to the output directory.
    asset_paths = list(listed.keys())
    copies = {key: file_ref(refs, f) for key, f in claims.items()}

    # Build manifest structure.
    manifest = build_asset_manifest(asset_paths)

    # Write the config JSON.
    config = {
        "assets": manifest,
        "fonts": fonts,
        "copies": copies,
    }

    # Icon tree shaking config.
    extra_inputs = []
    if font_subset and recorded_uses:
        config["icon_tree_shaking"] = {
            "font_subset": file_ref(refs, font_subset),
            "recorded_uses": [file_ref(refs, f) for f in recorded_uses],
            "optional_code_points": optional_code_points,
        }
        extra_inputs.extend([font_subset] + recorded_uses)

    args = ctx.actions.args()
    args.add(tool)
    args.add_all("--output-dir", [output_dir], expand_directories = False)
    args.add("--config")
    arguments = [args, json_config_args(ctx, config, refs)]
    program_inputs = []
    if program_assets != None:
        # The bundle holds data assets only: no native library is an input.
        program = program_assets_action_args(ctx.actions, program_assets, code = None)
        arguments.append(program.args)
        program_inputs = [program.inputs]

    ctx.actions.run(
        executable = dart,
        arguments = arguments,
        inputs = depset(
            direct = [tool] + claims.values() + extra_inputs,
            transitive = [dart_files] + program_inputs,
        ),
        outputs = [output_dir],
        mnemonic = "FlutterAssetBundle",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Bundling Flutter assets %s" % ctx.label,
    )

    return output_dir

def _flutter_asset_bundle_impl(ctx):
    tools = portable_tools(ctx)

    # Walk pub-package font/asset contributions from FlutterInfo. To get
    # MaterialIcons in the bundle, list `@rules_flutter//flutter:material_icons`
    # in deps — the same channel cupertino_icons et al. arrive through.
    fonts, extra_asset_copies, unlisted_asset_copies = aggregate_pub_contributions(ctx.attr.deps, flavor = ctx.attr.flavor, program_root = package_root_of(ctx))

    notices = flutter_notices_action(
        ctx = ctx,
        tools = tools,
        packages = package_licenses_of(ctx.attr.deps),
        additional = additional_licenses_of(ctx.attr.deps),
        engine_license = ctx.file._engine_license,
        web = False,
    )

    output_dir = flutter_asset_bundle_action(
        ctx = ctx,
        dart = tools.dart,
        dart_files = tools.sdk_files.run,
        assets = ctx.files.assets,
        fonts = fonts,
        output_dir = ctx.actions.declare_directory(ctx.label.name),
        extra_asset_copies = extra_asset_copies,
        unlisted_asset_copies = unlisted_asset_copies + [(notices_asset_key(False), notices)],
    )

    return [DefaultInfo(files = depset([output_dir]))]

flutter_asset_bundle = rule(
    implementation = _flutter_asset_bundle_impl,
    attrs = {
        "assets": attr.label_list(
            doc = "Asset files to include in the bundle.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = "Flutter library dependencies whose assets to include.",
            aspects = [flutter_info_forwarding_aspect],
        ),
        "flavor": attr.string(
            doc = "The flavor the bundle is for: a pub package's `flavors:` entries naming it are bundled, other `flavors:` entries are not. Empty is no flavor.",
        ),
        "_asset_bundle_tool": attr.label(
            default = _TOOL,
            allow_single_file = True,
        ),
    } | NOTICES_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Generates a flutter_assets/ tree artifact with manifests and asset files. It is for no platform in particular, so it holds the assets of `deps` that a package restricts to some platforms (`platforms:`) too, and only those it restricts to flavors (`flavors:`) that name `flavor`.",
)
