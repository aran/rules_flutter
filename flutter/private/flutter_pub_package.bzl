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

load("@rules_dart//dart/pub:pub_lock_package.bzl", "derive_language_version", "make_dart_library_build_content")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint")
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_assets_block", "parse_flutter_plugin_block")

# Apple source extensions we sweep into the per-platform plugin library.
_APPLE_SRC_EXTENSIONS = ("swift", "m", "mm", "h")

# C/C++ source extensions for Linux/Windows plugin libraries.
_DESKTOP_SRC_EXTENSIONS = ("cc", "cpp", "c", "h", "hh", "hpp")

# Kotlin/Java source extensions for Android plugin libraries.
_ANDROID_SRC_EXTENSIONS = ("kt", "java")

def _has_files_under(ctx, relative_path, extensions):
    """Check `<package>/<relative_path>` for source files.

    Returns True if the directory exists and contains at least one file
    matching one of `extensions`. `ctx.path(p).readdir()` is the
    documented repo-rule way to walk a directory; recursing in Starlark
    keeps the logic local instead of forking out to `find`.
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

def _detect_android_native_build(ctx):
    """True when the plugin's Gradle build compiles native code with the NDK.

    Gradle-built Flutter plugins declare `externalNativeBuild` in
    `android/build.gradle*` to compile C/C++ sources (CMake / ndk-build)
    into a shared library the APK must carry — e.g. package:jni's
    libdartjni.so. rules_flutter has no generic translation for those
    builds; packages that need one ship a curated overlay (bundled under
    `@rules_flutter//ext/` or user-supplied via `flutter.plugin_overlays`).
    Detection lets the generated android/ sub-package fail loudly instead
    of silently producing an APK missing the library.
    """
    for filename in ("android/build.gradle", "android/build.gradle.kts"):
        p = ctx.path(filename)
        if p.exists and "externalNativeBuild" in ctx.read(p):
            return True
    return False

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
    return 'fail("' + message + '")\n'

def _parse_consumer_proguard_files(content):
    """Extract `consumerProguardFiles` paths from a Gradle build script.

    AGP plugins declare reflection-keep rules they need consumers to
    apply via:
      consumerProguardFiles 'consumer-rules.pro'         (Groovy)
      consumerProguardFiles "consumer-rules.pro"         (Groovy)
      consumerProguardFiles("consumer-rules.pro")        (Kotlin DSL)
    Multiple files per declaration are comma-separated. Returns a sorted,
    deduplicated list of paths. Permissive matching by design: false
    positives in comments / strings are filtered out by the existence
    check downstream.
    """
    paths = {}
    for raw_line in content.split("\n"):
        line = raw_line.strip()
        if "consumerProguardFiles" not in line:
            continue

        # Snip everything after the keyword and pull paths out of the
        # quoted segments. Supports both Groovy ('...') and Kotlin DSL
        # ("..."), and handles comma-separated multi-arg invocations.
        rest = line.split("consumerProguardFiles", 1)[1]
        for quote in ("'", '"'):
            idx = 0
            for _ in range(rest.count(quote) // 2):
                start = rest.find(quote, idx)
                if start < 0:
                    break
                end = rest.find(quote, start + 1)
                if end < 0:
                    break
                paths[rest[start + 1:end]] = True
                idx = end + 1
    return sorted(paths.keys())

def _detect_consumer_proguard_specs(ctx):
    """Find the plugin's `consumer-rules.pro` files, declared via Gradle.

    Reads `android/build.gradle` (or `android/build.gradle.kts`),
    parses `consumerProguardFiles` declarations, and returns paths
    relative to the spoke's `android/` sub-package — only for files
    that actually exist on disk. Empty when the plugin doesn't ship
    consumer rules. AGP propagates these into the consuming app's R8
    invocation; rules_android does the same when they appear in
    `kt_android_library(proguard_specs = [...])` and the binary has
    R8 enabled.
    """
    paths = []
    for filename in ("build.gradle", "build.gradle.kts"):
        gradle_path = ctx.path("android/" + filename)
        if gradle_path.exists:
            for relpath in _parse_consumer_proguard_files(ctx.read(gradle_path)):
                if ctx.path("android/" + relpath).exists:
                    paths.append(relpath)
    return paths

# Map well-known maven coordinates the plugin's `build.gradle` may pull
# in to labels under `@rules_android_maven`. We translate
# `implementation("group:artifact:version")` declarations into Bazel
# dep labels by looking up the `group:artifact` here. The user's
# workspace `maven.install` must include matching artifacts; the bundle
# of androidx + jetbrains coordinates Flutter plugins typically use is
# documented in `docs/TESTING.md` § Plugin verification matrix.
_MAVEN_COORD_TO_LABEL = {
    "androidx.annotation:annotation": "@rules_android_maven//:androidx_annotation_annotation",
    "androidx.lifecycle:lifecycle-common": "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
    "androidx.lifecycle:lifecycle-runtime": "@rules_android_maven//:androidx_lifecycle_lifecycle_runtime",
    "androidx.media:media": "@rules_android_maven//:androidx_media_media",
    "androidx.window:window": "@rules_android_maven//:androidx_window_window",
    "androidx.core:core": "@rules_android_maven//:androidx_core_core",
    "androidx.browser:browser": "@rules_android_maven//:androidx_browser_browser",
    "androidx.fragment:fragment": "@rules_android_maven//:androidx_fragment_fragment",
    "androidx.activity:activity": "@rules_android_maven//:androidx_activity_activity",
    "com.google.android.material:material": "@rules_android_maven//:com_google_android_material_material",
    "com.getkeepsafe.relinker:relinker": "@rules_android_maven//:com_getkeepsafe_relinker_relinker",
}

# Coordinates we deliberately ignore — provided by the kt_android_library
# rule itself or out-of-band. Listing them avoids the parser falling back
# to "drop unknown" silently for things we do recognize.
_MAVEN_COORDS_PROVIDED = {
    "org.jetbrains.kotlin:kotlin-stdlib": True,
    "org.jetbrains.kotlin:kotlin-stdlib-jdk7": True,
    "org.jetbrains.kotlin:kotlin-stdlib-jdk8": True,
}

def _parse_gradle_deps(content):
    """Extract `implementation("group:artifact:...")` coordinates from Gradle content.

    Handles both Groovy DSL (single quotes) and Kotlin DSL (double
    quotes / parens). Returns a list of `group:artifact` strings.
    `api(...)` declarations are treated the same way.
    """
    coords = []
    for raw_line in content.split("\n"):
        line = raw_line.strip()
        if not line:
            continue

        # Skip comments and gradle plugin classpaths.
        if line.startswith("//") or line.startswith("#"):
            continue

        # Match `implementation(...)` or `api(...)` or
        # `implementation "..."` (Groovy without parens).
        for prefix in ("implementation", "api", "compile"):
            if not line.startswith(prefix):
                continue
            rest = line[len(prefix):].strip()
            if not rest:
                continue
            if rest[0] not in ("(", '"', "'"):
                # Not a dep call — could be `implementations.add(...)` etc.
                continue

            # Pull out the first quoted string after the opening paren/quote.
            quote_idx = -1
            quote_char = ""
            for q in ('"', "'"):
                idx = rest.find(q)
                if idx >= 0 and (quote_idx < 0 or idx < quote_idx):
                    quote_idx = idx
                    quote_char = q
            if quote_idx < 0:
                break
            end = rest.find(quote_char, quote_idx + 1)
            if end < 0:
                break
            inner = rest[quote_idx + 1:end]

            # Strip Gradle template variables (`$kotlin_version`,
            # `${kotlin_version}`). Versions only — group:artifact stays
            # parseable. For our purposes the `group:artifact` is what we
            # key off, so we just split on the first two colons.
            parts = inner.split(":")
            if len(parts) < 2:
                break
            coord = "%s:%s" % (parts[0], parts[1])
            coords.append(coord)
            break
    return coords

def _resolve_plugin_maven_deps(ctx):
    """Translate the spoke's `android/build.gradle*` deps to Bazel labels.

    Reads the package's Gradle build file (Groovy `.gradle` or Kotlin
    `.gradle.kts`), extracts `implementation("group:artifact:...")`
    coordinates, and maps them via `_MAVEN_COORD_TO_LABEL` to
    `@rules_android_maven//:...` labels. Coordinates we don't recognize
    are silently dropped — the plugin's compile may still fail in that
    case, but the path forward is to add the artifact to the user's
    `maven.install` and update the table here. Coordinates we
    deliberately provide elsewhere (`kotlin-stdlib`) are skipped.

    Returns a sorted list of distinct labels.
    """
    candidates = (
        "android/build.gradle.kts",
        "android/build.gradle",
    )
    content = ""
    for cand in candidates:
        p = ctx.path(cand)
        if p.exists:
            content = ctx.read(p)
            break
    if not content:
        return []
    coords = _parse_gradle_deps(content)
    seen = {}
    labels = []
    for coord in coords:
        if coord in _MAVEN_COORDS_PROVIDED:
            continue
        label = _MAVEN_COORD_TO_LABEL.get(coord)
        if label and label not in seen:
            seen[label] = True
            labels.append(label)
    return sorted(labels)

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
    quoted = ['        "%s",' % p for p in patterns]
    excl_quoted = ['        "%s",' % e for e in excludes]
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
    treats as "include every file under this directory").
    """
    out = []
    base = ctx.path(rel_dir)
    if not base.exists:
        return out
    queue = [base]
    for _ in range(10000):  # bounded loop to satisfy Starlark's no-while constraint
        if not queue:
            break
        cur = queue.pop()
        for child in cur.readdir():
            if child.is_dir:
                queue.append(child)
            else:
                # Reconstruct package-relative path. ctx.path() basis is the
                # repository root, so child.basename + walking up gets us
                # what we want — but readdir paths already include the
                # trailing component. Use child path's segments past the
                # spoke root.
                rel = str(child)

                # Trim the spoke-root prefix; what's left is the relative
                # path we want.
                pkg_root = str(ctx.path("."))
                if rel.startswith(pkg_root + "/"):
                    out.append(rel[len(pkg_root) + 1:])
                else:
                    out.append(rel)
    return out

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

def _build_pkg_assets_dict(ctx, parsed_assets):
    """Build the `pkg_assets` dict, expanding directory entries.

    Flutter's `flutter.assets:` accepts paths and trailing-slash directory
    prefixes. Bazel needs an explicit label per file, so we walk each
    directory at repo-rule time and emit one entry per discovered file.
    """
    out = {}
    for entry in parsed_assets:
        path = entry.path
        if path.endswith("/"):
            for f in _readdir_files_recursive(ctx, path.rstrip("/")):
                out[":" + f] = f
        else:
            out[":" + path] = path
    return out

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
    lines = ['{indent}"{k}": "{v}",'.format(indent = indent, k = k, v = d[k]) for k in keys]
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

def _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders):
    """Render the four pub-asset attrs as BUILD source, omitting empty ones."""
    parts = []
    if fonts_json_str:
        parts.append("    fonts_json = {},".format(repr(fonts_json_str)))
    if font_files:
        parts.append("    font_files = {},".format(_format_label_dict_literal(font_files)))
    if pkg_assets:
        parts.append("    pkg_assets = {},".format(_format_label_dict_literal(pkg_assets)))
    if pkg_shaders:
        parts.append("    pkg_shaders = {},".format(_format_label_dict_literal(pkg_shaders)))
    return ("\n".join(parts) + "\n") if parts else ""

def _make_flutter_library_build_content(
        name,
        deps,
        language_version,
        fonts_json_str,
        font_files,
        pkg_assets,
        pkg_shaders):
    """Generate BUILD content for a non-plugin Flutter spoke shipping fonts/assets/shaders.

    Counterpart to `make_dart_library_build_content` — used when the spoke
    declares anything under `flutter:` other than `plugin:` (e.g.
    cupertino_icons declaring `flutter.fonts`). The same shape a user
    would write by hand: `flutter_library` with the new pub-asset attrs.
    """
    deps_block = ""
    if deps:
        dep_lines = ['        "{}",'.format(dep) for dep in deps]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    pub_attrs = _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders)

    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_library")

flutter_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{deps}    package_name = "{name}",
    language_version = "{language_version}",
{pub_attrs}    visibility = ["//visibility:public"],
)
""".format(
        name = name,
        deps = deps_block,
        language_version = language_version,
        pub_attrs = pub_attrs,
    )

def _make_flutter_plugin_build_content(
        name,
        deps,
        language_version,
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
        pkg_shaders = {}):
    """Generate BUILD content for a Flutter plugin spoke.

    Emits a `flutter_plugin` plus optional per-platform
    `flutter_apple_plugin_library` (Apple) /
    `flutter_linux_plugin_library` /
    `flutter_windows_plugin_library` sub-targets.

    Android Kotlin/Java sources are exposed via a sibling `android/`
    sub-package (see `_make_android_subpackage_build_content`). The
    sub-package is loaded only when something queries
    `@<spoke>//android:lib` — non-Android workspaces don't pay the
    `@rules_android` / `@rules_kotlin` cost.
    """
    deps_block = ""
    if deps:
        dep_lines = ['        "{}",'.format(dep) for dep in deps]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    extra_loads = []
    extra_targets = []
    apple_libs_arg = ""
    linux_libs_arg = ""
    windows_libs_arg = ""

    if apple_macos_srcs_dirs or apple_ios_srcs_dirs:
        extra_loads.append('load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")')
    if linux_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:linux.bzl", "flutter_linux_plugin_library")')
    if windows_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:windows.bzl", "flutter_windows_plugin_library")')

    # NOTE: Android Kotlin/Java sources are NOT compiled in the top-level
    # spoke BUILD. Instead, they're exposed via a sibling `android/`
    # sub-package (see _make_android_subpackage_build_content) which loads
    # @rules_android + @rules_kotlin lazily — only when something queries
    # `@<spoke>//android:lib`. Mac-only / web-only workspaces never trigger
    # the parse and don't pay the @rules_android / @rules_kotlin cost.
    # The application-side `flutter_android_app` macro depends on the hub's
    # `android/all_android_plugin_libs` aggregator, which deps on every
    # spoke's `android:lib` — so Android-targeted builds pick up all
    # plugin libraries automatically.

    if apple_macos_srcs_dirs:
        extra_targets.append("""
flutter_apple_plugin_library(
    name = "{name}_apple_macos",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "macos",
    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = _glob_block(apple_macos_srcs_dirs, _APPLE_SRC_EXTENSIONS),
            includes = repr(apple_macos_include_dirs),
        ))

    if apple_ios_srcs_dirs:
        extra_targets.append("""
flutter_apple_plugin_library(
    name = "{name}_apple_ios",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "ios",
    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = _glob_block(apple_ios_srcs_dirs, _APPLE_SRC_EXTENSIONS),
            includes = repr(apple_ios_include_dirs),
        ))

    if linux_src_dir:
        linux_srcs, linux_hdrs = _split_glob_block([linux_src_dir], _DESKTOP_C_EXTS, _DESKTOP_HDR_EXTS)
        extra_targets.append("""
flutter_linux_plugin_library(
    name = "{name}_linux",
    srcs = {srcs},
    hdrs = {hdrs},
    includes = ["linux/include"],
    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = linux_srcs,
            hdrs = linux_hdrs,
        ))

    if windows_src_dir:
        win_srcs, win_hdrs = _split_glob_block([windows_src_dir], _DESKTOP_C_EXTS, _DESKTOP_HDR_EXTS)
        extra_targets.append("""
flutter_windows_plugin_library(
    name = "{name}_windows",
    srcs = {srcs},
    hdrs = {hdrs},
    includes = ["windows/include"],
    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = win_srcs,
            hdrs = win_hdrs,
        ))

    # NB: Android sources are no longer surfaced via a top-level filegroup.
    # See `_make_android_subpackage_build_content` — the spoke's `android/`
    # sub-package wraps them in a kt_android_library that the hub's
    # aggregator (`@<hub>//android:all_android_plugin_libs`) depends on.

    if apple_macos_srcs_dirs or apple_ios_srcs_dirs:
        macos_branch = '            ":{name}_apple_macos",'.format(name = name) if apple_macos_srcs_dirs else ""
        ios_branch = '            ":{name}_apple_ios",'.format(name = name) if apple_ios_srcs_dirs else ""
        apple_libs_arg = """    apple_libs = select({{
        "@platforms//os:macos": [
{macos_branch}
        ],
        "@platforms//os:ios": [
{ios_branch}
        ],
        "//conditions:default": [],
    }}),
""".format(
            macos_branch = macos_branch,
            ios_branch = ios_branch,
        )

    if linux_src_dir:
        linux_libs_arg = '    linux_libs = [":{name}_linux"],\n'.format(name = name)

    if windows_src_dir:
        windows_libs_arg = '    windows_libs = [":{name}_windows"],\n'.format(name = name)

    # Android sources travel through a sibling `android/` sub-package
    # rather than `flutter_plugin.android_libs`. See
    # `_make_android_subpackage_build_content`.

    # Apple PrivacyInfo.xcprivacy files: thread through `apple_privacy_files`
    # on the flutter_plugin so they propagate via FlutterInfo to the platform
    # application rule, which bundles them via Resources/. Split per-platform
    # via select() so the macOS bundle never picks up iOS-only manifests
    # (and vice versa) — different platforms can declare different privacy
    # uses, and Apple's submission validator aggregates whatever it finds in
    # the per-platform bundle.
    apple_privacy_files_arg = ""
    if apple_macos_privacy_manifests or apple_ios_privacy_manifests:
        macos_lines = "\n".join(['            "{}",'.format(p) for p in apple_macos_privacy_manifests])
        ios_lines = "\n".join(['            "{}",'.format(p) for p in apple_ios_privacy_manifests])
        apple_privacy_files_arg = """    apple_privacy_files = select({{
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

    pub_attrs = _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders)

    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")
{extra_loads}
flutter_plugin(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{deps}    package_name = "{name}",
    plugin_platforms_json = {plugin_platforms_json_literal},
    language_version = "{language_version}",
{apple_libs_arg}{linux_libs_arg}{windows_libs_arg}{apple_privacy_files_arg}{pub_attrs}    visibility = ["//visibility:public"],
)
{extra_targets}
""".format(
        name = name,
        deps = deps_block,
        language_version = language_version,
        plugin_platforms_json_literal = repr(plugin_platforms_json),
        extra_loads = "\n".join(extra_loads),
        extra_targets = "\n".join(extra_targets),
        apple_libs_arg = apple_libs_arg,
        linux_libs_arg = linux_libs_arg,
        windows_libs_arg = windows_libs_arg,
        apple_privacy_files_arg = apple_privacy_files_arg,
        pub_attrs = pub_attrs,
    )

def _make_android_subpackage_build_content(
        android_src_dir,
        java_package,
        extra_maven_labels,
        android_manifest = "",
        consumer_proguard_specs = []):
    """Generate `android/BUILD.bazel` content for a Flutter plugin spoke.

    Always emits a `kt_android_library(name = "lib", ...)`. The aggregator
    in the hub's `android/all_android_plugin_libs` depends on `:lib` for
    every spoke; spokes without Android sources still contribute an empty
    library (a no-op at link time).

    Loaded lazily — Bazel only parses this file when something queries
    `@<spoke>//android:lib`. Non-Android workspaces never trigger it and
    don't pay the `@rules_android` / `@rules_kotlin` cost.

    The `_engine` target gives the plugin's Kotlin/Java source access to
    the FlutterPlugin SPI on the compile classpath. We always pin the
    engine to arm64 here: Java bytecode is ABI-independent, so the
    consumer's `flutter_android_app(android_abi = ...)` continues to
    decide the runtime engine ABI without affecting the plugin's
    compile-time classpath.

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
        java_package: The Java/Kotlin package the plugin's classes live
            in, taken from `flutter.plugin.platforms.android.package` in
            the spoke's pubspec.yaml. Used as `custom_package` on the
            `kt_android_library` so resource references and manifest
            placeholders resolve. Empty when the spoke has no Android
            sources.
        extra_maven_labels: Additional `@rules_android_maven//:...`
            labels parsed from the plugin's `build.gradle*` and translated
            via `_MAVEN_COORD_TO_LABEL`.
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

    Returns:
        Generated BUILD content as a string.
    """
    if not android_src_dir:
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

    # Source dir is relative to the package root; the sub-package itself
    # lives at `android/`, so strip that prefix.
    if android_src_dir.startswith("android/"):
        sub_src = android_src_dir[len("android/"):]
    else:
        sub_src = android_src_dir

    glob_patterns = [
        '"%s/**/*.kt"' % sub_src,
        '"%s/**/*.java"' % sub_src,
    ]

    custom_package_arg = ""
    if java_package:
        custom_package_arg = '    custom_package = "%s",\n' % java_package

    # `manifest = "..."` lets `android_binary`'s `ManifestMerger2` pick
    # up the plugin's `<activity>` / `<service>` / `<uses-permission>`
    # / etc. entries transitively — same shape AGP uses inside
    # `flutter build apk`. `exports_manifest = 1` is required because
    # rules_android's `android_library` defaults to `no` (AGP defaults
    # to yes); without it, the library's manifest is parsed for itself
    # but never contributed to the binary's merger inputs. Path is
    # relative to the `android/` sub-package, so we strip the
    # `android/` prefix the same way `sub_src` does.
    manifest_arg = ""
    if android_manifest:
        sub_manifest = android_manifest
        if sub_manifest.startswith("android/"):
            sub_manifest = sub_manifest[len("android/"):]
        manifest_arg = '    manifest = "%s",\n    exports_manifest = 1,\n' % sub_manifest

    # `proguard_specs = [...]` lets `android_binary`'s R8 step pick up
    # the plugin's keep rules transitively — same shape AGP uses for
    # `consumerProguardFiles`. The paths are relative to the `android/`
    # sub-package, which is where the spoke lives in our layout.
    proguard_specs_arg = ""
    if consumer_proguard_specs:
        spec_lines = ", ".join(['"%s"' % path for path in consumer_proguard_specs])
        proguard_specs_arg = "    proguard_specs = [%s],\n" % spec_lines

    # Base deps every plugin spoke gets: the engine for the FlutterPlugin
    # SPI, the BuildConfig stub, and the two androidx artifacts that the
    # FlutterPlugin classes themselves transitively reference. Plugin-
    # specific maven deps from `extra_maven_labels` are appended,
    # de-duped (the gradle parser may surface artifacts already in the
    # base set, e.g. lifecycle-common).
    base_labels = [
        ":_engine",
        ":_build_config",
        "@rules_android_maven//:androidx_annotation_annotation",
        "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
    ]
    seen = {label: True for label in base_labels}
    all_labels = list(base_labels)
    for lbl in extra_maven_labels:
        if lbl not in seen:
            seen[lbl] = True
            all_labels.append(lbl)
    deps_block = "\n        ".join(['"%s",' % label for label in all_labels])

    # BuildConfig.java stub — Gradle generates this implicitly per
    # plugin's namespace. rules_android does not, so we hand-emit one.
    bc_package = java_package if java_package else "_unknown"

    return """\
load("@rules_flutter//flutter:android.bzl", "flutter_android_engine")
load("@rules_java//java:java_library.bzl", "java_library")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

# Private engine target — gives the plugin's Kotlin/Java the FlutterPlugin
# SPI on the compile classpath. Always arm64 here; Java bytecode is
# ABI-independent. The consumer's flutter_android_app(android_abi=...)
# decides the runtime ABI.
flutter_android_engine(
    name = "_engine",
    visibility = ["//visibility:private"],
)

# BuildConfig.java stub. Gradle synthesizes this per Android module
# (matching `android.namespace`). rules_android doesn't, so we generate
# a minimal one — `DEBUG = false`, which is correct for release builds
# and harmless for debug (the engine ABI / mode is decided elsewhere).
genrule(
    name = "_build_config_src",
    outs = ["_build_config/{bc_package_path}/BuildConfig.java"],
    cmd = "cat > $@ <<'EOF'\\npackage {bc_package};\\npublic final class BuildConfig {{\\n  public static final boolean DEBUG = false;\\n  public static final String LIBRARY_PACKAGE_NAME = \\"{bc_package}\\";\\n  public static final String BUILD_TYPE = \\"release\\";\\n}}\\nEOF\\n",
)

java_library(
    name = "_build_config",
    srcs = [":_build_config_src"],
    visibility = ["//visibility:private"],
)

kt_android_library(
    name = "lib",
    srcs = glob([{globs}], allow_empty = True),
{custom_package}{manifest}{proguard_specs}    visibility = ["//visibility:public"],
    deps = [
        {deps}
    ],
)
""".format(
        globs = ", ".join(glob_patterns),
        custom_package = custom_package_arg,
        manifest = manifest_arg,
        proguard_specs = proguard_specs_arg,
        deps = deps_block,
        bc_package = bc_package,
        bc_package_path = bc_package.replace(".", "/"),
    )

def _resolve_overlay_template(ctx, overlay_root_label, package_name, version, relpath):
    """Look up an overlay template at `<root>/<package>/<version-ladder>/<relpath>`.

    Walks the version-specificity ladder
    `<major>.<minor>.<patch>/`, `<major>.<minor>/`, `<major>/`, bare
    `<package>/`, and returns the templated content (with `{HUB_NAME}`,
    `{PKG}`, `{VERSION}` substitutions applied) on first match. Returns
    empty string when no template is found.

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
    root = ctx.path(overlay_root_label).dirname
    pkg_dir = root.get_child(package_name)
    if not pkg_dir.exists:
        return ""

    # Build the version ladder.
    parts = version.split(".")
    candidates = []
    if len(parts) >= 3:
        candidates.append("{}.{}.{}".format(parts[0], parts[1], parts[2]))
    if len(parts) >= 2:
        candidates.append("{}.{}".format(parts[0], parts[1]))
    if len(parts) >= 1:
        candidates.append(parts[0])
    candidates.append("")  # bare <pkg>/<relpath>

    relpath_parts = relpath.split("/")
    for candidate in candidates:
        tpl = pkg_dir.get_child(candidate) if candidate else pkg_dir
        for part in relpath_parts:
            tpl = tpl.get_child(part)
        if tpl.exists:
            content = ctx.read(tpl)
            return content.replace("{HUB_NAME}", ctx.attr.hub_name).replace(
                "{PKG}",
                package_name,
            ).replace("{VERSION}", version)
    return ""

def _resolve_overlay(ctx, overlay_root_label, package_name, version):
    """Resolve the top-level BUILD.bazel.tpl overlay (back-compat shim).

    Equivalent to `_resolve_overlay_template(..., "BUILD.bazel.tpl")`.
    Kept as a separate helper because the top-level lookup is the most
    common call shape; consumers wanting the Android sub-package
    template call `_resolve_overlay_template` directly.
    """
    return _resolve_overlay_template(ctx, overlay_root_label, package_name, version, "BUILD.bazel.tpl")

def _flutter_pub_package_impl(ctx):
    url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
        base = ctx.attr.base_url,
        name = ctx.attr.package_name,
        version = ctx.attr.version,
    )

    # Match `pub_lock_package`'s download/extract semantics, including the
    # `tar -xzf` workaround for archives with trailing-garbage gzip streams.
    ctx.download(
        url = url,
        output = "_archive.tar.gz",
        sha256 = ctx.attr.sha256 if ctx.attr.sha256 else "",
    )
    extract = ctx.execute(["tar", "-xzf", "_archive.tar.gz"])
    if extract.return_code != 0:
        fail("tar -xzf failed for {url}:\nstdout: {out}\nstderr: {err}".format(
            url = url,
            out = extract.stdout,
            err = extract.stderr,
        ))
    ctx.delete("_archive.tar.gz")

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

    # Build full label strings for sibling spoke repos.
    dep_labels = [
        "@{hub}__{dep}//:{dep}".format(hub = ctx.attr.hub_name, dep = dep)
        for dep in bazel_deps
    ]

    # If the pubspec declares `uses-material-design: true`, the spoke
    # depends on @rules_flutter//flutter:material_icons so the bundled
    # font travels through the deps graph automatically — same channel
    # any other pub package's font flows through. Cross-package mismatch
    # (app says false, pub dep says true) becomes structurally impossible.
    if asset_block.uses_material_design:
        dep_labels = dep_labels + ["@rules_flutter//flutter:material_icons"]

    # Pre-compute the pub-asset attr inputs once. Used by either branch
    # below (plugin vs library).
    fonts_json_str = _encode_fonts_json(asset_block.fonts)
    font_files = _build_font_files_dict(asset_block.fonts)
    pkg_assets_dict = _build_pkg_assets_dict(ctx, asset_block.assets)
    pkg_shaders_dict = _build_pkg_shaders_dict(asset_block.shaders)
    has_asset_contributions = (
        bool(asset_block.fonts) or bool(asset_block.assets) or bool(asset_block.shaders)
    )

    # Try overlays first (user-supplied roots win over the bundled
    # `@rules_flutter//ext/` tree). On match, the overlay replaces
    # auto-generation entirely; the user takes responsibility for the
    # spoke's BUILD content.
    overlay_content = ""
    overlay_android_content = ""
    for overlay_label in ctx.attr.overlay_roots:
        overlay_content = _resolve_overlay(
            ctx,
            overlay_label,
            ctx.attr.package_name,
            ctx.attr.version,
        )
        if overlay_content:
            # Look up the matching `android/BUILD.bazel.tpl` from the same
            # overlay root. Plugins whose Android side has real sources
            # ship one alongside the top-level BUILD; plugins that don't
            # leave it absent and the empty-stub fallback fires below.
            overlay_android_content = _resolve_overlay_template(
                ctx,
                overlay_label,
                ctx.attr.package_name,
                ctx.attr.version,
                "android/BUILD.bazel.tpl",
            )
            break

    if overlay_content:
        ctx.file("BUILD.bazel", overlay_content)

        # When the overlay ships an `android/BUILD.bazel.tpl`, use it
        # verbatim. Otherwise emit an empty stub so the hub's
        # `android/all_android_plugin_libs` aggregator can depend on
        # `@<spoke>//android:lib` uniformly across overlay-and-no-Android
        # plugins (audio_session declares Android sources and ships the
        # full sub-package; objective_c is pure Apple and gets the stub).
        if overlay_android_content:
            ctx.file("android/BUILD.bazel", overlay_android_content)
        else:
            ctx.file(
                "android/BUILD.bazel",
                _make_android_subpackage_build_content(
                    android_src_dir = "",
                    java_package = "",
                    extra_maven_labels = [],
                ),
            )
        return

    if plugin_block.present:
        # Detect Apple sources per platform when pluginClass is set.
        apple_macos_srcs_dirs = []
        apple_ios_srcs_dirs = []

        macos_info = plugin_block.platforms.get("macos", {})
        ios_info = plugin_block.platforms.get("ios", {})
        linux_info = plugin_block.platforms.get("linux", {})
        windows_info = plugin_block.platforms.get("windows", {})

        macos_shared_darwin = macos_info.get("sharedDarwinSource", False) if macos_info else False
        ios_shared_darwin = ios_info.get("sharedDarwinSource", False) if ios_info else False

        apple_macos_include_dirs = []
        apple_ios_include_dirs = []
        apple_macos_privacy_manifests = []
        apple_ios_privacy_manifests = []

        if macos_info and macos_info.get("pluginClass", ""):
            apple_macos_srcs_dirs = _detect_apple_source_dirs(
                ctx,
                ctx.attr.package_name,
                "macos",
                macos_shared_darwin,
            )
            apple_macos_include_dirs = _detect_apple_include_dirs(
                ctx,
                apple_macos_srcs_dirs,
                ctx.attr.package_name,
            )
            apple_macos_privacy_manifests = _detect_apple_privacy_manifests(
                ctx,
                apple_macos_srcs_dirs,
            )

        if ios_info and ios_info.get("pluginClass", ""):
            apple_ios_srcs_dirs = _detect_apple_source_dirs(
                ctx,
                ctx.attr.package_name,
                "ios",
                ios_shared_darwin,
            )
            apple_ios_include_dirs = _detect_apple_include_dirs(
                ctx,
                apple_ios_srcs_dirs,
                ctx.attr.package_name,
            )
            apple_ios_privacy_manifests = _detect_apple_privacy_manifests(
                ctx,
                apple_ios_srcs_dirs,
            )

        # Linux/Windows desktop sources: scan whenever pluginClass is
        # set on that platform. The plugin's own `linux/`/`windows/`
        # directory is the canonical location.
        linux_src_dir = ""
        windows_src_dir = ""
        if linux_info and linux_info.get("pluginClass", ""):
            linux_src_dir = _detect_desktop_source_dir(ctx, "linux")
        if windows_info and windows_info.get("pluginClass", ""):
            windows_src_dir = _detect_desktop_source_dir(ctx, "windows")

        # Android sources: scan when pluginClass is set on android.
        android_info = plugin_block.platforms.get("android", {})
        android_src_dir = ""
        android_java_package = ""
        android_extra_maven_labels = []
        android_manifest = ""
        android_consumer_proguard_specs = []
        android_native_build = False
        if android_info:
            android_native_build = _detect_android_native_build(ctx)
        if android_info and android_info.get("pluginClass", ""):
            android_src_dir = _detect_android_source_dir(ctx)
            android_java_package = android_info.get("package", "") or ""
            if android_src_dir:
                android_extra_maven_labels = _resolve_plugin_maven_deps(ctx)
                android_manifest = _detect_android_manifest(ctx)
                android_consumer_proguard_specs = _detect_consumer_proguard_specs(ctx)

        plugin_platforms_json = json.encode(plugin_block.platforms)
        build_content = _make_flutter_plugin_build_content(
            name = ctx.attr.package_name,
            deps = dep_labels,
            language_version = language_version,
            plugin_platforms_json = plugin_platforms_json,
            apple_macos_srcs_dirs = apple_macos_srcs_dirs,
            apple_ios_srcs_dirs = apple_ios_srcs_dirs,
            apple_macos_include_dirs = apple_macos_include_dirs,
            apple_ios_include_dirs = apple_ios_include_dirs,
            apple_macos_privacy_manifests = apple_macos_privacy_manifests,
            apple_ios_privacy_manifests = apple_ios_privacy_manifests,
            linux_src_dir = linux_src_dir,
            windows_src_dir = windows_src_dir,
            fonts_json_str = fonts_json_str,
            font_files = font_files,
            pkg_assets = pkg_assets_dict,
            pkg_shaders = pkg_shaders_dict,
        )
    elif has_asset_contributions:
        # No plugin block, but the pubspec has flutter.fonts/assets/shaders.
        # Emit a flutter_library (rather than dart_library) so the metadata
        # propagates via FlutterInfo.pub_fonts/pub_assets/pub_shaders to the
        # consuming app's bundle aggregator.
        build_content = _make_flutter_library_build_content(
            name = ctx.attr.package_name,
            deps = dep_labels,
            language_version = language_version,
            fonts_json_str = fonts_json_str,
            font_files = font_files,
            pkg_assets = pkg_assets_dict,
            pkg_shaders = pkg_shaders_dict,
        )
        android_src_dir = ""
        android_java_package = ""
        android_extra_maven_labels = []
        android_manifest = ""
        android_consumer_proguard_specs = []
        android_native_build = False
    else:
        build_content = make_dart_library_build_content(
            name = ctx.attr.package_name,
            deps = dep_labels,
            language_version = language_version,
        )
        android_src_dir = ""
        android_java_package = ""
        android_extra_maven_labels = []
        android_manifest = ""
        android_consumer_proguard_specs = []
        android_native_build = False

    ctx.file("BUILD.bazel", build_content)

    # Always emit `android/BUILD.bazel`. Bazel only loads it when something
    # queries `@<spoke>//android:lib`, so non-Android workspaces don't pay
    # the @rules_android / @rules_kotlin cost. Plugins whose Gradle build
    # compiles native Android code that autogen cannot translate get a
    # load-time fail() here instead — Android builds break loudly rather
    # than shipping an APK missing the library.
    if android_native_build:
        android_build_content = _make_android_native_build_unsupported_content(
            ctx.attr.package_name,
            ctx.attr.version,
        )
    else:
        android_build_content = _make_android_subpackage_build_content(
            android_src_dir = android_src_dir,
            java_package = android_java_package,
            extra_maven_labels = android_extra_maven_labels,
            android_manifest = android_manifest,
            consumer_proguard_specs = android_consumer_proguard_specs,
        )
    ctx.file("android/BUILD.bazel", android_build_content)

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
            doc = "SHA256 hash of the package archive.",
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
