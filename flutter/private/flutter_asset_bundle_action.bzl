"""Shared `flutter_assets/` tree build action.

Leaf module for the action both `flutter_asset_bundle` and the shared asset
bundling step in `//flutter/private:common.bzl` register. Kept apart from the
rule so the rule can load the shader helpers from `common.bzl` without a
load cycle.
"""

# Regex-like DPR directory patterns we detect in Starlark.
# A directory named like "2x", "1.5x", "3.0x" indicates a resolution variant.
_DPR_SUFFIXES = {
    "1.5x": 1.5,
    "2x": 2.0,
    "2.0x": 2.0,
    "3x": 3.0,
    "3.0x": 3.0,
    "4x": 4.0,
    "4.0x": 4.0,
}

def detect_dpr(path):
    """Detect device-pixel-ratio from a resolution variant directory name.

    Args:
        path: Asset path string (e.g. "assets/2.0x/icon.png").

    Returns:
        (base_path, dpr) tuple.  base_path has the DPR dir removed (e.g.
        "assets/icon.png").  dpr is a float or None if not a variant.
    """
    parts = path.split("/")
    for i, part in enumerate(parts):
        if part in _DPR_SUFFIXES:
            base = "/".join(parts[:i] + parts[i + 1:])
            return base, _DPR_SUFFIXES[part]
    return path, None

def build_asset_manifest(assets):
    """Build the asset manifest structure from a list of asset paths.

    Args:
        assets: list of asset path strings relative to package root.

    Returns:
        dict mapping logical key -> list of variant dicts.
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
        dart = None,
        flutter_sdk_files = None,
        assets = [],
        fonts = [],
        notices = "",
        license_files = [],
        output_dir = None,
        const_finder = None,
        font_subset = None,
        kernel_dill = None,
        kernel_dills = [],
        tree_shake_key = "",
        extra_asset_copies = {}):
    """Create an action that generates the flutter_assets/ tree artifact.

    Args:
        ctx: Rule context.
        dart: The `dart` executable File from the Flutter SDK (only required when icon tree shaking is enabled).
        flutter_sdk_files: SDK files needed to run dart (for action inputs when icon tree shaking is enabled).
        assets: list of asset entry structs (`struct(key, file, label)`) to
            include in the bundle, each keyed once by the target that listed
            it — relative to its Bazel package, or `packages/<name>/...` for
            a library. The bundle keys every file by its carried `key`.
        fonts: list of font declaration dicts (FontManifest.json schema).
        notices: License text string to compress into NOTICES.Z.
        license_files: list of File objects containing license text to include in NOTICES.Z.
        output_dir: The already-declared directory (tree artifact) File to
            write the bundle into. Declared by the caller rather than here
            because an application has to know where its assets will land
            *before* this action runs — the path is baked into the app as
            `rules_flutter.build_info.assetsDir`, which the dev tool matches
            against the tree it watches and rebuilds. Declaring an output and
            registering the action that fills it are separate steps in
            Starlark, so hoisting the declaration introduces no cycle even
            though icon tree shaking makes this action depend on the kernel.
        const_finder: File for const_finder.dart.snapshot (enables icon tree shaking).
        font_subset: File for font-subset binary (enables icon tree shaking).
        kernel_dill: File for the compiled kernel .dill (needed for icon tree shaking).
        kernel_dills: Optional list of compiled kernel .dill Files when icon tree
            shaking unions code points across multiple shipped builds.
        tree_shake_key: Optional configuration fingerprint for the shipped
            programs whose icons are tree-shaken.
        extra_asset_copies: dict mapping custom dest path → File for assets that
            need a specific destination path (e.g. "fonts/MaterialIcons-Regular.otf").

    Returns:
        The `output_dir` it was given, so callers can chain.
    """
    if output_dir == None:
        fail("flutter_asset_bundle_action: `output_dir` is required — declare it with ctx.actions.declare_directory().")
    tool = ctx.executable._asset_bundle_tool

    # Build asset paths and copy map relative to the output directory. The key
    # travels with the file — set once by the target that listed the asset —
    # so this action keys every file by its carried key and computes none.
    asset_paths = []
    copies = {}
    for entry in assets:
        asset_paths.append(entry.key)
        copies[entry.key] = entry.file.path

    # Add extra copies with custom destination paths.
    extra_files = []
    for dest_path, f in extra_asset_copies.items():
        asset_paths.append(dest_path)
        copies[dest_path] = f.path
        extra_files.append(f)

    # Build manifest structure.
    manifest = build_asset_manifest(asset_paths)

    # Write the config JSON.
    config = {
        "assets": manifest,
        "fonts": fonts,
        "copies": copies,
        "notices": notices,
        "license_files": [f.path for f in license_files],
    }

    # Icon tree shaking config.
    all_kernel_dills = list(kernel_dills) if kernel_dills else ([kernel_dill] if kernel_dill != None else [])
    extra_inputs = []
    transitive_inputs = []
    if const_finder and font_subset and all_kernel_dills:
        icon_cfg = {
            "dart": dart.path,
            "const_finder": const_finder.path,
            "font_subset": font_subset.path,
            "kernel_dill": all_kernel_dills[0].path,
            "kernel_dills": [d.path for d in all_kernel_dills],
        }
        if tree_shake_key:
            icon_cfg["key"] = "%x" % (hash(tree_shake_key) & 0xffffffff)
        config["icon_tree_shaking"] = icon_cfg
        extra_inputs.extend([dart, const_finder, font_subset] + all_kernel_dills)
        if flutter_sdk_files:
            transitive_inputs.append(flutter_sdk_files)

    config_content = json.encode(config)
    config_name = (
        "%s.%x.asset_bundle_config.json" % (ctx.label.name, hash(config_content) & 0xffffffff) if tree_shake_key else ctx.label.name + ".asset_bundle_config.json"
    )
    config_file = ctx.actions.declare_file(config_name)
    ctx.actions.write(config_file, config_content)

    ctx.actions.run(
        executable = tool,
        arguments = [
            "--config",
            config_file.path,
            "--output-dir",
            output_dir.path,
        ],
        inputs = depset(
            direct = [config_file] + [entry.file for entry in assets] + extra_files + license_files + extra_inputs,
            transitive = transitive_inputs,
        ),
        outputs = [output_dir],
        mnemonic = "FlutterAssetBundle",
        progress_message = "Bundling Flutter assets %s" % ctx.label,
    )

    return output_dir
