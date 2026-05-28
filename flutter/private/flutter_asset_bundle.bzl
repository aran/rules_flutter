"""Flutter asset bundle generation.

Produces a `flutter_assets/` tree artifact containing:
- AssetManifest.bin  (StandardMessageCodec binary manifest)
- FontManifest.json  (font family declarations)
- NOTICES.Z          (gzip-compressed license text)
- Copied asset files (images, etc.)
"""

load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_library.bzl", "aggregate_pub_contributions")

_TOOL = Label("//flutter/private/tools:generate_asset_manifest.dart")

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
        flutter_sdk_files,
        assets = [],
        fonts = [],
        notices = "",
        license_files = [],
        output_dir_name = "flutter_assets",
        const_finder = None,
        font_subset = None,
        kernel_dill = None,
        extra_asset_copies = {}):
    """Create an action that generates the flutter_assets/ tree artifact.

    Args:
        ctx: Rule context.
        dart: The `dart` executable File from the Flutter SDK.
        flutter_sdk_files: SDK files needed to run dart (for action inputs).
        assets: list of File objects to include in the bundle.
        fonts: list of font declaration dicts (FontManifest.json schema).
        notices: License text string to compress into NOTICES.Z.
        license_files: list of File objects containing license text to include in NOTICES.Z.
        output_dir_name: Name for the output tree artifact.
        const_finder: File for const_finder.dart.snapshot (enables icon tree shaking).
        font_subset: File for font-subset binary (enables icon tree shaking).
        kernel_dill: File for the compiled kernel .dill (needed for icon tree shaking).
        extra_asset_copies: dict mapping custom dest path → File for assets that
            need a specific destination path (e.g. "fonts/MaterialIcons-Regular.otf").

    Returns:
        The declared directory (tree artifact) File.
    """
    output_dir = ctx.actions.declare_directory(output_dir_name)
    tool = ctx.file._asset_bundle_tool

    # Build asset paths and copy map relative to the output directory.
    asset_paths = []
    copies = {}
    for f in assets:
        # Use short_path as the logical key inside flutter_assets/.
        asset_paths.append(f.short_path)
        copies[f.short_path] = f.path

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
    extra_inputs = []
    if const_finder and font_subset and kernel_dill:
        config["icon_tree_shaking"] = {
            "dart": dart.path,
            "const_finder": const_finder.path,
            "font_subset": font_subset.path,
            "kernel_dill": kernel_dill.path,
        }
        extra_inputs.extend([const_finder, font_subset, kernel_dill])

    config_content = json.encode(config)
    config_file = ctx.actions.declare_file(ctx.label.name + ".asset_bundle_config.json")
    ctx.actions.write(config_file, config_content)

    ctx.actions.run(
        executable = dart,
        arguments = [
            tool.path,
            "--config",
            config_file.path,
            "--output-dir",
            output_dir.path,
        ],
        inputs = depset(
            direct = [tool, config_file] + assets + extra_files + license_files + extra_inputs,
            transitive = [flutter_sdk_files],
        ),
        outputs = [output_dir],
        mnemonic = "FlutterAssetBundle",
        progress_message = "Bundling Flutter assets %s" % ctx.label,
    )

    return output_dir

def _flutter_asset_bundle_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    # Collect assets from direct attr + transitive FlutterInfo deps.
    all_assets = list(ctx.files.assets)
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_assets.extend(dep[FlutterInfo].asset_dirs.to_list())

    # Walk pub-package font/asset contributions from FlutterInfo. To get
    # MaterialIcons in the bundle, list `@rules_flutter//flutter:material_icons`
    # in deps — the same channel cupertino_icons et al. arrive through.
    fonts, extra_asset_copies = aggregate_pub_contributions(ctx.attr.deps)

    output_dir = flutter_asset_bundle_action(
        ctx = ctx,
        dart = flutter_sdk_info.dart,
        flutter_sdk_files = flutter_sdk_info.tool_files,
        assets = all_assets,
        fonts = fonts,
        notices = "",
        output_dir_name = ctx.label.name,
        extra_asset_copies = extra_asset_copies,
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
        ),
        "_asset_bundle_tool": attr.label(
            default = _TOOL,
            allow_single_file = True,
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ],
    doc = "Generates a flutter_assets/ tree artifact with manifests and asset files.",
)
