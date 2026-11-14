"""Implementation of the flutter_library rule."""

load("@rules_dart//dart:providers.bzl", "DartInfo", "DartUsedWithoutImportInfo")
load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "LIBRARY_IMPORT_CHECKER_ATTRS", "PORTABLE_EXEC_GROUPS", "RUNTIME_INDEPENDENT_ATTR", "SUMMARY_ATTRS", "dart_analyzable_info", "dart_info", "derive_package_root", "library_import_check", "library_package", "package_identity_attrs", "runtime_reset_when_independent")
load("//flutter:providers.bzl", "FlutterFontFamilyInfo", "FlutterInfo")
load("//flutter/private:flutter_font.bzl", "FONTS_ATTR")
load("//flutter/private:flutter_info.bzl", "flutter_info")

def package_root_of(owner):
    """The root of the Dart package `owner` is in: the directory above `lib/`.

    Args:
        owner: A program's inputs (`flutter_program_inputs`), which carry the
            root of the package the program is in, or a rule context or
            anything else with a `label`, whose root it is from its BUILD
            file's directory.

    Returns:
        The root's short_path, "" for the main repository's root.
    """
    if type(owner) == "struct" and hasattr(owner, "package_root"):
        return owner.package_root
    return derive_package_root(owner.label.workspace_root, owner.label.package)

def path_in_package(label, root, f):
    """The path of `f` from the root of its Dart package.

    This is an asset's path as the package's pubspec lists it
    (`assets/a.png`, `lib/src/a.png`), whatever the package's place in the
    workspace, the repository it belongs to, or the BUILD file that names the
    file: the path `flutter build` keys it by. A file outside the package has
    no such path, so it fails rather than being given some other.

    Args:
        label: The target that lists `f`, for the error.
        root: The package root, from `derive_package_root` or `package_root_of`.
        f: A File of the package rooted at `root`.

    Returns:
        The path of `f` relative to `root`.
    """
    path = f.short_path
    prefix = root + "/" if root else ""
    if (prefix and not path.startswith(prefix)) or (not prefix and path.startswith("../")):
        fail("%s: the asset %s is not in the Dart package rooted at %s. An asset is keyed by its path from the root of the package that lists it (the directory above `lib/`), so list it from its own package." % (label, f.short_path, root or "the workspace root"))
    return path[len(prefix):]

def asset_key(entry, path, program_root):
    """The key `path` of a package's contribution has in a program's bundle.

    flutter_tools decides it per program: what the program's own package
    lists is bare (`assets/a.png`), what any other package lists is under
    `packages/<name>/`. A contribution of no package (the Material icon font)
    is bare everywhere.

    Args:
        entry: A `pub_assets`, `pub_fonts` or `pub_shaders` struct.
        path: The path (or font family) as the package declares it.
        program_root: The root of the program's own package, from
            `package_root_of`; None for a bundle of no package's, where every
            package is another's.

    Returns:
        The key.
    """
    if not entry.package_name or entry.package_root == program_root:
        return path
    return "packages/{}/{}".format(entry.package_name, path)

ADDITIONAL_LICENSES_ATTR = attr.label_list(
    doc = "Licence files beyond the package's `LICENSE`: what its pubspec's `flutter: licenses:` lists. " +
          "An application that depends on the package appends them to its `NOTICES` as they are.",
    allow_files = True,
)

def own_additional_licenses(ctx, package_name):
    """The `additional_licenses` entries for the `additional_licenses` of a library or plugin.

    Args:
        ctx: Rule context with an `additional_licenses` attribute.
        package_name: The Dart package name the files are listed under.

    Returns:
        A list of one `struct(package_name, files)`, or none for a package that lists nothing.
    """
    if not ctx.files.additional_licenses:
        return []
    return [struct(package_name = package_name, files = tuple(ctx.files.additional_licenses))]

def build_pub_contributions(ctx, package_name, package_root):
    """The fonts, assets and shaders a library or plugin bundles, as `FlutterInfo` contributions.

    Keys each font, asset and shader by its path from the package root, producing the contribution structs
    that `flutter_info` takes as `pub_fonts` / `pub_assets` / `pub_shaders`.

    Args:
        ctx: The rule context of a `flutter_library`, `flutter_plugin` or
            `flutter_pub_member`. Reads `fonts`, `assets`,
            `shaders`, `shader_includes`, and the platforms and flavors the
            assets and shaders are restricted to.
        package_name: str — the Dart package the contributions are of.
        package_root: str — that package's root, from `derive_package_root`. A
            program whose own package this is bundles them bare, any other
            under `packages/<package_name>/` (see `asset_key`).

    Returns:
        Tuple of (pub_fonts, pub_assets, pub_shaders) lists.
    """

    # Tuples (not lists) inside the struct because depset elements must be
    # fully immutable — mutable fields propagate to the struct's mutability
    # check.
    extra_pub_fonts = []
    for family in ctx.attr.fonts:
        info = family[FlutterFontFamilyInfo]
        extra_pub_fonts.append(struct(
            package_name = package_name,
            package_root = package_root,
            family = info.family,
            fonts = tuple([
                struct(
                    asset_path = font.asset or path_in_package(ctx.label, package_root, font.file),
                    of_other_package = font.asset != None,
                    file = font.file,
                    weight = font.weight,
                    style = font.style,
                )
                for font in info.fonts
            ]),
        ))

    # Only a generated pub package's member has `bundle_paths`: the files its
    # pubspec names `packages/<the package>/x`, which are its `lib/x`.
    bundle_paths = getattr(ctx.attr, "bundle_paths", {})

    asset_platforms = ctx.attr.asset_platforms
    asset_flavors = ctx.attr.asset_flavors
    asset_paths = []
    extra_pub_assets = []
    for f in ctx.files.assets:
        path = path_in_package(ctx.label, package_root, f)
        asset_paths.append(path)
        extra_pub_assets.append(struct(
            package_name = package_name,
            package_root = package_root,
            asset_path = bundle_paths.get(path, path),
            file = f,
            platforms = tuple(asset_platforms.get(path, [])),
            flavors = tuple(asset_flavors.get(path, [])),
        ))

    shader_platforms = ctx.attr.shader_platforms
    shader_flavors = ctx.attr.shader_flavors
    shader_paths = []
    extra_pub_shaders = []
    for f in ctx.files.shaders:
        path = path_in_package(ctx.label, package_root, f)
        shader_paths.append(path)
        extra_pub_shaders.append(struct(
            package_name = package_name,
            package_root = package_root,
            shader_path = bundle_paths.get(path, path),
            file = f,
            includes = tuple(ctx.files.shader_includes),
            platforms = tuple(shader_platforms.get(path, [])),
            flavors = tuple(shader_flavors.get(path, [])),
        ))

    # A restriction of a path the target does not list would restrict
    # nothing: a misspelt path would ship everywhere, silently.
    for attr_name, restricted, paths, listing in [
        ("asset_platforms", asset_platforms, asset_paths, "assets"),
        ("asset_flavors", asset_flavors, asset_paths, "assets"),
        ("shader_platforms", shader_platforms, shader_paths, "shaders"),
        ("shader_flavors", shader_flavors, shader_paths, "shaders"),
        ("bundle_paths", bundle_paths, asset_paths + shader_paths, "assets` or `shaders"),
    ]:
        for path in restricted:
            if path not in paths:
                fail("%s: `%s` names %s, which is not the path of any file of its `%s` %s." % (ctx.label, attr_name, repr(path), listing, paths))

    return (extra_pub_fonts, extra_pub_assets, extra_pub_shaders)

def bundled_without_import(pub_fonts, pub_assets, pub_shaders):
    """`DartUsedWithoutImportInfo` for a package that puts files in the app's bundle, or nothing.

    An app gets a package's fonts, assets and shaders by depending on it, and
    loads them by key (`packages/<name>/<path>`), not by an import: a
    dependent that lists `cupertino_icons` for its font imports nothing of it.

    Args:
        pub_fonts: The package's own fonts, from `build_pub_contributions`.
        pub_assets: Its own assets.
        pub_shaders: Its own shaders.

    Returns:
        A list of the provider, or an empty one.
    """
    return [DartUsedWithoutImportInfo()] if pub_fonts or pub_assets or pub_shaders else []

def ships_on(platforms, target_platform):
    """Whether a pub asset or shader restricted to `platforms` is in a bundle for `target_platform`.

    Args:
        platforms: The platforms its `platforms:` entry names; empty for
            all of them.
        target_platform: The platform the bundle is for (`android`, `ios`,
            `linux`, `macos`, `windows`, `web`, or `tester`). None, and `tester`,
            which `flutter test` bundles for, leave out nothing.

    Returns:
        True if the bundle holds it.
    """
    return not platforms or target_platform in (None, "tester") or target_platform in platforms

def ships_in(entry, target_platform, flavor):
    """Whether a pub asset or shader is in a bundle for `target_platform` and `flavor`.

    Its `platforms:` as `ships_on` reads them; its `flavors:` as flutter_tools
    matches them: no flavors is every build, otherwise a build of one of
    them, never a build without a flavor (`tester` included).

    Args:
        entry: A `pub_assets` or `pub_shaders` struct.
        target_platform: As for `ships_on`.
        flavor: The flavor the bundle is for; empty or None for none.

    Returns:
        True if the bundle holds it.
    """
    if entry.flavors and flavor not in entry.flavors:
        return False
    return ships_on(entry.platforms, target_platform)

def aggregate_pub_contributions(deps, target_platform = None, flavor = "", program_root = None):
    """Walk transitive `FlutterInfo.pub_fonts` / `pub_assets` from deps.

    Each contribution is keyed for the program as `asset_key` says: bare when
    it is of the program's own package (`program_root`) or of no package (the
    Material icon font), under `packages/<package_name>/` otherwise, the font
    family included. A font naming another package's file keeps that path.
    This matches Flutter's CLI behavior and the const finder's tree-shaking
    key shape (`packages/<pkg>/<family>` only when the IconData has a non-null
    `fontPackage`).

    Args:
        deps: List of Targets — typically `ctx.attr.deps`.
        target_platform: The platform the bundle is for (`android`, `ios`,
            `linux`, `macos`, `windows`, `web`, or `tester`). An asset a
            package restricts to other platforms with `platforms:` is left
            out. None, and `tester`, which `flutter test` bundles for, leave
            out nothing.
        flavor: The flavor the bundle is for; empty for none. An asset a
            package restricts to flavors with `flavors:` is bundled only in a
            build of one of them, and in none without a flavor.
        program_root: The root of the program's own package, from
            `package_root_of`; None for a bundle that is no package's.

    Returns:
        Tuple of:
          - fonts: list of FontManifest entries (dicts) with the keyed family
            and per-font asset paths and optional weight/style.
          - copies: list of (bundle path, File) for both fonts and non-font
            pub-package assets, to be listed in the asset manifest.
          - unlisted_copies: the same for the files that are bundled but are
            no entry of the manifest, as flutter_tools has it for the Material
            icon font. Two entries may name one path; telling whether that is
            one file reached twice or a conflict is for the bundle action.
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
    copies = []
    unlisted_copies = []

    for entry in pub_fonts:
        fonts_descriptors = []
        for font in entry.fonts:
            key = font.asset_path if font.of_other_package else asset_key(entry, font.asset_path, program_root)
            descriptor = {"asset": key}
            if font.weight != None:
                descriptor["weight"] = font.weight
            if font.style != None:
                descriptor["style"] = font.style
            fonts_descriptors.append(descriptor)
            (copies if getattr(entry, "listed", True) else unlisted_copies).append((key, font.file))
        fonts.append({"family": asset_key(entry, entry.family, program_root), "fonts": fonts_descriptors})

    for entry in pub_assets:
        if not ships_in(entry, target_platform, flavor):
            continue
        copies.append((asset_key(entry, entry.asset_path, program_root), entry.file))

    return (fonts, copies, unlisted_copies)

SHADER_PLATFORMS_ATTR = attr.string_list_dict(
    doc = "For a shader of `shaders` that ships on some platforms only (a `platforms:` entry of `flutter: shaders:`), its package-relative path and the platforms (`android`, `ios`, `linux`, `macos`, `windows`, `web`). A shader not listed here ships on every platform.",
)

SHADER_FLAVORS_ATTR = attr.string_list_dict(
    doc = "For a shader of `shaders` that ships in some flavors only (a `flavors:` entry of `flutter: shaders:`), its package-relative path and the flavors. A shader not listed here ships in every build.",
)

ASSET_FLAVORS_ATTR = attr.string_list_dict(
    doc = "For an asset of `assets` that ships in some flavors only (a `flavors:` entry of `flutter: assets:`), its package-relative path and the flavors. An asset not listed here ships in every build.",
)

ASSET_PLATFORMS_ATTR = attr.string_list_dict(
    doc = "For an asset of `assets` that ships on some platforms only (a `platforms:` entry of `flutter: assets:`), its package-relative path and the platforms (`android`, `ios`, `linux`, `macos`, `windows`, `web`). An asset not listed here ships on every platform.",
)

# Analysis-only: `package:sky_engine`'s `lib/_embedder.yaml` is the only way the
# analyzer resolves `dart:ui`. Reaches `flutter_analyzable_info` and the
# library's analyzer summary (`dart_info(analysis_deps = ...)`) alone, so no
# compile action's inputs change.
SKY_ENGINE_ATTR = attr.label(
    doc = "Analysis-only: supplies `lib/_embedder.yaml`, the only way the analyzer resolves `dart:ui`.",
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)

def flutter_analyzable_info(ctx, package):
    """The package a Flutter library rule declares, as the analyzer sees it.

    The same package its `DartInfo` records, with `package:sky_engine` added.
    Compilation gets `dart:ui` from the patched SDK; the analyzer resolves it
    only through `sky_engine`'s `lib/_embedder.yaml`, so without this every
    `dart:ui` import is unresolved. `DartInfo` is untouched, so no compile input
    changes, and the analyzer prefers this provider when a target has both.

    Args:
      ctx: The rule context. Reads `deps`, `srcs`, `resources` and
        `_sky_engine` (`SKY_ENGINE_ATTR`).
      package: The target's `DartPackageInfo`, from `library_package`.

    Returns:
      A `DartAnalyzableInfo`.
    """
    return flutter_analyzable_info_of_packages(ctx, [package], ctx.files.srcs, ctx.files.resources)

def flutter_analyzable_info_of_packages(ctx, packages, srcs, resources):
    """As `flutter_analyzable_info`, for a target that is several packages.

    Args:
      ctx: The rule context. Reads `deps` and `_sky_engine` (`SKY_ENGINE_ATTR`).
      packages: The target's `DartPackageInfo`s.
      srcs: The Dart sources of all of them.
      resources: Their other files under `lib/`.

    Returns:
      A `DartAnalyzableInfo`.
    """
    return dart_analyzable_info(
        label = ctx.label,
        packages = packages,
        deps = ctx.attr.deps + [ctx.attr._sky_engine],
        srcs = srcs,
        resources = resources,
    )

def _flutter_library_impl(ctx):
    declared = library_package(ctx, ctx.files.srcs, ctx.files.resources)
    package_name = declared.package_name
    package_root = declared.package_root
    package = declared.record

    # Every asset, font and shader is of the Dart package in DartInfo, by name
    # and root, so `package:` imports and asset keys cannot disagree. Each
    # program decides from the root whether it is its own package's.
    extra_pub_fonts, extra_pub_assets, extra_pub_shaders = build_pub_contributions(ctx, package_name, package_root)

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
    # `assets`/`shaders`/`fonts` say a file is transformed and
    # bundled into flutter_assets. A shader under `lib/` is legitimately both.
    #
    # Code assets go on the package record, which is what makes them propagate
    # the way pub does: depending on a package that owns one is enough, and no
    # consumer has to name it. rules_dart owns the declaration
    # (`DartCodeAssetInfo`) and enforces that each asset id is namespaced to the
    # package declaring it; everything Flutter adds — bundle filename, the
    # per-platform bundle slot — is applied later by the application rule.
    info = dart_info(
        ctx = ctx,
        packages = [package],
        deps = ctx.attr.deps,
        srcs = ctx.files.srcs,
        resources = ctx.files.resources,
        analysis_deps = [ctx.attr._sky_engine],
        data = ctx.attr.data,
    )
    runfiles = ctx.runfiles(
        files = ctx.files.srcs + ctx.files.resources + ctx.files.assets,
    )
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs + ctx.files.resources),
            runfiles = runfiles.merge(info.runfiles) if info.runfiles != None else runfiles,
        ),
        info,
        flutter_analyzable_info(ctx, package),
        flutter_info(
            deps = ctx.attr.deps,
            shader_srcs = getattr(ctx.files, "framework_shaders", []),
            pub_fonts = extra_pub_fonts,
            pub_assets = extra_pub_assets,
            pub_shaders = extra_pub_shaders,
            additional_licenses = own_additional_licenses(ctx, package_name),
        ),
        # The sources `bazel coverage` may report of this package, as
        # `dart_library`'s.
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["deps"],
            extensions = ["dart"],
        ),
        # Its imports, checked against its `deps` as `dart_library`'s are,
        # every dep among them named by an import or export of `srcs`.
    ] + library_import_check(ctx, list(info.packages)) + bundled_without_import(extra_pub_fonts, extra_pub_assets, extra_pub_shaders)

# A library's `data`, as `dart_library`'s: the runfiles of whatever runs it on
# the host, never what an application ships.
LIBRARY_DATA_ATTR = attr.label_list(
    doc = "Files the library needs at run time when it runs on the host, " +
          "outside its package's `lib/`: a fixture, a model, a tool it runs. " +
          "Never compile inputs. With their own runfiles they join the " +
          "runfiles of every `flutter_test`, `flutter_tester_binary` and " +
          "rules_dart `dart_test`/`dart_binary` that reaches this library, " +
          "as `dart_library.data` does, and are found there with `rlocation`. " +
          "An application does not ship them, any more than `flutter build` " +
          "ships a package file its pubspec does not list as an asset: what " +
          "an app loads at run time is one of `assets`.",
    allow_files = True,
)

_LIBRARY_ATTRS = package_identity_attrs() | {
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
        doc = "Non-Dart files this package ships inside `lib/` — part of its published surface, but never compiled. Anything under `lib/` is addressable as `package:<name>/<path>` whatever its extension, so these are members of the package: they ride `DartInfo.transitive_resources` and are staged wherever the whole package is staged (the analyzer's project tree, `dart_test`/`dart_binary` runfiles), mirroring `dart_library`. Orthogonal to `assets`/`shaders`/`fonts`, which name flutter_assets bundle contributions — a `lib/` shader is legitimately both. `.dart` files belong in `srcs`.",
        allow_files = True,
    ),
    "assets": attr.label_list(
        doc = "Flutter asset files (images, fonts, etc.) declared in pubspec.yaml: any file of this target's Dart package. The path of each is its path from the package root (the directory above `lib/`), as the pubspec lists it. A program of another package bundles it at `packages/<package_name>/<path>`; a program of this package (its own `flutter_test`, or the application whose code this is) bundles it at `<path>`, as `flutter build` keys what a pubspec lists.",
        allow_files = True,
    ),
    "shaders": attr.label_list(
        doc = "The package's fragment shaders, mirroring `flutter: shaders:` in pubspec.yaml: any file of this target's Dart package, compiled with impellerc. The path of each is its path from the package root, as the pubspec lists it. A program of another package bundles it at `packages/<package_name>/<path>`; a program of this package (its own `flutter_test`, or the application whose code this is) bundles it at `<path>`, as `flutter build` keys them and where `FragmentProgram.fromAsset` looks.",
        allow_files = True,
    ),
    "data": LIBRARY_DATA_ATTR,
    "fonts": FONTS_ATTR,
    "additional_licenses": ADDITIONAL_LICENSES_ATTR,
    "asset_platforms": ASSET_PLATFORMS_ATTR,
    "shader_platforms": SHADER_PLATFORMS_ATTR,
    "asset_flavors": ASSET_FLAVORS_ATTR,
    "shader_flavors": SHADER_FLAVORS_ATTR,
    "_sky_engine": SKY_ENGINE_ATTR,
    "shader_includes": attr.label_list(
        doc = "Files this package's `shaders` may `#include` (e.g. " +
              "`glob([\"shaders/**/*.glsl\"])`). A shader compiles in a " +
              "sandbox holding only its declared inputs, so an include " +
              "not listed here is not found.",
        allow_files = True,
    ),
} | RUNTIME_INDEPENDENT_ATTR | SUMMARY_ATTRS | LIBRARY_IMPORT_CHECKER_ATTRS

flutter_library = rule(
    implementation = _flutter_library_impl,
    # A library reached under a web bundle's compilers is configured once for
    # each, unless it says `runtime_independent` (every generated pub and
    # SDK package does), which builds it once with no web compiler.
    cfg = runtime_reset_when_independent,
    attrs = _LIBRARY_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Collects Flutter sources and assets, propagates DartInfo and FlutterInfo. Does not compile.",
)

flutter_framework_library = rule(
    implementation = _flutter_library_impl,
    cfg = runtime_reset_when_independent,
    attrs = _LIBRARY_ATTRS | {
        "framework_shaders": attr.label_list(
            doc = "The Flutter framework's own shaders, compiled per platform and bundled at `shaders/<file name>`, unlisted in the asset manifest, as flutter_tools bundles them. No pubspec declares them: flutter_tools hardcodes them.",
            allow_files = [".frag", ".glsl"],
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "`package:flutter`, the framework: a `flutter_library` that also bundles the framework's own shaders. Only the framework's spoke repository declares one.",
)
