"""Implementation of the flutter_library rule."""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_info", "derive_lib_root", "derive_package_name")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_info.bzl", "flutter_info")

def build_pub_contributions(package_name, fonts_json, font_files_dict, pkg_assets_dict, pkg_shaders_dict):
    """Build pub_fonts/pub_assets/pub_shaders contribution structs from rule attrs.

    Decodes the JSON-encoded font declarations and walks the file dicts,
    producing the contribution structs that `build_flutter_providers` accepts
    as `extra_pub_fonts` / `extra_pub_assets` / `extra_pub_shaders`.

    Args:
        package_name: str — empty string for non-package contributions
            (no `packages/<pkg>/` prefix at bundle time), else the pub package
            name (or first-party package name) used as the prefix.
        fonts_json: str — JSON-encoded list of
            `{family: str, fonts: [{asset: str, weight: int?, style: str?}]}`.
            Empty string when the rule declares no fonts.
        font_files_dict: dict[Target, str] — `ctx.attr.font_files`. Each
            target must resolve to exactly one File. The string value is the
            package-relative asset path matching an entry in fonts_json.
        pkg_assets_dict: dict[Target, str] — `ctx.attr.pkg_assets`. Same
            shape, for non-font assets.
        pkg_shaders_dict: dict[Target, str] — `ctx.attr.pkg_shaders`. Same
            shape, for shaders.

    Returns:
        Tuple of (extra_pub_fonts, extra_pub_assets, extra_pub_shaders) lists.
    """
    extra_pub_fonts = []
    if fonts_json:
        decoded = json.decode(fonts_json)
        path_to_file = {}
        for target, asset_path in font_files_dict.items():
            files = target.files.to_list()
            if len(files) != 1:
                fail("font_files entry %s must resolve to exactly one File; got %d" % (target.label, len(files)))
            path_to_file[asset_path] = files[0]

        # Tuples (not lists) inside the struct because depset elements must
        # be fully immutable — mutable fields propagate to the struct's
        # mutability check.
        for family_entry in decoded:
            family = family_entry.get("family", "")
            fonts_list = []
            file_list = []
            for font in family_entry.get("fonts", []):
                asset_path = font.get("asset", "")
                fonts_list.append(struct(
                    asset_path = asset_path,
                    weight = font.get("weight"),
                    style = font.get("style"),
                ))
                if asset_path in path_to_file:
                    file_list.append(path_to_file[asset_path])
            extra_pub_fonts.append(struct(
                package_name = package_name,
                family = family,
                fonts = tuple(fonts_list),
                files = tuple(file_list),
            ))

    extra_pub_assets = []
    for target, asset_path in pkg_assets_dict.items():
        files = target.files.to_list()
        if len(files) != 1:
            fail("pkg_assets entry %s must resolve to exactly one File; got %d" % (target.label, len(files)))
        extra_pub_assets.append(struct(
            package_name = package_name,
            asset_path = asset_path,
            file = files[0],
        ))

    extra_pub_shaders = []
    for target, shader_path in pkg_shaders_dict.items():
        files = target.files.to_list()
        if len(files) != 1:
            fail("pkg_shaders entry %s must resolve to exactly one File; got %d" % (target.label, len(files)))
        extra_pub_shaders.append(struct(
            package_name = package_name,
            shader_path = shader_path,
            file = files[0],
        ))

    return (extra_pub_fonts, extra_pub_assets, extra_pub_shaders)

def aggregate_pub_contributions(deps):
    """Walk transitive `FlutterInfo.pub_fonts` / `pub_assets` from deps.

    Each contribution carries `package_name` — the empty string sentinel
    means "non-package contribution, bundle at bare path"; any other value
    triggers a `packages/<package_name>/` prefix on the family name and
    every asset path. This matches Flutter's CLI behavior and the const
    finder's tree-shaking key shape (`packages/<pkg>/<family>` only when
    the IconData has a non-null `fontPackage`).

    Args:
        deps: List of Targets — typically `ctx.attr.deps`.

    Returns:
        Tuple of:
          - fonts: list of FontManifest entries (dicts) with prefixed family
            + per-font asset paths and optional weight/style.
          - extra_asset_copies: dict[str, File] mapping bundle dest path to
            File for both fonts and non-font pub-package assets.
    """
    pub_fonts = []
    pub_assets = []
    for dep in deps:
        if FlutterInfo not in dep:
            continue
        info = dep[FlutterInfo]
        pub_fonts.extend(info.pub_fonts.to_list())
        pub_assets.extend(info.pub_assets.to_list())

    fonts = []
    extra_asset_copies = {}

    for entry in pub_fonts:
        prefix = "packages/{}/".format(entry.package_name) if entry.package_name else ""
        family_str = prefix + entry.family
        fonts_descriptors = []
        for i, font in enumerate(entry.fonts):
            descriptor = {"asset": prefix + font.asset_path}
            if font.weight != None:
                descriptor["weight"] = font.weight
            if font.style != None:
                descriptor["style"] = font.style
            fonts_descriptors.append(descriptor)
            if i < len(entry.files):
                extra_asset_copies[prefix + font.asset_path] = entry.files[i]
        fonts.append({"family": family_str, "fonts": fonts_descriptors})

    for entry in pub_assets:
        prefix = "packages/{}/".format(entry.package_name) if entry.package_name else ""
        extra_asset_copies[prefix + entry.asset_path] = entry.file

    return (fonts, extra_asset_copies)

def _flutter_library_impl(ctx):
    package_name = derive_package_name(
        ctx.attr.package_name,
        ctx.label.package,
        ctx.label.name,
    )
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # The asset-prefix package name uses the rule's `package_name` attr
    # verbatim (empty string sentinel = bare paths, non-empty = `packages/X/`).
    # Distinct from the Dart package name in DartInfo, which always derives a
    # value via derive_package_name. Users opting out of asset prefixing leave
    # `package_name` unset.
    asset_pkg = ctx.attr.package_name
    extra_pub_fonts, extra_pub_assets, extra_pub_shaders = build_pub_contributions(
        asset_pkg,
        ctx.attr.fonts_json,
        ctx.attr.font_files,
        ctx.attr.pkg_assets,
        ctx.attr.pkg_shaders,
    )

    # `resources` names the non-Dart remainder of `lib/`; a Dart source there
    # is a mis-filed `srcs` entry, and identical paths with identical
    # extensions would otherwise collide silently. Mirrors `dart_library`.
    for f in ctx.files.resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the non-Dart remainder of `lib/`; Dart sources belong in " +
                 "`srcs`.") % (ctx.label, f.short_path),
            )

    # Both providers are built by their own constructor, and each merges its
    # dependencies' closures itself. This rule states only what a
    # `flutter_library` contributes, which is what keeps a field added to
    # either provider from becoming a change here.
    #
    # `resources` and the pub-asset attrs are orthogonal channels. `resources`
    # says a file is part of the package's `lib/` tree — addressable as
    # `package:<name>/<path>`, staged wherever the whole package is staged
    # (the analyzer's project tree, `dart_test`/`dart_binary` runfiles).
    # `pkg_assets`/`pkg_shaders`/`font_files` say a file is transformed and
    # bundled into flutter_assets. A shader under `lib/` is legitimately both.
    #
    # Code assets go on the package record, which is what makes them propagate
    # the way pub does: depending on a package that owns one is enough, and no
    # consumer has to name it. rules_dart owns the declaration
    # (`DartCodeAssetInfo`) and enforces that each asset id is namespaced to the
    # package declaring it; everything Flutter adds — bundle filename, the
    # per-platform bundle slot — is applied later by the application rule.
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs + ctx.files.resources),
            runfiles = ctx.runfiles(
                files = ctx.files.srcs + ctx.files.resources + ctx.files.assets,
            ),
        ),
        dart_info(
            label = ctx.label,
            package_name = package_name,
            lib_root = lib_root,
            deps = ctx.attr.deps,
            srcs = ctx.files.srcs,
            resources = ctx.files.resources,
            code_assets = ctx.attr.code_assets,
            language_version = ctx.attr.language_version,
            version = ctx.attr.version,
            has_unreplaced_hook = ctx.attr.has_unreplaced_hook,
        ),
        flutter_info(
            deps = ctx.attr.deps,
            asset_dirs = ctx.files.assets,
            shader_srcs = ctx.files.shaders,
            pub_fonts = extra_pub_fonts,
            pub_assets = extra_pub_assets,
            pub_shaders = extra_pub_shaders,
        ),
    ]

flutter_library = rule(
    implementation = _flutter_library_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Dart source files for this library.",
            allow_files = [".dart"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Other `dart_library` or `flutter_library` targets this library depends on.",
            providers = [DartInfo],
        ),
        "resources": attr.label_list(
            doc = "Non-Dart files this package ships inside `lib/` — part of its published surface, but never compiled. Anything under `lib/` is addressable as `package:<name>/<path>` whatever its extension, so these are members of the package: they ride `DartInfo.transitive_resources` and are staged wherever the whole package is staged (the analyzer's project tree, `dart_test`/`dart_binary` runfiles), mirroring `dart_library`. Orthogonal to `pkg_assets`/`pkg_shaders`/`font_files`, which name flutter_assets bundle contributions — a `lib/` shader is legitimately both. `.dart` files belong in `srcs`.",
            allow_files = True,
        ),
        "assets": attr.label_list(
            doc = "Flutter asset files (images, fonts, etc.) declared in pubspec.yaml.",
            allow_files = True,
        ),
        "shaders": attr.label_list(
            doc = "Shader source files (.frag/.glsl) to compile per-platform and include in the asset bundle.",
            allow_files = [".frag", ".glsl"],
        ),
        "package_name": attr.string(
            doc = "The Dart package name. If omitted, defaults to the last component of the Bazel package path.",
        ),
        "code_assets": attr.label_list(
            doc = "`dart_code_asset` targets standing in for this package's " +
                  "`hook/build.dart` output. Declared on the owning package " +
                  "rather than on the consuming application so they propagate " +
                  "the way pub's own do — depending on the package is enough.",
            providers = [DartCodeAssetInfo],
        ),
        "has_unreplaced_hook": attr.string(
            doc = "Path of a build hook this package ships that nothing " +
                  "replaces, or empty. Recorded at repo generation; the " +
                  "application that depends on the package fails on it.",
        ),
        "version": attr.string(
            doc = "The package's own version, as resolved by pub (e.g. `2.2.0`). " +
                  "Set automatically by the generated pub spokes; leave it empty on " +
                  "hand-written targets, which have no resolved version to state. " +
                  "Mirrors `dart_library`'s attribute, and has its one use: when a " +
                  "single package name arrives from two hubs, two records stating " +
                  "different versions fail the build instead of the first one " +
                  "silently standing in for the second. An empty version never " +
                  "conflicts.",
        ),
        "language_version": attr.string(
            doc = "Dart language version (`<major>.<minor>`) for this package's `package_config.json` entry. Mirrors `dart_library`'s attribute. Empty string means defer to the toolchain default.",
        ),
        "fonts_json": attr.string(
            doc = "JSON-encoded list of font-family declarations (mirrors `flutter.fonts` in pubspec.yaml). Each entry: `{family: str, fonts: [{asset: str, weight: int?, style: str?}]}`. The `asset` paths are package-relative and must each match a key in `font_files`. The asset bundle aggregator prefixes family + asset paths with `packages/<package_name>/` when this rule's `package_name` is non-empty (empty = bare paths, used for non-package contributions like the toolchain MaterialIcons target).",
            default = "",
        ),
        "font_files": attr.label_keyed_string_dict(
            doc = "Map of font File label -> package-relative asset path. The string value must match an `asset` field in `fonts_json`. The file is bundled at `packages/<package_name>/<path>` (or bare `<path>` when `package_name` is empty).",
            allow_files = True,
        ),
        "pkg_assets": attr.label_keyed_string_dict(
            doc = "Map of asset File label -> package-relative path (mirrors `flutter.assets` in pubspec.yaml). Bundled at `packages/<package_name>/<path>` (or bare `<path>` when `package_name` is empty); also included in AssetManifest.",
            allow_files = True,
        ),
        "pkg_shaders": attr.label_keyed_string_dict(
            doc = "Map of shader File label -> package-relative path (mirrors `flutter.shaders` in pubspec.yaml). Routed through the impellerc compile and bundled at `packages/<package_name>/<path>` (or bare `<path>` when `package_name` is empty).",
            allow_files = True,
        ),
    },
    doc = "Collects Flutter sources and assets, propagates DartInfo and FlutterInfo. Does not compile.",
)
