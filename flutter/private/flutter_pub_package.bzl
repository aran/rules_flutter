"""flutter_pub_package — the `flutter pub get` analog for a single hosted
Flutter pub.dev package.

For each package in a Flutter app's pubspec.lock this rule:
  1. Downloads the same `pub.dev/api/packages/<name>/versions/<version>.tar.gz`
     archive that rules_dart's `pub_lock_package` would.
  2. Reads the package's pubspec.yaml.
  3. Parses `flutter.plugin.platforms` via `parse_flutter_plugin_block`.
  4. Scans the extracted package tree for per-platform Apple source layouts
     (modern SwiftPM `<platform>/<pkg>/Sources/<pkg>/`, shared-darwin
     `darwin/Classes/`, legacy `<platform>/Classes/`).
  5. Branches on whether a `flutter.plugin` block is present:
       - Absent → emit a plain `dart_library` via rules_dart's
         `make_dart_library_build_content`. Pure-Dart pub packages reach
         consumers exactly as they do under `pub.pub()`.
       - Present → emit a `flutter_plugin` whose `plugin_platforms_json`
         carries the parsed metadata, plus per-platform sub-targets:
         `:<pkg>_apple_macos` / `:<pkg>_apple_ios` `flutter_apple_plugin_library`
         when Apple sources are detected for the corresponding
         `flutter.plugin.platforms.<plat>` entry.

This is the rules_flutter sibling of rules_dart's `pub_lock_package`. The
two rules never run for the same package: `flutter.pub()` always invokes
this one for hosted pub packages; `pub.pub()` (in non-Flutter modules)
keeps using `pub_lock_package`. Both share the same archive download +
extract pattern (replicated, not abstracted, to keep the cross-repo
surface small).
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "derive_language_version", "make_dart_library_build_content", "trim_gzip_trailing_nulls")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint")
load("//flutter/private:artifact_urls.bzl", "require_sha256")
load("//flutter/private:download.bzl", "pinned_download")
load("//flutter/private:flutter_pubspec.bzl", "asset_flavor_error", "asset_platform_error", "invalid_asset_platforms", "parse_flutter_assets_block", "parse_flutter_plugin_block")
load(
    ":gradle.bzl",
    "detect_android_namespace",
    "detect_android_native_build",
    "detect_consumer_proguard_specs",
    "plugin_android_build",
    "resolve_plugin_maven_deps",
    _gradle_is_java_package_name = "is_java_package_name",
    _gradle_is_maven_dep_label = "is_maven_dep_label",
    _gradle_maven_labels_for_gradle = "maven_labels_for_gradle",
    _gradle_parse_android_manifest_package = "parse_android_manifest_package",
    _gradle_parse_gradle_android_namespace = "parse_gradle_android_namespace",
)
load(":starlark_literal.bzl", "check_spoke_file_name", "decode_starlark_escapes", "starlark_string_literal")

def parse_gradle_android_namespace(content, language = "groovy"):
    """Extract `android.namespace` from a Gradle build script.

    Moved to `//flutter/private:gradle.bzl`; kept here with the same
    signature so existing loads keep working.
    """
    return _gradle_parse_gradle_android_namespace(content, language)

def parse_android_manifest_package(content):
    """Extract the `package` attribute from an AndroidManifest.xml.

    Moved to `//flutter/private:gradle.bzl`; kept here with the same
    signature so existing loads keep working.
    """
    return _gradle_parse_android_manifest_package(content)

def maven_labels_for_gradle(content, mapping, ignore, read_script = None, language = "groovy"):
    """Translate a Gradle build file's runtime deps to Bazel labels.

    Moved to `//flutter/private:gradle.bzl`; kept here with the same
    signature so existing loads keep working.
    """
    return _gradle_maven_labels_for_gradle(content, mapping, ignore, read_script, language)

def is_java_package_name(value):
    """True when `value` is a well-formed Java package name.

    Moved to `//flutter/private:gradle.bzl`; kept here with the same
    signature so existing loads keep working.
    """
    return _gradle_is_java_package_name(value)

def is_maven_dep_label(value):
    """True when `value` is a plausible Bazel label for `android_maven_deps`.

    Moved to `//flutter/private:gradle.bzl`; kept here with the same
    signature so existing loads keep working.
    """
    return _gradle_is_maven_dep_label(value)

# Apple source extensions we sweep into the per-platform plugin library.
_APPLE_SRC_EXTENSIONS = ("swift", "m", "mm", "h")

# C/C++ source extensions for Linux/Windows plugin libraries.
_DESKTOP_SRC_EXTENSIONS = ("cc", "cpp", "c", "h", "hh", "hpp")

# Kotlin/Java source extensions for Android plugin libraries.
_ANDROID_SRC_EXTENSIONS = ("kt", "java")

def _has_files_under(ctx, relative_path, extensions = None):
    """Check `<package>/<relative_path>` for source files.

    Returns True if the directory exists and contains at least one file
    matching one of `extensions` (any file when `extensions` is None).
    `ctx.path(p).readdir()` is the documented repo-rule way to walk a
    directory; recursing in Starlark keeps the logic local instead of
    forking out to `find`.
    """
    root = ctx.path(relative_path)
    if not root.exists:
        return False

    stack = [root]
    for _ in range(10000):  # bound the walk; pub packages are not deep
        if not stack:
            break
        d = stack.pop()
        if not d.exists:
            continue
        for entry in d.readdir():
            if entry.is_dir:
                stack.append(entry)
            else:
                if extensions == None:
                    return True
                name = entry.basename
                ext = name.rsplit(".", 1)[-1] if "." in name else ""
                if ext in extensions:
                    return True
    return False

def _detect_apple_source_dirs(ctx, package_name, platform, shared_darwin_source):
    """List Apple source directory globs for the given platform.

    Returns the relative-to-package-root directories that contain Apple
    sources for `platform`. Empty list when no sources are detected.
    """
    candidates = []

    # Modern SwiftPM layout: <platform>/<pkg>/Sources/<pkg>/...
    swiftpm_dir = "{plat}/{pkg}/Sources/{pkg}".format(plat = platform, pkg = package_name)
    if _has_files_under(ctx, swiftpm_dir, _APPLE_SRC_EXTENSIONS):
        candidates.append(swiftpm_dir)

    # Shared darwin source layout: darwin/Classes/...
    if shared_darwin_source:
        darwin_dir = "darwin/Classes"
        if _has_files_under(ctx, darwin_dir, _APPLE_SRC_EXTENSIONS):
            candidates.append(darwin_dir)

        # Legacy darwin SwiftPM (older path_provider_foundation versions).
        darwin_swiftpm_dir = "darwin/{pkg}/Sources/{pkg}".format(pkg = package_name)
        if _has_files_under(ctx, darwin_swiftpm_dir, _APPLE_SRC_EXTENSIONS):
            candidates.append(darwin_swiftpm_dir)

    # Legacy split layout: <platform>/Classes/...
    legacy_dir = "{plat}/Classes".format(plat = platform)
    if _has_files_under(ctx, legacy_dir, _APPLE_SRC_EXTENSIONS):
        candidates.append(legacy_dir)

    return candidates

def _detect_apple_include_dirs(ctx, source_dirs, package_name):
    """Collect SwiftPM-canonical public-header directories for the given Apple sources.

    SwiftPM's `publicHeadersPath: "include"` (the default) places public
    headers at `Sources/<Target>/include/[<Module>/]Foo.h` and adds the
    `include` directory to the lib's own header search path. Plugins
    relying on this convention `#import "Foo.h"` (bare basename) from
    sibling `.m` files; without an explicit `-I` flag clang can't find
    the header. Mirror SwiftPM by adding both `include` and the
    `include/<pkg>` nested subdirectory (when present) — covers
    headers placed directly under `include/` and the more common
    umbrella-style layout.
    """
    include_dirs = []
    for src_dir in source_dirs:
        include_root = src_dir + "/include"
        include_root_path = ctx.path(include_root)
        if include_root_path.exists:
            include_dirs.append(include_root)
            nested = include_root + "/" + package_name
            if ctx.path(nested).exists:
                include_dirs.append(nested)
    return include_dirs

def _detect_apple_privacy_manifests(ctx, source_dirs):
    """Find each plugin source dir's `PrivacyInfo.xcprivacy` file.

    Apple requires every framework to ship a privacy manifest since
    iOS 17.4 / macOS 14.4; App Store submission walks the bundle for
    `*.xcprivacy` files and aggregates them into the app's privacy
    report. CocoaPods/SwiftPM bundle them automatically as framework
    resources; we mirror by collecting them here and threading them
    through to `flutter_apple_plugin_library`'s `privacy_manifests`
    attr (which forwards to the inner objc/swift_library `data`).

    Two layouts occur in real plugins:

    * **Pattern A** (e.g. `package_info_plus`, `share_plus`):
      `<source_dir>/PrivacyInfo.xcprivacy`.
    * **Pattern B** (e.g. `path_provider_foundation`, `record_ios`,
      `webview_flutter_wkwebview`):
      `<source_dir>/Resources/PrivacyInfo.xcprivacy`.

    Returns a sorted, deduplicated list of relative paths.
    """
    manifests = {}
    for src_dir in source_dirs:
        for relpath in (
            src_dir + "/PrivacyInfo.xcprivacy",
            src_dir + "/Resources/PrivacyInfo.xcprivacy",
        ):
            if ctx.path(relpath).exists:
                manifests[relpath] = True
    return sorted(manifests.keys())

def _detect_desktop_source_dir(ctx, platform):
    """Return the Linux/Windows source dir if it contains C/C++ files.

    Pub plugins put Linux sources at `linux/` and Windows sources at
    `windows/`. We surface a single source dir per platform (the
    plugin's own conventions); subdirectories like `linux/include/` are
    swept by the resulting glob.
    """
    if _has_files_under(ctx, platform, _DESKTOP_SRC_EXTENSIONS):
        return platform
    return ""

def _detect_android_source_dir(ctx):
    """Return the Android source dir if it contains Kotlin/Java files.

    Pub plugins use the standard Android directory layout
    `android/src/main/{kotlin,java}/`.
    """
    if _has_files_under(ctx, "android/src/main", _ANDROID_SRC_EXTENSIONS):
        return "android/src/main"
    return ""

def _detect_android_resources(ctx):
    """True when the plugin ships Android resources at `android/src/main/res/`.

    The standard AGP resource location. Detected resources are compiled
    into the generated `kt_android_library` via `resource_files` so the
    plugin's `R` class resolves and the resources merge into the
    consuming APK — same as any Gradle-built Android library.
    """
    return _has_files_under(ctx, "android/src/main/res")

def _detect_android_manifest(ctx):
    """Return the plugin's `android/src/main/AndroidManifest.xml` path if present.

    AGP's `ManifestMerger2` combines each Android library's manifest into
    the consuming app's final AndroidManifest.xml at build time. Plugins
    routinely declare `<activity>`, `<service>`, `<receiver>`,
    `<provider>`, `<uses-permission>`, and `<queries>` entries this way
    (e.g. url_launcher_android's WebViewActivity, record_android's
    RECORD_AUDIO permission). `rules_android`'s `android_binary` runs
    the equivalent merger over its dep graph; a `kt_android_library`
    (which extends `android_library`) participates if it sets
    `manifest = "..."`. Returns the path relative to the spoke root, or
    empty when the plugin ships no manifest.
    """
    if ctx.path("android/src/main/AndroidManifest.xml").exists:
        return "android/src/main/AndroidManifest.xml"
    return ""

def _make_android_native_build_unsupported_content(package_name, version):
    """Generate an `android/BUILD.bazel` that fails at load time.

    Emitted for plugins whose Gradle build compiles native code for Android
    (externalNativeBuild) when no overlay provides a Bazel translation.
    Android builds load this file through the hub's
    `android/all_android_plugin_libs` aggregator and fail with a clear
    message; non-Android platforms never load it and are unaffected.
    """
    message = (
        "package:{pkg} {version} compiles native code for Android via " +
        "Gradle's externalNativeBuild, which rules_flutter cannot " +
        "translate automatically. An APK built without that library would " +
        "crash at plugin registration, so this is a hard error. Provide a " +
        "plugin overlay for {pkg} (flutter.plugin_overlays in MODULE.bazel) " +
        "that compiles the package's native sources with cc_shared_library " +
        "and ships them through flutter_plugin.native_deps — see " +
        "@rules_flutter//ext/jni for the canonical example."
    ).format(pkg = package_name, version = version)

    # The message names a classified package name and a lock version; the
    # whole text still renders as one escaped literal, never spliced raw.
    return "fail(" + starlark_string_literal(message) + ")\n"

def _glob_block(srcs_dirs, extensions):
    """Format a `glob([...])` expression covering the given extensions.

    Each directory in `srcs_dirs` is recursively swept for files matching
    any extension in `extensions`. `test/` and `example/` subtrees are
    excluded — pub plugins routinely ship integration tests next to
    their plugin source, but those should never be linked into the
    runner.
    """
    patterns = []
    excludes = []
    for d in srcs_dirs:
        for ext in extensions:
            patterns.append("{}/**/*.{}".format(d, ext))
        excludes.append("{}/test/**".format(d))
        excludes.append("{}/example/**".format(d))

    # Directories embed the pub package name, which lock classification
    # already refused when quotable; every pattern still renders through the
    # escaping helper, so an odd name lands inert inside a string literal.
    quoted = ["        " + starlark_string_literal(p) + "," for p in patterns]
    excl_quoted = ["        " + starlark_string_literal(e) + "," for e in excludes]
    return "glob(\n        [\n{}\n        ],\n        exclude = [\n{}\n        ],\n        allow_empty = True,\n    )".format("\n".join(quoted), "\n".join(excl_quoted))

def _split_glob_block(srcs_dirs, src_exts, hdr_exts):
    """Format separate srcs/hdrs glob expressions for desktop plugins.

    Returns (srcs_glob, hdrs_glob) so the spoke can pass the lists to
    flutter_linux_plugin_library / flutter_windows_plugin_library
    separately — those rules require .h/.hh/.hpp on `hdrs` and the
    compilable extensions on `srcs`.
    """
    return _glob_block(srcs_dirs, src_exts), _glob_block(srcs_dirs, hdr_exts)

_DESKTOP_HDR_EXTS = ("h", "hh", "hpp")
_DESKTOP_C_EXTS = ("cc", "cpp", "c")

def _readdir_files_recursive(ctx, rel_dir):
    """Recursively walk `<package>/<rel_dir>` and return file paths.

    Returns a list of package-relative paths (e.g. `data/locales.json`).
    Used to expand directory entries from `flutter.assets:` (which Flutter
    treats as "include every file under this directory"). Relative paths
    are tracked structurally alongside the walk, never by trimming a string
    prefix off the walked paths — the tree may be symlinked in (path
    packages), in which case the walked paths do not start with the spoke
    root at all.
    """
    out = []
    base = ctx.path(rel_dir)
    if not base.exists:
        return out
    queue = [(base, rel_dir)]
    for _ in range(10000):  # bounded loop to satisfy Starlark's no-while constraint
        if not queue:
            break
        cur, cur_rel = queue.pop()
        for child in cur.readdir():
            child_rel = cur_rel + "/" + child.basename
            if child.is_dir:
                queue.append((child, child_rel))
            else:
                out.append(child_rel)
    return out

def expand_pub_asset_entries(parsed_assets, list_dir):
    """Expand parsed `flutter.assets` entries to one struct per bundled file.

    Trailing-slash directory entries expand to every file under them, each
    inheriting the entry's `platforms` / `flavors` conditions — the same way
    flutter_tools applies an entry's conditions to the whole directory.

    Args:
        parsed_assets: List of `struct(path, flavors, platforms)` from
            `parse_flutter_assets_block().assets`.
        list_dir: Callable taking a directory path (no trailing slash) and
            returning the file paths under it. Taking it as a parameter
            keeps this pure so unit tests can pass a fake; the spoke passes
            `_readdir_files_recursive` bound to its repo context.

    Returns:
        List of `struct(path, flavors, platforms)`, one per file.
    """
    expanded = []
    for entry in parsed_assets:
        if entry.path.endswith("/"):
            for f in list_dir(entry.path.rstrip("/")):
                expanded.append(struct(
                    path = f,
                    flavors = entry.flavors,
                    platforms = entry.platforms,
                ))
        else:
            expanded.append(struct(
                path = entry.path,
                flavors = entry.flavors,
                platforms = entry.platforms,
            ))
    return expanded

def _encode_fonts_json(parsed_fonts):
    """Convert parse_flutter_assets_block().fonts to the JSON shape flutter_library expects."""
    fonts_for_json = []
    for entry in parsed_fonts:
        fonts_list = []
        for font in entry.fonts:
            d = {"asset": font.asset}
            if font.weight != None:
                d["weight"] = font.weight
            if font.style != None:
                d["style"] = font.style
            fonts_list.append(d)
        fonts_for_json.append({"family": entry.family, "fonts": fonts_list})
    return json.encode(fonts_for_json) if fonts_for_json else ""

def _build_font_files_dict(parsed_fonts):
    """Build the `font_files` label_keyed_string_dict literal — {":path": "path", ...}."""
    out = {}
    for entry in parsed_fonts:
        for font in entry.fonts:
            out[":" + font.asset] = font.asset
    return out

def _build_pkg_assets_dict(expanded):
    """Build the `pkg_assets` dict from expanded per-file entries.

    Flutter's `flutter.assets:` accepts paths and trailing-slash directory
    prefixes. Bazel needs an explicit label per file, so each directory is
    walked at repo-rule time and emits one entry per discovered file.
    """
    return {":" + entry.path: entry.path for entry in expanded}

def _sorted_flavor_set(flavors):
    """The deduplicated, sorted flavor names, for order-insensitive comparison."""
    seen = {}
    for flavor in flavors:
        seen[flavor] = True
    return sorted(seen.keys())

def merge_pub_asset_conditions(expanded, package_name):
    """Merge per-file `flutter.assets` entries the way flutter_tools does.

    flutter_tools keeps one entry per declaration and bundles a file when ANY
    of its entries survives filtering, so every entry for one file merges:
    any entry without `platforms` makes the file unconditional, otherwise the
    file's platforms are the union of its entries' lists. Entries for one
    file whose flavor sets differ conflict (compared as sets, so order does
    not matter); the caller fails the fetch with the returned message.

    Args:
        expanded: Per-file entries from `expand_pub_asset_entries`.
        package_name: The pub package the entries come from, for the conflict
            message.

    Returns:
        A `struct(platforms, flavors, conflict)`: the merged condition dicts
        (same shapes `_build_pkg_asset_conditions` returns) and the fetch
        failure naming the package, the file and both flavor lists, or `""`
        when the entries agree. A file with one entry keeps its declared
        order, so single-entry spokes render byte-identically to before.
    """
    by_path = {}
    order = []
    for entry in expanded:
        key = ":" + entry.path
        if key not in by_path:
            by_path[key] = []
            order.append(key)
        by_path[key].append(entry)
    platforms = {}
    flavors = {}
    for key in order:
        entries = by_path[key]
        first = entries[0]
        for other in entries[1:]:
            if _sorted_flavor_set(other.flavors) != _sorted_flavor_set(first.flavors):
                return struct(
                    platforms = {},
                    flavors = {},
                    conflict = asset_flavor_error(
                        package_name,
                        first.path,
                        first.flavors,
                        other.flavors,
                    ),
                )
        if first.flavors:
            flavors[key] = list(first.flavors)
        union = {}
        unconditional = False
        for entry in entries:
            if not entry.platforms:
                unconditional = True
                break
            for platform in entry.platforms:
                union[platform] = True
        if unconditional:
            continue
        if len(entries) == 1:
            platforms[key] = list(first.platforms)
        else:
            platforms[key] = sorted(union.keys())
    return struct(platforms = platforms, flavors = flavors, conflict = "")

def _build_pkg_asset_conditions(expanded, package_name):
    """Build the `pkg_asset_platforms` / `pkg_asset_flavors` dicts.

    Same keys as `pkg_assets` (`":" + path`), but only for entries that
    actually restrict: unconditional files stay out of both dicts, so the
    emitted attrs stay empty for packages without conditions. Entries for
    one file merge (see `merge_pub_asset_conditions`); conflicting flavors
    fail the spoke fetch.

    Args:
        expanded: Per-file entries from `expand_pub_asset_entries`.
        package_name: The pub package the entries come from.

    Returns:
        A `(platforms, flavors)` tuple of dicts.
    """
    merged = merge_pub_asset_conditions(expanded, package_name)
    if merged.conflict:
        fail(merged.conflict)
    return (merged.platforms, merged.flavors)

def _build_pkg_shaders_dict(parsed_shaders):
    """Build the `pkg_shaders` dict — same shape as pkg_assets, no directories."""
    out = {}
    for entry in parsed_shaders:
        out[":" + entry.path] = entry.path
    return out

def _format_label_dict_literal(d, indent = "        "):
    """Render `{":foo": "foo", ":bar": "bar"}` as a multi-line BUILD source dict."""
    if not d:
        return "{}"
    keys = sorted(d.keys())

    # Keys and values are asset, font and shader paths from the pubspec and
    # the file-system walk: attacker-controlled for hosted packages. Each
    # renders through the escaping helper, so the dict parses back exactly.
    lines = ["{indent}{k}: {v},".format(indent = indent, k = starlark_string_literal(k), v = starlark_string_literal(d[k])) for k in keys]
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

def _format_string_list_dict_literal(d, indent = "        "):
    """Render `{":foo": ["a", "b"]}` as a multi-line BUILD source dict."""
    if not d:
        return "{}"
    lines = []
    for k in sorted(d.keys()):
        # Keys are walked asset paths (see above); values are flavor and
        # platform names from the pubspec, helper-rendered for the same
        # reason: a flavor name may hold any string the pubspec declares.
        values = ", ".join([starlark_string_literal(v) for v in d[k]])
        lines.append("{indent}{k}: [{values}],".format(indent = indent, k = starlark_string_literal(k), values = values))
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

def scoped_shader_includes_block(shader_paths):
    """Render `shader_includes` covering only the declared shaders' own directories.

    Each non-empty dirname contributes `<dir>/**/*.glsl|frag|vert`; a
    top-level shader contributes root `*.ext`. Sorted for determinism, so
    `example/build/` output can never become an include through a
    package-wide `**` glob.

    Args:
        shader_paths: Declared shader paths (the `pkg_shaders` values).

    Returns:
        The `shader_includes = glob(...)` BUILD block.
    """
    dirs = {}
    for path in shader_paths:
        dirs[path.rpartition("/")[0]] = True
    lines = []
    for d in sorted(dirs.keys()):
        for ext in _PATH_SPOKE_SHADER_INCLUDE_EXTS:
            pattern = d + "/**/*." + ext if d else "*." + ext

            # `d` is a declared shader's own directory, read from the
            # pubspec; the pattern renders through the escaping helper.
            lines.append("        " + starlark_string_literal(pattern) + ",")
    return "    shader_includes = glob(\n        [\n{}\n        ],\n        allow_empty = True,\n    ),".format("\n".join(lines))

def _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders, pkg_asset_platforms = {}, pkg_asset_flavors = {}):
    """Render the pub-asset attrs as BUILD source, omitting empty ones."""
    parts = []
    if fonts_json_str:
        parts.append("    fonts_json = " + starlark_string_literal(fonts_json_str) + ",")
    if font_files:
        parts.append("    font_files = {},".format(_format_label_dict_literal(font_files)))
    if pkg_assets:
        parts.append("    pkg_assets = {},".format(_format_label_dict_literal(pkg_assets)))
    if pkg_asset_platforms:
        parts.append("    pkg_asset_platforms = {},".format(_format_string_list_dict_literal(pkg_asset_platforms)))
    if pkg_asset_flavors:
        parts.append("    pkg_asset_flavors = {},".format(_format_string_list_dict_literal(pkg_asset_flavors)))
    if pkg_shaders:
        parts.append("    pkg_shaders = {},".format(_format_label_dict_literal(pkg_shaders)))

        # What the shaders may `#include`: GLSL beside a declared shader, so
        # only the declared shaders' own directories resolve — never the
        # whole package, where `example/build/` output would become includes.
        parts.append(scoped_shader_includes_block(sorted(pkg_shaders.values())))
    return ("\n".join(parts) + "\n") if parts else ""

def _format_code_asset_attrs(code_assets, has_unreplaced_hook):
    """Render the `code_assets` / `has_unreplaced_hook` attrs for a spoke.

    Shared by the `flutter_library` and `flutter_plugin` generators so the two
    emit an identical shape; the `dart_library` branch gets the equivalent from
    rules_dart's own `make_dart_library_build_content`.
    """
    block = ""
    if code_assets:
        # Labels arrive from the curated registry; the hook path is one of
        # two fixed entrypoints. Both still render through the helper.
        lines = ["        " + starlark_string_literal(a) + "," for a in code_assets]
        block += "    code_assets = [\n{}\n    ],\n".format("\n".join(lines))
    if has_unreplaced_hook:
        block += "    has_unreplaced_hook = " + starlark_string_literal(has_unreplaced_hook) + ",\n"
    return block

# The non-Dart remainder of `lib/`, emitted verbatim by both spoke
# generators below — the same partition rules_dart's
# `make_dart_library_build_content` uses, so `srcs + resources = lib/**`
# holds for every spoke whichever generator ran. A published package's
# `lib/` is addressable as `package:<name>/<path>` whatever the extension;
# a spoke that keeps only `*.dart` is a package with pieces missing.
# `resources` is orthogonal to the declared-asset attrs (`pkg_assets` /
# `pkg_shaders` / `font_files`): those name what is transformed and bundled
# into flutter_assets, while `resources` names membership in the staged
# package tree. A shader under `lib/` is legitimately both.
_RESOURCES_GLOB_BLOCK = """    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
"""

def _format_version_attr(version):
    """The `version` attr line for a spoke, or nothing when it is unknown.

    Omitted rather than written empty, matching
    `make_dart_library_build_content`. The attribute's only use is agreement
    checking between two records for one package name, and an unstated version
    never conflicts — so a spoke with nothing to say says nothing.

    Args:
        version: The resolved package version, or "".

    Returns:
        A BUILD attribute line, or "".
    """

    # The lock's version string renders through the helper like the rest.
    return "    version = " + starlark_string_literal(version) + ",\n" if version else ""

def make_flutter_library_build_content(
        name,
        deps,
        language_version,
        code_assets,
        has_unreplaced_hook,
        fonts_json_str,
        font_files,
        pkg_assets,
        pkg_shaders,
        pkg_asset_platforms = {},
        pkg_asset_flavors = {},
        version = ""):
    """Generate BUILD content for a non-plugin Flutter spoke shipping fonts/assets/shaders.

    Counterpart to `make_dart_library_build_content` — used when the spoke
    declares anything under `flutter:` other than `plugin:` (e.g.
    cupertino_icons declaring `flutter.fonts`). The same shape a user
    would write by hand: `flutter_library` with the new pub-asset attrs,
    plus the non-Dart `lib/` remainder as `resources`.

    Args:
        name: Target name (also the `package_name`).
        deps: Fully-qualified Bazel label strings for sibling spokes.
        language_version: Dart language version string (e.g. `"3.4"`).
        code_assets: `dart_code_asset` label strings replacing this
            package's build hook output.
        has_unreplaced_hook: Path of a build hook nothing replaces, or "".
        fonts_json_str: JSON-encoded `flutter.fonts` declarations, or "".
        font_files: Dict of font file label -> package-relative path.
        pkg_assets: Dict of asset file label -> package-relative path.
        pkg_shaders: Dict of shader file label -> package-relative path.
        pkg_asset_platforms: Dict of asset label -> platform list, only for
            restricted entries. Empty (the common case) emits no attr, so
            unconditional spokes are byte-identical to before.
        pkg_asset_flavors: Dict of asset label -> flavor list, same shape.
        version: The resolved package version this spoke was fetched at, or
            empty. Emitted only when known, matching
            `make_dart_library_build_content`: its sole use is agreement
            checking when one package name arrives from two hubs, and an
            unstated version never conflicts with a stated one.

    Returns:
        BUILD.bazel content as a string.

    Escaping: `name` is a lock package name (refused quotable at hub
    classification) and `language_version` is a derived `X.Y`; every walked
    or declared path below renders through the escaping helper.
    """
    deps_block = _spoke_deps_block(deps)

    pub_attrs = _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders, pkg_asset_platforms, pkg_asset_flavors)

    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_library")

flutter_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{resources}{deps}    package_name = "{name}",
    language_version = "{language_version}",
{version}{asset_attrs}{pub_attrs}    visibility = ["//visibility:public"],
)
""".format(
        name = name,
        resources = _RESOURCES_GLOB_BLOCK,
        deps = deps_block,
        language_version = language_version,
        version = _format_version_attr(version),
        asset_attrs = _format_code_asset_attrs(code_assets, has_unreplaced_hook),
        pub_attrs = pub_attrs,
    )

def _spoke_deps_block(deps):
    """The `deps` attribute block for a spoke, or nothing when it has none."""
    if not deps:
        return ""

    # Labels are built from the hub name and lock package names, which hub
    # classification already refused when quotable; each still renders
    # through the escaping helper, so a hostile label lands inert.
    dep_lines = ["        " + starlark_string_literal(dep) + "," for dep in deps]
    return "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

def _apple_plugin_targets(name, srcs_dirs, include_dirs, platform):
    """The `flutter_apple_plugin_library` pair (device + xtool) for one platform."""

    # `name` is a lock package name (refused quotable at classification) and
    # `platform` is a fixed literal at every call site; `srcs` globs and the
    # `includes` list render through the escaping helper.
    return """
flutter_apple_plugin_library(
    name = "{name}_apple_{platform}",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "{platform}",
    visibility = ["//visibility:public"],
)

flutter_apple_plugin_library(
    name = "{name}_apple_{platform}_xtool",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "{platform}",
    backend = "xtool",
    visibility = ["//visibility:public"],
)""".format(
        name = name,
        platform = platform,
        srcs = _glob_block(srcs_dirs, _APPLE_SRC_EXTENSIONS),
        includes = starlark_string_literal(include_dirs),
    )

def _desktop_plugin_target(name, src_dir, platform):
    """The `flutter_<platform>_plugin_library` target for one desktop platform."""

    # Same shape as above: `name` is a classified lock package name and
    # `platform` is `"linux"` or `"windows"` at every call site.
    srcs, hdrs = _split_glob_block([src_dir], _DESKTOP_C_EXTS, _DESKTOP_HDR_EXTS)
    return """
flutter_{platform}_plugin_library(
    name = "{name}_{platform}",
    srcs = {srcs},
    hdrs = {hdrs},
    includes = ["{platform}/include"],
    visibility = ["//visibility:public"],
)""".format(
        name = name,
        platform = platform,
        srcs = srcs,
        hdrs = hdrs,
    )

def _plugin_apple_libs_arg(name, apple_macos_srcs_dirs, apple_ios_srcs_dirs):
    """The `apple_libs` select routing each OS to its device/xtool library."""
    if not (apple_macos_srcs_dirs or apple_ios_srcs_dirs):
        return ""

    # Branch labels compose the classified package name with fixed
    # suffixes; nothing walked or declared reaches them unquoted.
    macos_branch = '            ":{name}_apple_macos",'.format(name = name) if apple_macos_srcs_dirs else ""
    macos_xtool_branch = '            ":{name}_apple_macos_xtool",'.format(name = name) if apple_macos_srcs_dirs else ""
    ios_branch = '            ":{name}_apple_ios",'.format(name = name) if apple_ios_srcs_dirs else ""
    ios_xtool_branch = '            ":{name}_apple_ios_xtool",'.format(name = name) if apple_ios_srcs_dirs else ""
    return """    apple_libs = select({{
        "@rules_flutter//flutter/settings:macos_xtool_backend": [
{macos_xtool_branch}
        ],
        "@platforms//os:macos": [
{macos_branch}
        ],
        "@rules_flutter//flutter/settings:ios_xtool_backend": [
{ios_xtool_branch}
        ],
        "@platforms//os:ios": [
{ios_branch}
        ],
        "//conditions:default": [],
    }}),
""".format(
        macos_branch = macos_branch,
        macos_xtool_branch = macos_xtool_branch,
        ios_branch = ios_branch,
        ios_xtool_branch = ios_xtool_branch,
    )

def _plugin_privacy_files_arg(apple_macos_privacy_manifests, apple_ios_privacy_manifests):
    """The `apple_privacy_files` select splitting manifests per platform.

    Split per-platform via select() so the macOS bundle never picks up
    iOS-only manifests (and vice versa) — different platforms can declare
    different privacy uses, and Apple's submission validator aggregates
    whatever it finds in the per-platform bundle.
    """
    if not (apple_macos_privacy_manifests or apple_ios_privacy_manifests):
        return ""

    # Manifest paths are walked from detected source directories plus a
    # fixed file name; each renders through the escaping helper.
    macos_lines = "\n".join(["            " + starlark_string_literal(p) + "," for p in apple_macos_privacy_manifests])
    ios_lines = "\n".join(["            " + starlark_string_literal(p) + "," for p in apple_ios_privacy_manifests])
    return """    apple_privacy_files = select({{
        "@platforms//os:macos": [
{macos_lines}
        ],
        "@platforms//os:ios": [
{ios_lines}
        ],
        "//conditions:default": [],
    }}),
""".format(
        macos_lines = macos_lines,
        ios_lines = ios_lines,
    )

def _plugin_extra_loads(apple_macos_srcs_dirs, apple_ios_srcs_dirs, linux_src_dir, windows_src_dir):
    """The extra `load` lines a plugin spoke needs, joined for the template."""
    extra_loads = []
    if apple_macos_srcs_dirs or apple_ios_srcs_dirs:
        extra_loads.append('load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")')
    if linux_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:linux.bzl", "flutter_linux_plugin_library")')
    if windows_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:windows.bzl", "flutter_windows_plugin_library")')
    return "\n".join(extra_loads)

def _plugin_extra_targets(name, apple_macos_srcs_dirs, apple_ios_srcs_dirs, apple_macos_include_dirs, apple_ios_include_dirs, linux_src_dir, windows_src_dir):
    """The per-platform plugin library targets, joined for the template.

    NOTE: Android Kotlin/Java sources are NOT compiled in the top-level
    spoke BUILD. Instead, they're exposed via a sibling `android/`
    sub-package (see make_android_subpackage_build_content) which loads
    @rules_android + @rules_kotlin lazily — only when something queries
    `@<spoke>//android:lib`. Mac-only / web-only workspaces never trigger
    the parse and don't pay the @rules_android / @rules_kotlin cost.
    The application-side `flutter_android_app` macro depends on the hub's
    `android/all_android_plugin_libs` aggregator, which deps on every
    spoke's `android:lib` — so Android-targeted builds pick up all
    plugin libraries automatically.
    """
    extra_targets = []
    if apple_macos_srcs_dirs:
        extra_targets.append(_apple_plugin_targets(
            name,
            apple_macos_srcs_dirs,
            apple_macos_include_dirs,
            "macos",
        ))
    if apple_ios_srcs_dirs:
        extra_targets.append(_apple_plugin_targets(
            name,
            apple_ios_srcs_dirs,
            apple_ios_include_dirs,
            "ios",
        ))
    if linux_src_dir:
        extra_targets.append(_desktop_plugin_target(name, linux_src_dir, "linux"))
    if windows_src_dir:
        extra_targets.append(_desktop_plugin_target(name, windows_src_dir, "windows"))
    return "\n".join(extra_targets)

def make_flutter_plugin_build_content(
        name,
        deps,
        language_version,
        code_assets,
        has_unreplaced_hook,
        plugin_platforms_json,
        apple_macos_srcs_dirs,
        apple_ios_srcs_dirs,
        apple_macos_include_dirs,
        apple_ios_include_dirs,
        apple_macos_privacy_manifests,
        apple_ios_privacy_manifests,
        linux_src_dir,
        windows_src_dir,
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {},
        pkg_shaders = {},
        pkg_asset_platforms = {},
        pkg_asset_flavors = {},
        version = ""):
    """Generate BUILD content for a Flutter plugin spoke.

    Emits a `flutter_plugin` plus optional per-platform
    `flutter_apple_plugin_library` (Apple) /
    `flutter_linux_plugin_library` /
    `flutter_windows_plugin_library` sub-targets.

    Android Kotlin/Java sources are exposed via a sibling `android/`
    sub-package (see `make_android_subpackage_build_content`). The
    sub-package is loaded only when something queries
    `@<spoke>//android:lib` — non-Android workspaces don't pay the
    `@rules_android` / `@rules_kotlin` cost.

    Args:
        name: Target name (also the `package_name`).
        deps: Fully-qualified Bazel label strings for sibling spokes.
        language_version: Dart language version string (e.g. `"3.4"`).
        code_assets: `dart_code_asset` label strings replacing this
            package's build hook output.
        has_unreplaced_hook: Path of a build hook nothing replaces, or "".
        plugin_platforms_json: JSON-encoded `flutter.plugin.platforms` dict.
        apple_macos_srcs_dirs: Detected macOS Apple source dirs.
        apple_ios_srcs_dirs: Detected iOS Apple source dirs.
        apple_macos_include_dirs: SwiftPM-style public-header dirs (macOS).
        apple_ios_include_dirs: SwiftPM-style public-header dirs (iOS).
        apple_macos_privacy_manifests: `PrivacyInfo.xcprivacy` paths (macOS).
        apple_ios_privacy_manifests: `PrivacyInfo.xcprivacy` paths (iOS).
        linux_src_dir: Linux C/C++ source dir, or "".
        windows_src_dir: Windows C/C++ source dir, or "".
        fonts_json_str: JSON-encoded `flutter.fonts` declarations, or "".
        font_files: Dict of font file label -> package-relative path.
        pkg_assets: Dict of asset file label -> package-relative path.
        pkg_shaders: Dict of shader file label -> package-relative path.
        pkg_asset_platforms: Dict of asset label -> platform list, only for
            restricted entries. Empty (the common case) emits no attr, so
            unconditional spokes are byte-identical to before.
        pkg_asset_flavors: Dict of asset label -> flavor list, same shape.
        version: The resolved package version this spoke was fetched at, or
            empty. Emitted only when known, matching
            `make_dart_library_build_content`: its sole use is agreement
            checking when one package name arrives from two hubs, and an
            unstated version never conflicts with a stated one.

    Returns:
        BUILD.bazel content as a string.

    Escaping: `name` is a lock package name (refused quotable at hub
    classification) and `language_version` is a derived `X.Y`; the plugin
    JSON and every walked or declared path render through the helper.
    """
    deps_block = _spoke_deps_block(deps)

    extra_loads = _plugin_extra_loads(
        apple_macos_srcs_dirs,
        apple_ios_srcs_dirs,
        linux_src_dir,
        windows_src_dir,
    )
    extra_targets = _plugin_extra_targets(
        name,
        apple_macos_srcs_dirs,
        apple_ios_srcs_dirs,
        apple_macos_include_dirs,
        apple_ios_include_dirs,
        linux_src_dir,
        windows_src_dir,
    )

    # NB: Android sources are no longer surfaced via a top-level filegroup.
    # See `make_android_subpackage_build_content` — the spoke's `android/`
    # sub-package wraps them in a kt_android_library that the hub's
    # aggregator (`@<hub>//android:all_android_plugin_libs`) depends on.

    apple_libs_arg = _plugin_apple_libs_arg(name, apple_macos_srcs_dirs, apple_ios_srcs_dirs)

    # Branch labels compose the classified package name with fixed
    # suffixes; nothing walked or declared reaches them unquoted.
    linux_libs_arg = ""
    if linux_src_dir:
        linux_libs_arg = '    linux_libs = [":{name}_linux"],\n'.format(name = name)

    windows_libs_arg = ""
    if windows_src_dir:
        windows_libs_arg = '    windows_libs = [":{name}_windows"],\n'.format(name = name)

    # Android sources travel through a sibling `android/` sub-package, which
    # the hub's `all_android_plugin_libs` deps on and the application macro
    # adds to `binary_deps`. See `make_android_subpackage_build_content`.
    # Nothing rides a provider: the wiring happens at macro-load time, where
    # providers cannot be read.

    # Apple PrivacyInfo.xcprivacy files: thread through `apple_privacy_files`
    # on the flutter_plugin so they propagate via FlutterInfo to the platform
    # application rule, which bundles them via Resources/.
    apple_privacy_files_arg = _plugin_privacy_files_arg(
        apple_macos_privacy_manifests,
        apple_ios_privacy_manifests,
    )

    pub_attrs = _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders, pkg_asset_platforms, pkg_asset_flavors)

    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")
{extra_loads}
flutter_plugin(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{resources}{deps}    package_name = "{name}",
    plugin_platforms_json = {plugin_platforms_json_literal},
    language_version = "{language_version}",
{version}{apple_libs_arg}{linux_libs_arg}{windows_libs_arg}{apple_privacy_files_arg}{asset_attrs}{pub_attrs}    visibility = ["//visibility:public"],
)
{extra_targets}
""".format(
        name = name,
        version = _format_version_attr(version),
        asset_attrs = _format_code_asset_attrs(code_assets, has_unreplaced_hook),
        resources = _RESOURCES_GLOB_BLOCK,
        deps = deps_block,
        language_version = language_version,
        plugin_platforms_json_literal = starlark_string_literal(plugin_platforms_json),
        extra_loads = extra_loads,
        extra_targets = extra_targets,
        apple_libs_arg = apple_libs_arg,
        linux_libs_arg = linux_libs_arg,
        windows_libs_arg = windows_libs_arg,
        apple_privacy_files_arg = apple_privacy_files_arg,
        pub_attrs = pub_attrs,
    )

def _android_manifest_build_args(android_manifest, java_package, has_resources):
    """Return the `(manifest_arg, synthesized_manifest)` BUILD fragments.

    `manifest = "..."` lets `android_binary`'s `ManifestMerger2` pick up
    the plugin's entries transitively; `exports_manifest = 1` opts into
    the merger (rules_android defaults to no, AGP to yes). rules_android
    requires *some* manifest whenever `resource_files` is set, so a
    res-bearing plugin with no manifest gets a synthesized namespaced
    empty one, the way AGP treats a missing library manifest.
    """
    if android_manifest:
        sub_manifest = android_manifest
        if sub_manifest.startswith("android/"):
            sub_manifest = sub_manifest[len("android/"):]

        # The manifest path is a fixed plugin layout location; it renders
        # through the escaping helper like every other emitted string.
        return ("    manifest = %s,\n    exports_manifest = 1,\n" % starlark_string_literal(sub_manifest), "")
    if not has_resources:
        return ("", "")
    manifest_lines = [
        "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"",
        "    package=\"" + java_package + "\">",
        "</manifest>",
        "",
    ]
    manifest_content = "\n".join(["        %s," % starlark_string_literal(line) for line in manifest_lines])
    synthesized = """
# Minimal manifest for resource processing. AGP treats a missing library
# manifest as an empty one; rules_android requires an explicit file when
# resource_files is set.
write_file(
    name = "_manifest",
    out = "_manifest/AndroidManifest.xml",
    content = [
{content}
    ],
    newline = "unix",
)
""".format(content = manifest_content)
    return ('    manifest = ":_manifest",\n', synthesized)

def _android_build_config_block(bc_package):
    """Return the `(out, content)` fragments of the BuildConfig stub.

    Gradle synthesizes BuildConfig per Android module (matching
    `android.namespace`); rules_android does not, so the spoke hand-emits
    a minimal one. `DEBUG = false` is the safe default — the engine ABI /
    mode is decided elsewhere.
    """
    bc_lines = [
        "package " + bc_package + ";",
        "public final class BuildConfig {",
        "  public static final boolean DEBUG = false;",
        "  public static final String LIBRARY_PACKAGE_NAME = \"" + bc_package + "\";",
        "  public static final String BUILD_TYPE = \"release\";",
        "}",
        "",
    ]

    # `bc_package` is a validated Java package name (dots only); every line
    # still renders through the escaping helper.
    return (
        starlark_string_literal("_build_config/" + bc_package.replace(".", "/") + "/BuildConfig.java"),
        "\n".join(["        %s," % starlark_string_literal(line) for line in bc_lines]),
    )

def _fail_on_invalid_android_namespace(package_name, java_package):
    """Fail the spoke fetch when the resolved namespace is not a package."""
    if java_package and not _gradle_is_java_package_name(java_package):
        fail((
            "flutter.pub spoke for \"{pkg}\": the Android namespace " +
            "{ns} is not a valid Java package name (checked " +
            "android.namespace in build.gradle(.kts), the " +
            "AndroidManifest.xml package attribute, and " +
            "flutter.plugin.platforms.android.package in " +
            "pubspec.yaml). Refusing it rather than emitting it " +
            "into the generated android/BUILD.bazel."
        ).format(
            pkg = package_name,
            ns = repr(java_package),
        ))

def _android_srcs_attr(android_src_dir):
    """The `srcs` attribute value for the spoke's `kt_android_library`.

    The source dir is relative to the package root; the sub-package itself
    lives at `android/`, so that prefix is stripped there.
    """
    if not android_src_dir:
        return "[]"
    if android_src_dir.startswith("android/"):
        sub_src = android_src_dir[len("android/"):]
    else:
        sub_src = android_src_dir
    return "glob([{kt}, {java}], allow_empty = True)".format(
        kt = starlark_string_literal(sub_src + "/**/*.kt"),
        java = starlark_string_literal(sub_src + "/**/*.java"),
    )

def _android_library_args(java_package, android_manifest, has_resources, consumer_proguard_specs):
    """The manifest, resources and ProGuard fragments of the spoke library.

    Returns `struct(custom_package, manifest, synthesized_manifest,
    resource_files, proguard_specs)`. `manifest = "..."` lets
    `android_binary`'s `ManifestMerger2` pick up the plugin's `<activity>` /
    `<service>` / `<uses-permission>` / etc. entries transitively — same
    shape AGP uses inside `flutter build apk`. Paths are relative to the
    `android/` sub-package, so the prefix is stripped there. Resources are
    compiled into the library so the plugin's `R` class resolves at compile
    time and the resources merge into the consuming APK. `proguard_specs`
    lets `android_binary`'s R8 step pick up the plugin's keep rules
    transitively — same shape AGP uses for `consumerProguardFiles`.
    """
    custom_package_arg = ""
    if java_package:
        # Validated as a Java package name before the spoke renders, so
        # quotefree; still helper-rendered like every emitted string.
        custom_package_arg = "    custom_package = %s,\n" % starlark_string_literal(java_package)

    (manifest_arg, synthesized_manifest) = _android_manifest_build_args(
        android_manifest,
        java_package,
        has_resources,
    )

    # `allow_empty = False` — resource detection already saw files here, so
    # an empty glob means the layout assumption broke.
    resource_files_arg = ""
    if has_resources:
        resource_files_arg = '    resource_files = glob(["src/main/res/**"], allow_empty = False),\n'

    proguard_specs_arg = ""
    if consumer_proguard_specs:
        # Keep-rule paths are single-quoted Gradle literals resolved by the
        # lexed model; each renders through the escaping helper.
        spec_lines = ", ".join([starlark_string_literal(path) for path in consumer_proguard_specs])
        proguard_specs_arg = "    proguard_specs = [%s],\n" % spec_lines

    return struct(
        custom_package = custom_package_arg,
        manifest = manifest_arg,
        synthesized_manifest = synthesized_manifest,
        resource_files = resource_files_arg,
        proguard_specs = proguard_specs_arg,
    )

def _android_plugin_deps_block(extra_maven_labels):
    """The `deps` block body: the engine and BuildConfig plus maven labels.

    Base deps every plugin spoke gets: the engine (which carries the
    FlutterPlugin SPI plus the embedding's androidx compile classpath via
    its exports) and the BuildConfig stub. Plugin-specific maven deps from
    `extra_maven_labels` are appended, de-duped.
    """
    base_labels = [
        ":_engine",
        ":_build_config",
    ]
    seen = {label: True for label in base_labels}
    all_labels = list(base_labels)
    for lbl in extra_maven_labels:
        if lbl not in seen:
            seen[lbl] = True
            all_labels.append(lbl)

    # Base labels are fixed; maven labels arrive validated quotefree from
    # the extension. Each still renders through the escaping helper, so a
    # hostile value lands inert instead of breaking out of the list.
    return "\n        ".join([starlark_string_literal(label) + "," for label in all_labels])

def _android_engine_prelude(bc_out, bc_content):
    """The engine + BuildConfig half of the Android sub-package content."""
    return """\
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_flutter//flutter:android.bzl", "flutter_android_engine")
load("@rules_java//java:java_library.bzl", "java_library")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

# Private engine target — gives the plugin's Kotlin/Java the FlutterPlugin
# SPI plus the embedding's androidx dependencies (via the engine's
# exports) on the compile classpath. Always arm64; Java bytecode is
# ABI-independent. neverlink, so the APK carries only the app's engine, of
# the ABI flutter_android_app(android_abi=...) names.
flutter_android_engine(
    name = "_engine",
    neverlink = True,
    visibility = ["//visibility:private"],
)

# BuildConfig.java stub. Gradle synthesizes this per Android module
# (matching `android.namespace`). rules_android doesn't, so we generate
# a minimal one — `DEBUG = false`, which is correct for release builds
# and harmless for debug (the engine ABI / mode is decided elsewhere).
write_file(
    name = "_build_config_src",
    out = {bc_out},
    content = [
{bc_content}
    ],
    newline = "unix",
)

java_library(
    name = "_build_config",
    srcs = [":_build_config_src"],
    visibility = ["//visibility:private"],
)
""".format(bc_out = bc_out, bc_content = bc_content)

def _android_lib_target(srcs_attr, lib_args, deps_block):
    """The `kt_android_library(name = "lib")` half, manifest included."""
    return """\
{synthesized_manifest}
kt_android_library(
    name = "lib",
    srcs = {srcs},
{custom_package}{manifest}{resource_files}{proguard_specs}    visibility = ["//visibility:public"],
    deps = [
        {deps}
    ],
)
""".format(
        srcs = srcs_attr,
        custom_package = lib_args.custom_package,
        manifest = lib_args.manifest,
        resource_files = lib_args.resource_files,
        proguard_specs = lib_args.proguard_specs,
        deps = deps_block,
        synthesized_manifest = lib_args.synthesized_manifest,
    )

def make_android_subpackage_build_content(
        android_src_dir,
        java_package,
        extra_maven_labels,
        android_manifest = "",
        consumer_proguard_specs = [],
        has_resources = False):
    """Generate `android/BUILD.bazel` content for a Flutter plugin spoke.

    Always emits a `kt_android_library(name = "lib", ...)`. The aggregator
    in the hub's `android/all_android_plugin_libs` depends on `:lib` for
    every spoke; spokes without Android sources still contribute an empty
    library (a no-op at link time).

    Loaded lazily — Bazel only parses this file when something queries
    `@<spoke>//android:lib`. Non-Android workspaces never trigger it and
    don't pay the `@rules_android` / `@rules_kotlin` cost.

    The `_engine` target gives the plugin's Kotlin/Java source access to
    the FlutterPlugin SPI on the compile classpath. It is `neverlink`, as
    Gradle gives a plugin the embedding with `compileOnly`: the app
    packages its own engine, of the ABI its
    `flutter_android_app(android_abi = ...)` names. The plugin's is the
    arm64 one whatever the app's ABI, since Java bytecode is
    ABI-independent, and packaged it would put an arm64 engine in an x64
    APK. The engine also exports the embedding's
    androidx dependencies (see `_ANDROIDX_EMBEDDING_DEPS` in
    `flutter/android.bzl`), so a plugin whose `build.gradle` declares no
    dependencies still compiles against `NotificationCompat` & co. —
    exactly the compile classpath Gradle gives it via the
    `io.flutter:flutter_embedding_*` POM.

    BuildConfig.java is generated from the plugin's `java_package`. Many
    Flutter plugins reference `BuildConfig.DEBUG`, which Gradle synthesizes
    automatically; rules_android does not. We emit a minimal stub so the
    plugin's source compiles. `DEBUG = false` is the safe default —
    Flutter's Bazel build is release-by-default; debug runtime semantics
    are governed by `flutter_android_engine`'s engine selection, not by
    `BuildConfig.DEBUG`.

    Args:
        android_src_dir: Source dir under the package root (e.g.
            `android/src/main`) when the spoke has Android sources, or
            empty when it doesn't.
        java_package: The plugin's Android namespace — resolved the way
            AGP resolves it (`android.namespace` in `build.gradle(.kts)`,
            else the manifest's `package` attribute), falling back to
            `flutter.plugin.platforms.android.package` from the spoke's
            pubspec.yaml. Used as `custom_package` on the
            `kt_android_library` so the generated `R` and `BuildConfig`
            classes land in the package the plugin's sources expect.
        extra_maven_labels: Additional `@rules_android_maven//:...`
            labels parsed from the plugin's `build.gradle*` and translated
            via `maven_labels_for_gradle` (the built-in table plus
            `flutter.pub(android_maven_deps)`).
        android_manifest: Path to the plugin's
            `android/src/main/AndroidManifest.xml` if it ships one, or
            empty. When set, the generated `kt_android_library` declares
            `manifest = ...` so `android_binary`'s manifest merger
            (`ManifestMerger2`) picks the plugin's `<activity>` /
            `<service>` / `<uses-permission>` / etc. entries up
            transitively — same shape AGP uses inside `flutter build apk`.
        consumer_proguard_specs: Paths (relative to the spoke's
            `android/` sub-package) to ProGuard / R8 keep-rule files
            the plugin declared via `consumerProguardFiles` in its
            `build.gradle`. Threaded through as `proguard_specs = [...]`
            on the generated `kt_android_library`; rules_android
            propagates them transitively to the consuming
            `android_binary`'s R8 invocation, mirroring AGP's
            `consumerProguardFiles` flow.
        has_resources: True when the plugin ships resources at
            `android/src/main/res/`. Compiled via `resource_files` so the
            plugin's `R` class is generated against `java_package` and
            the resources merge into the consuming APK.

    Returns:
        Generated BUILD content as a string.

    Every string below renders through the escaping helper, never
    `"..." % value`: the namespace, manifest paths and labels arrive from
    plugin files and user attributes, and a hostile value must at worst land
    inert inside a string literal, never break out of one. A non-empty
    `java_package` that is not a Java package name (see
    `is_java_package_name`) fails instead of rendering at all.
    """
    if java_package and not _gradle_is_java_package_name(java_package):
        fail(
            "make_android_subpackage_build_content: java_package " +
            repr(java_package) + " is not a valid Java package name.",
        )
    if not android_src_dir and not has_resources:
        # Empty kt_android_library is valid in rules_kotlin. The hub's
        # aggregator depends on this spoke's `:lib` unconditionally, so
        # this no-op contribution keeps the deps list mechanical.
        return """\
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

kt_android_library(
    name = "lib",
    srcs = [],
    visibility = ["//visibility:public"],
)
"""

    if has_resources and not java_package:
        fail(
            "Plugin ships Android resources (android/src/main/res/) but " +
            "declares no namespace — checked android.namespace in " +
            "build.gradle(.kts), the AndroidManifest.xml package " +
            "attribute, and flutter.plugin.platforms.android.package in " +
            "pubspec.yaml. Without a namespace the R class cannot be " +
            "generated, so the resources would not compile.",
        )

    srcs_attr = _android_srcs_attr(android_src_dir)

    lib_args = _android_library_args(
        java_package,
        android_manifest,
        has_resources,
        consumer_proguard_specs,
    )

    deps_block = _android_plugin_deps_block(extra_maven_labels)

    # BuildConfig.java stub — Gradle generates this implicitly per
    # plugin's namespace. rules_android does not, so we hand-emit one.
    bc_package = java_package if java_package else "_unknown"
    (bc_out, bc_content) = _android_build_config_block(bc_package)

    return _android_engine_prelude(bc_out, bc_content) + _android_lib_target(
        srcs_attr,
        lib_args,
        deps_block,
    )

# The hook entrypoints upstream Dart defines (`package:hooks` — `build` and
# `link`). A package shipping one produces native libraries by running Dart at
# build time, which Bazel cannot do hermetically; something must stand in for it.
_DART_BUILD_HOOKS = ["hook/build.dart", "hook/link.dart"]

def _detect_unreplaced_hook(ctx):
    """Return the path of a build hook nothing replaces, or "".

    Recording rather than failing here is deliberate, and matches rules_dart:
    the whole lock is materialised, including packages nothing depends on, so
    failing at repo generation would break builds over packages never reached.
    The application that actually depends on one fails instead.
    """
    if ctx.attr.code_assets or ctx.attr.ignore_hook:
        return ""
    for candidate in _DART_BUILD_HOOKS:
        if ctx.path(candidate).exists:
            return candidate
    return ""

_LANGUAGE_VERSION_PLACEHOLDER = "{LANGUAGE_VERSION}"
_DEPS_PLACEHOLDER = "{DEPS}"

# The prefix a spoke label takes in an overlay template before substitution.
# Finding one means the template names a sibling package by hand.
_HUB_DEP_PREFIX = "@{HUB_NAME}__"

def find_hardcoded_language_version(content):
    """Return the literal language version an overlay spells out, or `""`.

    A package's `environment.sdk` is the only place its language version is
    declared; the spoke derives from it and substitutes
    `{LANGUAGE_VERSION}`. A template that writes the version out instead is a
    second declaration of the same fact, and the one that wins — the overlay
    replaces generated content wholesale. The two then drift silently,
    because the overlay ladder is version-ranged: `ext/objective_c/9/` serves
    every 9.x, so a release that raises the SDK floor keeps the old literal.

    Args:
        content: Raw template text, before substitution.

    Returns:
        The offending literal (e.g. `"3.3"`), or `""` when the template
        either uses the placeholder or declares no language version.
    """
    marker = "language_version"
    idx = content.find(marker)
    for _ in range(len(content)):
        if idx == -1:
            return ""
        rest = content[idx + len(marker):].lstrip(" ")
        if rest.startswith("="):
            value = rest[1:].lstrip(" ")
            if value.startswith('"'):
                end = value.find('"', 1)
                if end > 0:
                    literal = value[1:end]
                    if literal != _LANGUAGE_VERSION_PLACEHOLDER:
                        return literal
        idx = content.find(marker, idx + len(marker))
    return ""

def find_hardcoded_hub_dep(content):
    """Return the first hand-written sibling-spoke label an overlay names, or `""`.

    A package's dependencies are declared once, by its own pubspec, and the
    spoke derives the Bazel labels from it — intersected with the lock, so a
    generated spoke can never name a repo the hub did not create. An overlay
    that spells the list out instead declares the same fact twice, and this
    copy wins, because an overlay replaces generated content wholesale.

    The two then drift on the package's next release, and the drift is not
    a stale-but-working list: `objective_c` 9.5.0 dropped `native_toolchain_c`
    from `dependencies` (its build hook stopped using it), so the lock stopped
    carrying that package, while `ext/objective_c/9/` — one directory for the
    whole major — kept asking for `@<hub>__native_toolchain_c`. The build died
    on an unknown repo naming neither `objective_c` nor the overlay.

    Args:
        content: Raw template text, before substitution.

    Returns:
        The offending label (e.g. `"@{HUB_NAME}__ffi//:ffi"`), or `""`.
    """
    idx = content.find(_HUB_DEP_PREFIX)
    if idx == -1:
        return ""
    end = content.find('"', idx)
    return content[idx:end] if end > 0 else content[idx:]

def render_overlay_deps(dep_labels):
    """Render `dep_labels` as the body of an overlay's `deps = [...]`.

    Emits one quoted, comma-terminated label per line at the eight-space
    indent a template's `deps = [` block sits at, so the substituted BUILD
    file comes out buildifier-clean.

    Args:
        dep_labels: Fully-qualified labels, in the order they should appear.

    Returns:
        The list body, without the enclosing brackets.
    """

    # Labels derive from the package's own pubspec intersected with the
    # lock (names refused quotable at classification); each still renders
    # through the escaping helper before substitution into the template.
    return "\n        ".join([starlark_string_literal(label) + "," for label in dep_labels])

_WRITE_FILE_LOAD = 'load("@bazel_skylib//rules:write_file.bzl", "write_file")\n'
_CAT_HEREDOC_PREFIX = "    cmd = \"cat > $@ <<'EOF'\\n"
_CAT_HEREDOC_SUFFIX = "\\nEOF\\n\",\n)"

def _decode_heredoc_field(source, package_name, template, genrule_name, field):
    """Decode one source-encoded heredoc field, failing the fetch closed.

    Args:
        source: The still-encoded field text cut out of the template.
        package_name: The pub package the overlay belongs to, for the failure.
        template: The overlay template path, for the failure.
        genrule_name: The raw `name` line, naming the genrule in the failure.
        field: Which field failed to decode (`name`, `outs`, or the body).

    Returns:
        The decoded text; fails the fetch naming the package, the template
        and the genrule when the field holds an undecodable escape.
    """
    decoded = decode_starlark_escapes(source)
    if decoded.error != "":
        fail((
            "flutter.pub overlay for \"{pkg}\" ({tpl}): genrule {name} holds " +
            "{error} in its {field}; refusing it rather than emitting " +
            "bytes the heredoc `cat` never wrote."
        ).format(
            pkg = package_name,
            tpl = template,
            name = repr(genrule_name),
            error = decoded.error,
            field = field,
        ))
    return decoded.text

def _rewrite_cat_genrules(content, package_name = "", template = ""):
    """Rewrite heredoc `cat` `genrule` targets in overlay templates to `write_file`.

    The cut-out heredoc body (and the parsed `name`/`outs` lines) is
    Starlark source text: its escapes are still encoded. Each decodes to
    the actual text before rendering, so the `write_file` output equals the
    bytes the original genrule's `cat` heredoc would have written. An
    undecodable escape fails the fetch, naming the package and the
    template. Every decoded line still renders through
    `starlark_string_literal`; the build-escape fix stays intact.

    Args:
        content: The substituted overlay template text.
        package_name: The pub package the overlay belongs to, for failures.
        template: The overlay template path, for failures.

    Returns:
        The template with each heredoc `cat` genrule replaced by an
        equivalent `write_file`, plus the `write_file` load when missing.
    """
    if _CAT_HEREDOC_PREFIX not in content:
        return content
    out_chunks = []
    rest = content
    for _ in range(16):
        idx = rest.find("genrule(\n")
        if idx < 0:
            break
        end_idx = rest.find(_CAT_HEREDOC_SUFFIX, idx)
        if end_idx < 0:
            break
        block = rest[idx:end_idx + len(_CAT_HEREDOC_SUFFIX)]
        cmd_idx = block.find(_CAT_HEREDOC_PREFIX)
        if cmd_idx < 0:
            out_chunks.append(rest[:idx + len("genrule(\n")])
            rest = rest[idx + len("genrule(\n"):]
            continue
        header = block[:cmd_idx]
        body = block[cmd_idx + len(_CAT_HEREDOC_PREFIX):len(block) - len(_CAT_HEREDOC_SUFFIX)]
        name_val = ""
        out_val = ""
        for hline in header.split("\n"):
            s = hline.strip()
            if s.startswith('name = "') and s.endswith('",'):
                name_val = s[len('name = "'):-2]
            elif s.startswith('outs = ["') and s.endswith('"],'):
                out_val = s[len('outs = ["'):-3]
        if not name_val or not out_val:
            out_chunks.append(rest[:idx + len("genrule(\n")])
            rest = rest[idx + len("genrule(\n"):]
            continue

        # The cut-out body (and the parsed `name`/`outs` lines) is Starlark
        # source text: its escapes are still encoded. Decode each to the
        # actual text first, or the escaping helper below escapes the
        # already-escaped text a second time.
        name = _decode_heredoc_field(name_val, package_name, template, name_val, "name")
        out = _decode_heredoc_field(out_val, package_name, template, name_val, "outs")
        body_text = _decode_heredoc_field(body, package_name, template, name_val, "heredoc body")
        body_lines = body_text.split("\n") + [""]

        # Decoded lines are plain values now; every line still renders
        # through the escaping helper on its way into `content`.
        content_entries = "\n".join(["        " + starlark_string_literal(line) + "," for line in body_lines])
        replacement = (
            "write_file(\n" +
            "    name = " + starlark_string_literal(name) + ",\n" +
            "    out = " + starlark_string_literal(out) + ",\n" +
            "    content = [\n" +
            content_entries + "\n" +
            "    ],\n" +
            '    newline = "unix",\n' +
            # Public so consumers can read the output through runfiles: the
            # e2e BuildConfig verifier holds a `data` dependency on it, and
            # `bazel build` of the label needs no visibility at all.
            '    visibility = ["//visibility:public"],\n' +
            ")"
        )
        out_chunks.append(rest[:idx])
        out_chunks.append(replacement)
        rest = rest[end_idx + len(_CAT_HEREDOC_SUFFIX):]
    out_chunks.append(rest)
    rewritten = "".join(out_chunks)
    if _WRITE_FILE_LOAD not in rewritten:
        load_idx = rewritten.find("load(")
        if load_idx >= 0:
            rewritten = rewritten[:load_idx] + _WRITE_FILE_LOAD + rewritten[load_idx:]
        else:
            rewritten = _WRITE_FILE_LOAD + rewritten
    return rewritten

def apply_overlay_substitutions(content, hub_name, package_name, version, language_version, deps, template = ""):
    """Fill an overlay template's placeholders.

    Args:
        content: Raw template text.
        hub_name: Value for `{HUB_NAME}`.
        package_name: Value for `{PKG}`.
        version: Value for `{VERSION}`.
        language_version: Value for `{LANGUAGE_VERSION}`, derived from the
            package's own pubspec.
        deps: Rendered list body for `{DEPS}` (see `render_overlay_deps`),
            derived from the same pubspec-and-lock intersection a generated
            spoke uses.
        template: The overlay template path, naming it in heredoc decode
            failures (see `_rewrite_cat_genrules`).

    Returns:
        The substituted content.
    """
    substituted = content.replace(
        "{HUB_NAME}",
        hub_name,
    ).replace(
        "{PKG}",
        package_name,
    ).replace(
        "{VERSION}",
        version,
    ).replace(
        _LANGUAGE_VERSION_PLACEHOLDER,
        language_version,
    ).replace(
        _DEPS_PLACEHOLDER,
        deps,
    )
    return _rewrite_cat_genrules(substituted, package_name, template)

def _resolve_overlay_template(ctx, overlay_root_label, package_name, version, language_version, dep_labels, relpath, guard_hub_deps = False):
    """Look up an overlay template at `<root>/<package>/<version-ladder>/<relpath>`.

    Walks the version-specificity ladder
    `<major>.<minor>.<patch>/`, `<major>.<minor>/`, `<major>/`, bare
    `<package>/`, and returns the templated content (with `{HUB_NAME}`,
    `{PKG}`, `{VERSION}`, `{LANGUAGE_VERSION}` and `{DEPS}` substitutions
    applied) on first match. Returns empty string when no template is found.

    `dep_labels` are the spoke labels the package's own pubspec resolves to,
    which `{DEPS}` expands into. `guard_hub_deps` rejects a template that
    hand-writes those labels instead — see `find_hardcoded_hub_dep`. Only the
    top-level BUILD sets it: `{DEPS}` is a Dart dependency list, so it is not
    the right substitute for a sibling label in an `android/` sub-package.

    Currently called for two relpaths:

    * `BUILD.bazel.tpl` — the spoke's top-level BUILD that fully
      replaces the auto-generated content.
    * `android/BUILD.bazel.tpl` — the Android sub-package BUILD,
      replacing the empty-stub `kt_android_library(srcs=[])` that
      otherwise fires when a top-level overlay short-circuits the
      regular auto-gen path. Plugins whose Android side needs real
      sources / extra maven labels (e.g. ones whose Java references
      transitive deps not in the curated `_MAVEN_COORD_TO_LABEL`)
      ship this alongside the top-level overlay.
    """
    anchor = ctx.path(overlay_root_label)
    ctx.watch(anchor)
    root = anchor.dirname
    ctx.watch(root)
    pkg_dir = root.get_child(package_name)
    ctx.watch(pkg_dir)

    # Build the version ladder.
    parts = version.split(".")
    candidates = []
    if len(parts) >= 3:
        candidates.append("{}.{}.{}".format(parts[0], parts[1], parts[2]))
    if len(parts) >= 2:
        candidates.append("{}.{}".format(parts[0], parts[1]))
    if len(parts) >= 1 and parts[0]:
        candidates.append(parts[0])
    candidates.append("")  # bare <pkg>/<relpath>

    relpath_parts = relpath.split("/")
    for candidate in candidates:
        cand_dir = pkg_dir.get_child(candidate) if candidate else pkg_dir
        if candidate:
            ctx.watch(cand_dir)
        tpl = cand_dir
        for part in relpath_parts:
            tpl = tpl.get_child(part)
            ctx.watch(tpl)
        if tpl.exists:
            content = ctx.read(tpl)
            hardcoded_dep = find_hardcoded_hub_dep(content) if guard_hub_deps else ""
            if hardcoded_dep:
                fail((
                    "overlay template {tpl} hand-writes the dependency " +
                    "`{dep}`.\n" +
                    "A package's dependencies are declared once, by its own " +
                    "pubspec; the spoke derives the labels from it — " +
                    "intersected with the lock, so it can never name a repo " +
                    "the hub did not create. Listing them here declares the " +
                    "same fact twice, and this copy wins, because an overlay " +
                    "replaces generated content wholesale. Because the " +
                    "overlay ladder is version-ranged, a release that changes " +
                    "the package's dependencies then fails on an unknown " +
                    "repo that names neither the package nor this file.\n" +
                    "Write `deps = [\n        {placeholder}\n    ],` instead."
                ).format(
                    tpl = str(tpl),
                    dep = hardcoded_dep,
                    placeholder = _DEPS_PLACEHOLDER,
                ))
            hardcoded = find_hardcoded_language_version(content)
            if hardcoded:
                fail((
                    "overlay template {tpl} sets language_version = \"{value}\".\n" +
                    "A package's language version is declared once, by its own " +
                    "pubspec `environment.sdk`; the spoke derives it and fills in " +
                    "{placeholder}. Spelling it out here declares the same fact " +
                    "twice, and this copy wins — an overlay replaces generated " +
                    "content wholesale. Because the overlay ladder is " +
                    "version-ranged, the two then drift without a build error.\n" +
                    "Write `language_version = \"{placeholder}\"` instead."
                ).format(
                    tpl = str(tpl),
                    value = hardcoded,
                    placeholder = _LANGUAGE_VERSION_PLACEHOLDER,
                ))
            return apply_overlay_substitutions(
                content = content,
                hub_name = ctx.attr.hub_name,
                package_name = package_name,
                version = version,
                language_version = language_version,
                deps = render_overlay_deps(dep_labels),
                template = str(tpl),
            )
    return ""

resolve_overlay_template = _resolve_overlay_template

def _resolve_overlay(ctx, overlay_root_label, package_name, version, language_version, dep_labels):
    """Resolve the top-level BUILD.bazel.tpl overlay.

    Equivalent to `_resolve_overlay_template(..., "BUILD.bazel.tpl")`.
    Kept as a separate helper because the top-level lookup is the most
    common call shape; consumers wanting the Android sub-package
    template call `_resolve_overlay_template` directly.
    """
    return _resolve_overlay_template(
        ctx,
        overlay_root_label,
        package_name,
        version,
        language_version,
        dep_labels,
        "BUILD.bazel.tpl",
        guard_hub_deps = True,
    )

resolve_overlay = _resolve_overlay

def resolve_overlay_roots(ctx, overlay_roots, package_name, version, language_version, dep_labels):
    """Resolve `(overlay_content, overlay_android_content)` across `overlay_roots`.

    Walks `overlay_roots` in order and stops on the first root that supplies a
    top-level `BUILD.bazel.tpl` for `package_name` at `version`, then looks up
    the matching `android/BUILD.bazel.tpl` from that same root.

    Args:
        ctx: The repository rule context (`repository_ctx`).
        overlay_roots: Anchor labels for candidate overlay trees, ordered by precedence.
        package_name: The pub package name to look up.
        version: The resolved package version string.
        language_version: The Dart language version derived from the package's pubspec.
        dep_labels: Sibling spoke label strings for `{DEPS}` substitution.

    Returns:
        A `(overlay_content, overlay_android_content)` tuple of substituted
        BUILD contents (each `""` when no matching template was found).
    """
    overlay_content = ""
    overlay_android_content = ""
    for overlay_label in overlay_roots:
        overlay_content = _resolve_overlay(
            ctx,
            overlay_label,
            package_name,
            version,
            language_version,
            dep_labels,
        )
        if overlay_content:
            # Look up the matching `android/BUILD.bazel.tpl` from the same
            # overlay root. Plugins whose Android side has real sources
            # ship one alongside the top-level BUILD; plugins that don't
            # leave it absent and the empty-stub fallback fires below.
            overlay_android_content = _resolve_overlay_template(
                ctx,
                overlay_label,
                package_name,
                version,
                language_version,
                dep_labels,
                "android/BUILD.bazel.tpl",
            )
            break
    return overlay_content, overlay_android_content

def _fetch_pub_archive(ctx):
    """Downloads and extracts the package archive, like `pub_lock_package`.

    Verifies sha256 on download, strips trailing NUL padding past the RFC
    1952 gzip trailer, and unpacks with `ctx.extract`.
    """
    url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
        base = ctx.attr.base_url,
        name = ctx.attr.package_name,
        version = ctx.attr.version,
    )
    pinned_download(
        ctx,
        url = url,
        output = "_archive.tar.gz",
        sha256 = require_sha256(ctx.attr.sha256, url),
    )
    raw_archive = ctx.read("_archive.tar.gz", watch = "no")
    trimmed_archive = trim_gzip_trailing_nulls(raw_archive)
    if trimmed_archive != raw_archive:
        ctx.delete("_archive.tar.gz")
        ctx.file("_archive.tar.gz", trimmed_archive, executable = False)
    ctx.extract("_archive.tar.gz")
    ctx.delete("_archive.tar.gz")

def _read_spoke_pubspec(ctx):
    """Parses the extracted `pubspec.yaml` into spoke inputs.

    Returns `struct(bazel_deps, language_version, plugin_block,
    asset_block)`: the lock-filtered dependency names, the derived language
    version, and the parsed `flutter.plugin` / `flutter` asset blocks
    (absent-pubspec defaults when no pubspec was extracted).
    """
    bazel_deps = []
    language_version = ""
    plugin_block = struct(
        present = False,
        platforms = {},
        implements = "",
        ffi_plugin = False,
    )
    asset_block = struct(
        fonts = [],
        assets = [],
        shaders = [],
        uses_material_design = False,
    )
    pubspec_path = ctx.path("pubspec.yaml")
    if pubspec_path.exists:
        pubspec_content = ctx.read(pubspec_path)
        all_deps = parse_pubspec_deps(pubspec_content)
        available = {p: True for p in ctx.attr.lock_packages}
        bazel_deps = sorted([d for d in all_deps if d in available])
        language_version = derive_language_version(
            parse_pubspec_sdk_constraint(pubspec_content),
        )
        plugin_block = parse_flutter_plugin_block(pubspec_content)
        asset_block = parse_flutter_assets_block(pubspec_content)
    return struct(
        bazel_deps = bazel_deps,
        language_version = language_version,
        plugin_block = plugin_block,
        asset_block = asset_block,
    )

def _spoke_dep_labels(ctx, bazel_deps, asset_block):
    """Sibling-spoke labels for the package's own pubspec dependencies.

    If the pubspec declares `uses-material-design: true`, the spoke depends
    on `@rules_flutter//flutter:material_icons` so the bundled font travels
    through the deps graph automatically — same channel any other pub
    package's font flows through. Cross-package mismatch (app says false,
    pub dep says true) becomes structurally impossible.
    """
    dep_labels = [
        "@{hub}__{dep}//:{dep}".format(hub = ctx.attr.hub_name, dep = dep)
        for dep in bazel_deps
    ]
    if asset_block.uses_material_design:
        dep_labels = dep_labels + ["@rules_flutter//flutter:material_icons"]
    return dep_labels

def _check_asset_platforms(package_name, parsed_assets):
    """Fail the spoke fetch on asset entries naming unknown platforms.

    An entry `platforms` value flutter_tools would reject (`flutter_manifest.dart`
    fails the manifest the same way) is refused here, naming the package, the
    asset entry, and every valid name — a misspelled platform would otherwise
    bundle nowhere on every target, silently.
    """
    for entry in parsed_assets:
        invalid = invalid_asset_platforms(entry.platforms)
        if invalid:
            fail(asset_platform_error(package_name, entry.path, invalid))

def _covering_entry(parsed_assets, path):
    """The `flutter.assets` declaration covering `path`, for failure messages.

    A direct entry covers itself; a trailing-slash directory declaration
    covers every file walked out of it. Falls back to the path itself when
    no declaration covers it (a font asset or a shader path).
    """
    for entry in parsed_assets:
        if entry.path == path:
            return entry.path
        if entry.path.endswith("/") and path.startswith(entry.path):
            return entry.path
    return path

def check_spoke_file_names(package_name, asset_block, expanded):
    """Fail the spoke fetch on declared or walked names no target can name.

    Every refused class (see `check_spoke_file_name`) fails here, naming
    the package, the declaring entry and the file rather than emitting a
    spoke that cannot name them. Trailing-slash directory declarations are
    covering entries, never emitted target names, so only the files walked
    out of them are checked (with the declaration in the message).

    Args:
        package_name: The pub package the entries come from.
        asset_block: The parsed `flutter` block (assets, fonts, shaders).
        expanded: The walked asset files, each with a `path` field.

    Returns:
        None; fails the fetch on the first unemittable name.
    """
    for entry in asset_block.assets:
        if not entry.path.endswith("/"):
            check_spoke_file_name(package_name, entry.path, entry.path)
    for item in expanded:
        check_spoke_file_name(package_name, _covering_entry(asset_block.assets, item.path), item.path)
    for family in asset_block.fonts:
        for font in family.fonts:
            check_spoke_file_name(package_name, "flutter.fonts[" + family.family + "]", font.asset)
    for shader in asset_block.shaders:
        check_spoke_file_name(package_name, shader.path, shader.path)

def _spoke_asset_inputs(ctx, package_name, asset_block):
    """Pre-computes the pub-asset generator inputs, used by either branch.

    Returns `struct(fonts_json_str, font_files, pkg_assets,
    pkg_asset_platforms, pkg_asset_flavors, pkg_shaders,
    has_contributions)`.
    """
    _check_asset_platforms(package_name, asset_block.assets)
    fonts_json_str = _encode_fonts_json(asset_block.fonts)
    font_files = _build_font_files_dict(asset_block.fonts)
    expanded = expand_pub_asset_entries(
        asset_block.assets,
        lambda directory: _readdir_files_recursive(ctx, directory),
    )
    check_spoke_file_names(package_name, asset_block, expanded)
    pkg_assets_dict = _build_pkg_assets_dict(expanded)
    pkg_asset_platforms, pkg_asset_flavors = _build_pkg_asset_conditions(expanded, package_name)
    pkg_shaders_dict = _build_pkg_shaders_dict(asset_block.shaders)
    return struct(
        fonts_json_str = fonts_json_str,
        font_files = font_files,
        pkg_assets = pkg_assets_dict,
        pkg_asset_platforms = pkg_asset_platforms,
        pkg_asset_flavors = pkg_asset_flavors,
        pkg_shaders = pkg_shaders_dict,
        has_contributions = (
            bool(asset_block.fonts) or bool(asset_block.assets) or bool(asset_block.shaders)
        ),
    )

def _empty_android_spoke():
    """Android sub-package inputs for a spoke with no Android side."""
    return struct(
        src_dir = "",
        java_package = "",
        extra_maven_labels = [],
        manifest = "",
        consumer_proguard_specs = [],
        has_resources = False,
        native_build = False,
    )

def _write_overlay_spoke(ctx, overlay_content, overlay_android_content):
    """Emits an overlay's BUILD content, replacing auto-generation entirely.

    When the overlay ships an `android/BUILD.bazel.tpl`, it is used
    verbatim. Otherwise an empty stub is emitted so the hub's
    `android/all_android_plugin_libs` aggregator can depend on
    `@<spoke>//android:lib` uniformly across overlay-and-no-Android
    plugins (audio_session declares Android sources and ships the full
    sub-package; objective_c is pure Apple and gets the stub).
    """
    ctx.file("BUILD.bazel", overlay_content)
    if overlay_android_content:
        ctx.file("android/BUILD.bazel", overlay_android_content)
    else:
        ctx.file(
            "android/BUILD.bazel",
            make_android_subpackage_build_content(
                android_src_dir = "",
                java_package = "",
                extra_maven_labels = [],
            ),
        )

def _detect_apple_plugin_sources(ctx, package_name, plugin_block):
    """Detects Apple sources per platform when pluginClass is set.

    Returns `struct(macos_srcs, ios_srcs, macos_includes, ios_includes,
    macos_manifests, ios_manifests)`.
    """
    apple_macos_srcs_dirs = []
    apple_ios_srcs_dirs = []
    apple_macos_include_dirs = []
    apple_ios_include_dirs = []
    apple_macos_privacy_manifests = []
    apple_ios_privacy_manifests = []

    macos_info = plugin_block.platforms.get("macos", {})
    ios_info = plugin_block.platforms.get("ios", {})
    macos_shared_darwin = macos_info.get("sharedDarwinSource", False) if macos_info else False
    ios_shared_darwin = ios_info.get("sharedDarwinSource", False) if ios_info else False

    if macos_info and macos_info.get("pluginClass", ""):
        apple_macos_srcs_dirs = _detect_apple_source_dirs(
            ctx,
            package_name,
            "macos",
            macos_shared_darwin,
        )
        apple_macos_include_dirs = _detect_apple_include_dirs(
            ctx,
            apple_macos_srcs_dirs,
            package_name,
        )
        apple_macos_privacy_manifests = _detect_apple_privacy_manifests(
            ctx,
            apple_macos_srcs_dirs,
        )

    if ios_info and ios_info.get("pluginClass", ""):
        apple_ios_srcs_dirs = _detect_apple_source_dirs(
            ctx,
            package_name,
            "ios",
            ios_shared_darwin,
        )
        apple_ios_include_dirs = _detect_apple_include_dirs(
            ctx,
            apple_ios_srcs_dirs,
            package_name,
        )
        apple_ios_privacy_manifests = _detect_apple_privacy_manifests(
            ctx,
            apple_ios_srcs_dirs,
        )

    return struct(
        macos_srcs = apple_macos_srcs_dirs,
        ios_srcs = apple_ios_srcs_dirs,
        macos_includes = apple_macos_include_dirs,
        ios_includes = apple_ios_include_dirs,
        macos_manifests = apple_macos_privacy_manifests,
        ios_manifests = apple_ios_privacy_manifests,
    )

def _detect_desktop_plugin_sources(ctx, plugin_block):
    """Detects Linux/Windows sources when pluginClass is set on that platform.

    The plugin's own `linux/`/`windows/` directory is the canonical
    location. Returns `struct(linux, windows)`.
    """
    linux_info = plugin_block.platforms.get("linux", {})
    windows_info = plugin_block.platforms.get("windows", {})
    linux_src_dir = ""
    windows_src_dir = ""
    if linux_info and linux_info.get("pluginClass", ""):
        linux_src_dir = _detect_desktop_source_dir(ctx, "linux")
    if windows_info and windows_info.get("pluginClass", ""):
        windows_src_dir = _detect_desktop_source_dir(ctx, "windows")
    return struct(linux = linux_src_dir, windows = windows_src_dir)

def _detect_android_plugin_sources(ctx, plugin_block):
    """Detects the Android side when pluginClass is set on android.

    The plugin's Android Gradle build is ONE consistent model: Gradle
    evaluates exactly one build file per project directory, so every reader
    below shares plugin_android_build's single choice (see
    gradle_build_file_choice). Namespace resolution mirrors AGP (gradle
    `android.namespace`, else the manifest `package` attribute). The
    pubspec's `package` field locates the plugin class for the registrant;
    it only stands in for the namespace when the plugin declares none of
    its own.

    Returns `struct(src_dir, java_package, extra_maven_labels, manifest,
    consumer_proguard_specs, has_resources, native_build)`.
    """
    android_info = plugin_block.platforms.get("android", {})
    android_build = struct(path = "", content = "")
    android_native_build = False
    if android_info:
        android_build = plugin_android_build(ctx)
        android_native_build = detect_android_native_build(ctx, android_build.path, android_build.content)

    android_src_dir = ""
    android_java_package = ""
    android_extra_maven_labels = []
    android_manifest = ""
    android_consumer_proguard_specs = []
    android_has_resources = False
    if android_info and android_info.get("pluginClass", ""):
        android_src_dir = _detect_android_source_dir(ctx)
        android_has_resources = _detect_android_resources(ctx)
        android_java_package = (
            detect_android_namespace(ctx, android_build.path, android_build.content) or
            android_info.get("package", "") or
            ""
        )
        _fail_on_invalid_android_namespace(ctx.attr.package_name, android_java_package)
        if android_src_dir or android_has_resources:
            android_extra_maven_labels = resolve_plugin_maven_deps(ctx, android_build.path, android_build.content)
            android_manifest = _detect_android_manifest(ctx)
            android_consumer_proguard_specs = detect_consumer_proguard_specs(ctx, android_build.path, android_build.content)

    return struct(
        src_dir = android_src_dir,
        java_package = android_java_package,
        extra_maven_labels = android_extra_maven_labels,
        manifest = android_manifest,
        consumer_proguard_specs = android_consumer_proguard_specs,
        has_resources = android_has_resources,
        native_build = android_native_build,
    )

def _build_plugin_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook):
    """Builds a `flutter_plugin` spoke and its Android sub-package inputs."""
    package_name = ctx.attr.package_name
    apple = _detect_apple_plugin_sources(ctx, package_name, pubspec.plugin_block)
    desktop = _detect_desktop_plugin_sources(ctx, pubspec.plugin_block)
    android = _detect_android_plugin_sources(ctx, pubspec.plugin_block)
    plugin_platforms_json = json.encode(pubspec.plugin_block.platforms)
    build_content = make_flutter_plugin_build_content(
        name = package_name,
        deps = dep_labels,
        language_version = pubspec.language_version,
        version = ctx.attr.version,
        code_assets = ctx.attr.code_assets,
        has_unreplaced_hook = unreplaced_hook,
        plugin_platforms_json = plugin_platforms_json,
        apple_macos_srcs_dirs = apple.macos_srcs,
        apple_ios_srcs_dirs = apple.ios_srcs,
        apple_macos_include_dirs = apple.macos_includes,
        apple_ios_include_dirs = apple.ios_includes,
        apple_macos_privacy_manifests = apple.macos_manifests,
        apple_ios_privacy_manifests = apple.ios_manifests,
        linux_src_dir = desktop.linux,
        windows_src_dir = desktop.windows,
        fonts_json_str = assets.fonts_json_str,
        font_files = assets.font_files,
        pkg_assets = assets.pkg_assets,
        pkg_asset_platforms = assets.pkg_asset_platforms,
        pkg_asset_flavors = assets.pkg_asset_flavors,
        pkg_shaders = assets.pkg_shaders,
    )
    return struct(build_content = build_content, android = android)

def _build_library_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook):
    """Builds a `flutter_library` spoke for asset/font/shader contributions.

    No plugin block, but the pubspec has flutter.fonts/assets/shaders:
    a `flutter_library` (rather than `dart_library`) so the metadata
    propagates via FlutterInfo.pub_fonts/pub_assets/pub_shaders to the
    consuming app's bundle aggregator.
    """
    build_content = make_flutter_library_build_content(
        name = ctx.attr.package_name,
        deps = dep_labels,
        language_version = pubspec.language_version,
        version = ctx.attr.version,
        code_assets = ctx.attr.code_assets,
        has_unreplaced_hook = unreplaced_hook,
        fonts_json_str = assets.fonts_json_str,
        font_files = assets.font_files,
        pkg_assets = assets.pkg_assets,
        pkg_asset_platforms = assets.pkg_asset_platforms,
        pkg_asset_flavors = assets.pkg_asset_flavors,
        pkg_shaders = assets.pkg_shaders,
    )
    return struct(build_content = build_content, android = _empty_android_spoke())

def _build_dart_spoke_content(ctx, pubspec, dep_labels, unreplaced_hook):
    """Builds a plain `dart_library` spoke via rules_dart's generator."""
    build_content = make_dart_library_build_content(
        name = ctx.attr.package_name,
        deps = dep_labels,
        language_version = pubspec.language_version,
        code_assets = ctx.attr.code_assets,
        has_unreplaced_hook = unreplaced_hook,
        version = ctx.attr.version,
    )
    if ctx.attr.package_name == "test":
        ctx.file("flutter_test_package.bzl", _FLUTTER_TEST_PACKAGE_BZL_CONTENT)
        build_content = build_content.replace(
            '    "dart_test_package",\n',
            "",
        ).replace(
            "dart_test_package(",
            'load(":flutter_test_package.bzl", "flutter_test_package")\n\nflutter_test_package(',
        )
    return struct(build_content = build_content, android = _empty_android_spoke())

def _build_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook):
    """Builds the spoke BUILD content for whichever branch the pubspec selects.

    Returns `struct(build_content, android)` where `android` carries the
    Android sub-package inputs for the follow-up `android/BUILD.bazel`.
    """
    if pubspec.plugin_block.present:
        return _build_plugin_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook)
    if assets.has_contributions:
        return _build_library_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook)
    return _build_dart_spoke_content(ctx, pubspec, dep_labels, unreplaced_hook)

def _flutter_pub_package_impl(ctx):
    _fetch_pub_archive(ctx)
    _generate_spoke(ctx)

# Top-level names a path-spoke link walk never descends into: build output,
# pub's own tool state, the example app (whose `flutter pub get` leaves a
# `.plugin_symlinks` cycle back to the package root next to its own `build/`
# output), and dot-directories. The generator reads nothing under them, so
# linking or watching them only makes the fetch machine-dependent.
_PATH_SPOKE_SKIP_DIRS = ("build", ".dart_tool", "example")

# File extensions a shader may `#include`: the spoke links them beside a
# top-level declared shader so its scoped include glob resolves.
_PATH_SPOKE_SHADER_INCLUDE_EXTS = ("glsl", "frag", "vert")

# File names a path spoke never links: the spoke generates every BUILD file
# it needs, so the package's own stay untouched and are not used. Skipping
# them keeps a nested BUILD file from cutting the spoke's `lib/**` globs
# into a second Bazel package.
_PATH_SPOKE_SKIP_FILES = ("BUILD", "BUILD.bazel")

def is_path_spoke_skipped_dir(name):
    """Whether a path-spoke link walk skips this top-level entry.

    Anything under `build/`, `.dart_tool/`, `example/`, or a dot-directory
    is build output or tool state the generator never reads.
    """
    return name in _PATH_SPOKE_SKIP_DIRS or name.startswith(".")

def path_spoke_is_ancestor_cycle(package_realpath, target_realpath):
    """Whether a link target is the package itself or one of its ancestors.

    Pure testable core of the ancestor-link refusal: a source symlink
    resolving here would cycle any fetch-time walk (the `.plugin_symlinks`
    shape `flutter pub get` leaves behind).

    Args:
        package_realpath: The linked package root's resolved path.
        target_realpath: The link's resolved path.

    Returns:
        True when the target is the package or an ancestor of it.
    """
    return (
        target_realpath == package_realpath or
        target_realpath == "/" or
        package_realpath.startswith(target_realpath + "/")
    )

def ancestor_link_refusal(package_name, link_rel, link_real):
    """The fetch refusal for a link escaping to the package or an ancestor.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package and the link.
    """
    return (
        "flutter.pub repo rule: path dependency \"" + package_name + "\" " +
        "links \"" + link_rel + "\" which resolves to the package itself " +
        "or one of its ancestors (" + link_real + "); linking it would " +
        "cycle fetch-time walks. Point the path entry at the package " +
        "directory itself."
    )

def path_spoke_platform_dirs(plugin_block):
    """The platform directories the spoke generator reads for a plugin.

    Pure testable core of the link plan: a declared platform's directory
    is where the generator probes for manifests, Gradle files, and native
    sources, so only declared platforms get linked.

    Args:
        plugin_block: The parsed plugin block (or `_EMPTY_PLUGIN`).

    Returns:
        The sorted platform directory names to link, possibly empty.
    """
    platforms = plugin_block.platforms
    dirs = []
    if "android" in platforms:
        dirs.append("android")
    if "ios" in platforms or "macos" in platforms:
        dirs.extend(["darwin", "ios", "macos"])
    if "linux" in platforms:
        dirs.append("linux")
    if "windows" in platforms:
        dirs.append("windows")
    return sorted(dirs)

def _spoke_entry_parts(package_name, entry_path):
    """Split a declared package entry into segments, failing closed.

    Absolute paths, entries escaping above the package root through `..`,
    and empty entries fail naming the package and the entry; `.` segments
    and duplicate slashes normalize away.
    """
    if entry_path == "" or entry_path.startswith("/"):
        fail("flutter.pub repo rule: path dependency \"" + package_name +
             "\" declares entry \"" + entry_path +
             "\" which is not inside the package.")
    parts = []
    for part in entry_path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                fail("flutter.pub repo rule: path dependency \"" +
                     package_name + "\" declares entry \"" + entry_path +
                     "\" which escapes the package.")
            parts.pop()
            continue
        parts.append(part)
    if not parts:
        fail("flutter.pub repo rule: path dependency \"" + package_name +
             "\" declares entry \"" + entry_path +
             "\" which names no file or directory.")
    return parts

def _link_new_symlink(ctx, node, repo_rel, linked):
    """Symlink one node unless an earlier entry already linked it.

    Overlapping declarations (a shader inside a declared asset dir, a file
    inside its own declared dir) reach the same spoke path twice; the
    second link would fail with "File exists". The first link already
    watches the source, so skipping repeats loses nothing.
    """
    if repo_rel in linked:
        return
    ctx.symlink(node, repo_rel)
    ctx.watch(node)
    linked[repo_rel] = True

def _link_scoped_symlink(ctx, node, repo_rel, package_name, package_realpath, linked):
    """Replicate one source symlink inside the spoke without descending.

    A link resolving to the package or an ancestor would cycle the
    fetch-time walks (the `.plugin_symlinks` shape); it fails naming the
    package and the link. Any other link replicates as-is and is watched,
    so outside targets stay outside and the walk always terminates.
    """
    if path_spoke_is_ancestor_cycle(package_realpath, str(node.realpath)):
        fail(ancestor_link_refusal(package_name, repo_rel, str(node.realpath)))
    _link_new_symlink(ctx, node, repo_rel, linked)

def _link_scoped_tree(ctx, node, repo_rel, package_name, package_realpath, linked):
    """Mirror one real source directory into the spoke file by file.

    Real directories become real repository directories holding one symlink
    per file, so the generator's `ctx.file` writes (the root and generated
    BUILD files) can never land in the user tree through a symlinked
    directory. Symlinks replicate without descending; skipped subtrees
    (`build/`, `.dart_tool/`, `example/`, dot-directories) stay unlinked
    and unwatched so machine-local output cannot affect the fetch; user
    BUILD files are watched but not linked. The explicit stack over a
    bounded loop keeps one pathological package from hanging the fetch.
    """
    ctx.watch(node)
    stack = [(node, repo_rel)]
    for _ in range(10000):
        if not stack:
            break
        (parent, parent_rel) = stack.pop()
        for child in parent.readdir():
            name = child.basename
            if is_path_spoke_skipped_dir(name):
                continue
            child_rel = parent_rel + "/" + name
            if str(child.realpath) != package_realpath + "/" + child_rel:
                _link_scoped_symlink(ctx, node = child, repo_rel = child_rel, package_name = package_name, package_realpath = package_realpath, linked = linked)
                continue
            if child.is_dir:
                ctx.watch(child)
                stack.append((child, child_rel))
                continue
            if name in _PATH_SPOKE_SKIP_FILES:
                ctx.watch(child)
                continue
            _link_new_symlink(ctx, child, child_rel, linked)
    if stack:
        fail("flutter.pub repo rule: path dependency \"" + package_name +
             "\" holds more than 10000 directories under its linked " +
             "entries. Refusing it rather than fetching part of the tree.")

def _link_top_level_shader_includes(ctx, src, package_name, package_realpath, linked):
    """Link top-level include siblings for a top-level declared shader.

    A declared `ripple.frag` at the package root resolves `#include`s
    against the root, so the spoke links the root's `.glsl`/`.frag`/`.vert`
    files beside it — flat, never descending, skipping build output, tool
    state, and user BUILD files like every other link.
    """
    for child in src.readdir():
        name = child.basename
        if is_path_spoke_skipped_dir(name):
            continue
        if child.is_dir:
            continue
        if name in _PATH_SPOKE_SKIP_FILES:
            ctx.watch(child)
            continue
        if name.rpartition(".")[2] not in _PATH_SPOKE_SHADER_INCLUDE_EXTS:
            continue
        if str(child.realpath) != package_realpath + "/" + name:
            _link_scoped_symlink(ctx, node = child, repo_rel = name, package_name = package_name, package_realpath = package_realpath, linked = linked)
            continue
        _link_new_symlink(ctx, child, name, linked)

def _link_scoped_dir_entry(ctx, src, entry_path, package_name, package_realpath, linked):
    """Link one declared directory entry (asset, shader, or platform dir).

    Missing entries stay unlinked (a declared-but-absent directory is not
    an error); real directories mirror file by file; anything else
    replicates as a single symlink, refusing package-ancestor cycles.
    """
    parts = _spoke_entry_parts(package_name, entry_path)
    node = src.get_child(*parts)
    if not node.exists:
        return
    repo_rel = "/".join(parts)
    if str(node.realpath) != package_realpath + "/" + repo_rel:
        _link_scoped_symlink(ctx, node = node, repo_rel = repo_rel, package_name = package_name, package_realpath = package_realpath, linked = linked)
        return
    if node.is_dir:
        _link_scoped_tree(ctx, node, repo_rel, package_name, package_realpath, linked)
        return
    ctx.symlink(node, repo_rel)
    ctx.watch(node)

def _link_scoped_file_entry(ctx, src, entry_path, package_name, package_realpath, linked):
    """Link one declared file entry (pubspec, hook, asset, font, shader).

    Missing entries stay unlinked; a directory at the entry mirrors file
    by file; a user BUILD file is watched but not linked; anything else
    becomes a single symlink, refusing package-ancestor cycles.
    """
    parts = _spoke_entry_parts(package_name, entry_path)
    node = src.get_child(*parts)
    if not node.exists:
        return
    repo_rel = "/".join(parts)
    if str(node.realpath) != package_realpath + "/" + repo_rel:
        _link_scoped_symlink(ctx, node = node, repo_rel = repo_rel, package_name = package_name, package_realpath = package_realpath, linked = linked)
        return
    if node.is_dir:
        _link_scoped_tree(ctx, node, repo_rel, package_name, package_realpath, linked)
        return
    if node.basename in _PATH_SPOKE_SKIP_FILES:
        ctx.watch(node)
        return
    _link_new_symlink(ctx, node, repo_rel, linked)

def _link_spoke_contents(ctx, src, asset_block, plugin_block, package_name, package_realpath, linked):
    """Link everything the spoke generator reads or exposes — nothing else.

    The pubspec leads: `lib/`, hook scripts, declared assets, fonts, and
    shaders (plus each shader's own directory, or the root's include
    siblings for a top-level shader), and the plugin's platform
    directories. (`link_path_package` links the pubspec itself first, so it
    can parse it for this plan.) Everything else in the package —
    `example/`, `build/`, `.dart_tool/`, dot-directories, undeclared files
    — stays out of the spoke and unwatched, so machine-local state cannot
    affect the fetch. Overlapping declarations (a shader inside a declared
    asset dir, a file inside its own declared dir) link each spoke path
    once: `linked` records every created symlink.
    """
    for entry in ["lib", "hook/build.dart", "hook/link.dart"]:
        _link_scoped_file_entry(ctx, src, entry, package_name, package_realpath, linked)
    for asset in asset_block.assets:
        if asset.path.endswith("/"):
            _link_scoped_dir_entry(ctx, src, asset.path[:-1], package_name, package_realpath, linked)
        else:
            _link_scoped_file_entry(ctx, src, asset.path, package_name, package_realpath, linked)
    for family in asset_block.fonts:
        for font in family.fonts:
            _link_scoped_file_entry(ctx, src, font.asset, package_name, package_realpath, linked)
    for shader in asset_block.shaders:
        _link_scoped_file_entry(ctx, src, shader.path, package_name, package_realpath, linked)
        shader_dir = shader.path.rpartition("/")[0]
        if shader_dir:
            _link_scoped_dir_entry(ctx, src, shader_dir, package_name, package_realpath, linked)
        else:
            _link_top_level_shader_includes(ctx, src, package_name, package_realpath, linked)
    for platform_dir in path_spoke_platform_dirs(plugin_block):
        _link_scoped_dir_entry(ctx, src, platform_dir, package_name, package_realpath, linked)

def link_path_package(ctx):
    """Symlinks a workspace-local `path:` package into the spoke, hermetically.

    The link plan parses the package's own `pubspec.yaml` from the spoke:
    `lib/`, the pubspec, hook scripts, declared assets/fonts/shaders (plus
    each shader's own directory), and the plugin's platform directories are
    mirrored one file at a time into real repository directories — never
    whole-directory symlinks — so the generator's `ctx.file` writes land in
    the spoke, never in the user tree. `example/`, `build/`, `.dart_tool/`,
    dot-directories, undeclared files, and user BUILD files stay unlinked
    (skipped subtrees are not even watched); source links replicate without
    descending and fail closed, naming the package and the link, when they
    resolve to the package or an ancestor. Fails closed: an absolute path,
    a `..` escape, or a missing directory fails the fetch rather than
    emitting an empty spoke or reaching outside the workspace.

    Args:
        ctx: The path-package spoke's repository context. Reads `path` and
            `package_name` from its attrs.

    Returns:
        None.
    """
    rel = ctx.attr.path
    if rel.startswith("/") or rel in ("", "."):
        fail("flutter.pub spoke for \"{pkg}\": path dependency {path} is not a workspace-relative package directory. Refusing it rather than resolving outside the workspace.".format(
            pkg = ctx.attr.package_name,
            path = repr(rel),
        ))
    segments = rel.split("/")
    if ".." in segments or "." in segments or "" in segments:
        fail("flutter.pub spoke for \"{pkg}\": path dependency {path} escapes its directory. Refusing it rather than resolving outside the workspace.".format(
            pkg = ctx.attr.package_name,
            path = repr(rel),
        ))
    src = ctx.workspace_root.get_child(*segments)
    if not src.exists:
        fail("flutter.pub spoke for \"{pkg}\": path dependency {path} does not exist under the workspace. Refusing it rather than emitting an empty package.".format(
            pkg = ctx.attr.package_name,
            path = repr(rel),
        ))
    package_name = ctx.attr.package_name
    package_realpath = str(src.realpath)
    linked = {}

    # The pubspec leads: link it first, then parse the spoke-side copy for
    # the link plan, so the spoke links only what the generator reads or
    # exposes. A missing pubspec parses as empty rather than failing: the
    # spoke pipeline reports the real problem.
    _link_scoped_file_entry(ctx, src, "pubspec.yaml", package_name, package_realpath, linked)
    pubspec_node = ctx.path("pubspec.yaml")
    pubspec_text = ctx.read(pubspec_node) if pubspec_node.exists else ""
    _link_spoke_contents(
        ctx,
        src,
        parse_flutter_assets_block(pubspec_text),
        parse_flutter_plugin_block(pubspec_text),
        package_name,
        package_realpath,
        linked,
    )
    ctx.watch(src)

def _flutter_pub_path_package_impl(ctx):
    link_path_package(ctx)
    _generate_spoke(ctx)

def _generate_spoke(ctx):
    """Runs the shared spoke pipeline: pubspec in, BUILD content out."""
    pubspec = _read_spoke_pubspec(ctx)

    # Build full label strings for sibling spoke repos.
    dep_labels = _spoke_dep_labels(ctx, pubspec.bazel_deps, pubspec.asset_block)

    # Pre-compute the pub-asset attr inputs once. Used by either branch
    # below (plugin vs library).
    assets = _spoke_asset_inputs(ctx, ctx.attr.package_name, pubspec.asset_block)

    # Computed once, before the branch: which generator runs depends on the
    # pubspec, but a build hook is a property of the package either way.
    unreplaced_hook = _detect_unreplaced_hook(ctx)

    # Try overlays first (user-supplied roots win over the bundled
    # `@rules_flutter//ext/` tree). On match, the overlay replaces
    # auto-generation entirely; the user takes responsibility for the
    # spoke's BUILD content.
    overlay_content, overlay_android_content = resolve_overlay_roots(
        ctx,
        ctx.attr.overlay_roots,
        ctx.attr.package_name,
        ctx.attr.version,
        pubspec.language_version,
        dep_labels,
    )

    if overlay_content:
        _write_overlay_spoke(ctx, overlay_content, overlay_android_content)
        return

    spoke = _build_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook)
    ctx.file("BUILD.bazel", spoke.build_content)

    # Always emit `android/BUILD.bazel`. Bazel only loads it when something
    # queries `@<spoke>//android:lib`, so non-Android workspaces don't pay
    # the @rules_android / @rules_kotlin cost. Plugins whose Gradle build
    # compiles native Android code that autogen cannot translate get a
    # load-time fail() here instead — Android builds break loudly rather
    # than shipping an APK missing the library.
    if spoke.android.native_build:
        android_build_content = _make_android_native_build_unsupported_content(
            ctx.attr.package_name,
            ctx.attr.version,
        )
    else:
        android_build_content = make_android_subpackage_build_content(
            android_src_dir = spoke.android.src_dir,
            java_package = spoke.android.java_package,
            extra_maven_labels = spoke.android.extra_maven_labels,
            android_manifest = spoke.android.manifest,
            consumer_proguard_specs = spoke.android.consumer_proguard_specs,
            has_resources = spoke.android.has_resources,
        )
    ctx.file("android/BUILD.bazel", android_build_content)

_FLUTTER_TEST_PACKAGE_BZL_CONTENT = """\
load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart/private:dart_test_runner.bzl",
    "DartTestRunnerInfo",
    "DartTestRunnerSnapshotInfo",
)

def _flutter_test_package_impl(ctx):
    library = ctx.attr.library
    dills = [f for f in ctx.attr.runner[DefaultInfo].files.to_list() if f.extension == "dill"]
    if len(dills) != 1:
        fail("%s: `runner` must produce exactly one `.dill`, got %s" % (ctx.label, dills))
    runner = dills[0]
    if ctx.attr.snapshot != None:
        snapshot = ctx.attr.snapshot[DartTestRunnerSnapshotInfo].snapshot
        if snapshot != None:
            runner = snapshot
    return [
        library[DefaultInfo],
        library[DartInfo],
        DartTestRunnerInfo(runner = runner),
    ]

flutter_test_package = rule(
    implementation = _flutter_test_package_impl,
    attrs = {
        "library": attr.label(
            doc = "The `package:test` `dart_library`.",
            mandatory = True,
            providers = [DartInfo],
        ),
        "runner": attr.label(
            doc = "A kernel-mode `dart_binary` built from `library`.",
            mandatory = True,
        ),
        "snapshot": attr.label(
            doc = "A `dart_test_runner_snapshot` of `runner`. Its snapshot runs in place of the kernel when one was built.",
            providers = [DartTestRunnerSnapshotInfo],
        ),
    },
    doc = "`package:test` as a dependency, carrying the runner built from it.",
)
"""

flutter_pub_package = repository_rule(
    implementation = _flutter_pub_package_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The pub.dev package name.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version to download.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive. Taken from the hosted lock entry; an empty value fails the fetch.",
            default = "",
        ),
        "base_url": attr.string(
            doc = "Base URL for the pub repository.",
            default = "https://pub.dev",
        ),
        "hub_name": attr.string(
            doc = "Name of the hub repo (for constructing cross-spoke dep labels).",
            mandatory = True,
        ),
        "lock_packages": attr.string_list(
            doc = "All hosted package names in the lock file (for dep filtering).",
            default = [],
        ),
        "code_assets": attr.string_list(
            doc = "Labels of `dart_code_asset` targets standing in for this " +
                  "package's build hook. Resolved by the extension from " +
                  "rules_dart's curated registry, so a user depending on, say, " +
                  "`drift` never names `sqlite3`. Attached to the generated " +
                  "package target rather than to the application, which is what " +
                  "makes them propagate the way pub's own assets do.",
            default = [],
        ),
        "ignore_hook": attr.bool(
            doc = "Treat this package's build hook as irrelevant. Without it, a " +
                  "package shipping a hook that nothing replaces is recorded and " +
                  "the application that reaches it fails, rather than building " +
                  "cleanly and dying at runtime on an unresolved native symbol.",
            default = False,
        ),
        "android_maven_deps": attr.string_dict(
            doc = "`group:artifact` -> Bazel label additions to the built-in " +
                  "Gradle-to-`@rules_android_maven` mapping, from " +
                  "`flutter.pub(android_maven_deps)`. A plugin's " +
                  "`android/build.gradle*` runtime dependency whose " +
                  "coordinate is in neither table fails the fetch; mapping " +
                  "it here is the fix for external artifacts.",
            default = {},
        ),
        "android_maven_ignore": attr.string_list(
            doc = "`group:artifact` coordinates that need no Bazel label, " +
                  "from `flutter.pub(android_maven_ignore)`. A coordinate " +
                  "listed here is left out of the spoke's deps instead of " +
                  "failing the fetch as unknown. This is a declaration you " +
                  "make deliberately; it is never a default.",
            default = [],
        ),
        "overlay_roots": attr.label_list(
            doc = "BUILD.bazel anchors for overlay trees. Each label points at " +
                  "an `ext/BUILD.bazel` (or equivalent) that anchors a directory " +
                  "tree of `<package>/<version>/BUILD.bazel.tpl` overrides. The " +
                  "rule walks the roots in order and uses the first match. " +
                  "User-supplied roots come before the bundled " +
                  "`@rules_flutter//ext:BUILD.bazel`.",
            allow_files = True,
            default = [],
        ),
    },
    doc = "Downloads a single Flutter pub package and emits a `flutter_plugin` (when `flutter.plugin` is present) or a plain `dart_library` (otherwise). When Apple sources are detected, also emits per-platform `flutter_apple_plugin_library` sub-targets. Honors per-package overlay BUILD.bazel.tpl overrides under `overlay_roots`. The `flutter pub get` analog of `pub_lock_package`.",
)

flutter_pub_path_package = repository_rule(
    implementation = _flutter_pub_path_package_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The pub package name.",
            mandatory = True,
        ),
        "path": attr.string(
            doc = "Workspace-relative directory of the package (the lock's `path:` value, relative to the lock file). Symlinked in; absolute paths and `..` escapes fail the fetch.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version, when the lock states one. Empty stays " +
                  "unstated and never conflicts, matching the hosted rule.",
            default = "",
        ),
        "hub_name": attr.string(
            doc = "Name of the hub repo (for constructing cross-spoke dep labels).",
            mandatory = True,
        ),
        "lock_packages": attr.string_list(
            doc = "All package names in the lock file (for dep filtering).",
            default = [],
        ),
        "code_assets": attr.string_list(
            doc = "Labels of `dart_code_asset` targets standing in for this " +
                  "package's build hook, same as `flutter_pub_package`.",
            default = [],
        ),
        "ignore_hook": attr.bool(
            doc = "Treat this package's build hook as irrelevant, same as " +
                  "`flutter_pub_package`.",
            default = False,
        ),
        "overlay_roots": attr.label_list(
            doc = "BUILD.bazel anchors for overlay trees, same as " +
                  "`flutter_pub_package`.",
            allow_files = True,
            default = [],
        ),
    },
    doc = "Symlinks a workspace-local `path:` pub package into a spoke and emits the same `flutter_plugin` / `flutter_library` / `dart_library` the hosted rule would. The `flutter pub get` analog for path dependencies: hermetic (workspace-relative only, watched for changes) and fail-closed on anything outside the workspace.",
)
