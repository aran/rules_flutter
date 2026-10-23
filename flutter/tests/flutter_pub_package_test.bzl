"""Unit tests for flutter_pub_package.bzl's generated Android sub-package.

The fixture shapes mirror real pub.dev plugins:

* `record_android` 1.5.1 — Kotlin sources, `android/src/main/res/`
  resources referenced as `R.drawable.ic_mic`, a library manifest
  declaring RECORD_AUDIO, a `build.gradle` with a `namespace` and **no**
  dependencies block (androidx arrives via the Flutter embedding's
  compile classpath, exactly as in Gradle builds).
* `url_launcher_android` — Kotlin sources, no resources, gradle deps.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "apply_overlay_substitutions",
    "find_hardcoded_hub_dep",
    "find_hardcoded_language_version",
    "is_java_package_name",
    "is_maven_dep_label",
    "make_android_subpackage_build_content",
    "make_flutter_library_build_content",
    "make_flutter_plugin_build_content",
    "maven_labels_for_gradle",
    "parse_android_manifest_package",
    "parse_gradle_android_namespace",
    "render_overlay_deps",
    "resolve_overlay",
    "resolve_overlay_roots",
    "resolve_overlay_template",
)
load("//flutter/private:gradle.bzl", "gradle_android_namespaces", "gradle_build_file_choice", "gradle_collect_files", "gradle_scan_namespaces", "gradle_scan_native", "gradle_scan_proguard")
load("//flutter/private:starlark_literal.bzl", "starlark_string_literal")

# Verbatim shape of record_android 1.5.1's android/build.gradle (trimmed):
# Groovy DSL, namespace assignment, no dependencies block at all.
_RECORD_ANDROID_GRADLE = """\
group 'com.llfbandit.record'
version '1.0'

apply plugin: 'com.android.library'
apply plugin: 'kotlin-android'

android {
    namespace = 'com.llfbandit.record'

    compileSdk = flutter.compileSdkVersion

    sourceSets {
        main.java.srcDirs += 'src/main/kotlin'
    }

    defaultConfig {
        minSdk = 23
    }
}
"""

_GRADLE_KTS_NAMESPACE = """\
android {
    namespace = "dev.example.kts_plugin"
}
"""

# Legacy (pre-AGP-8) Groovy namespace method-call syntax, no `=`.
_GRADLE_GROOVY_NAMESPACE_NO_ASSIGN = """\
android {
    namespace 'dev.example.legacy'
}
"""

_RECORD_ANDROID_MANIFEST = """\
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
  package="com.llfbandit.record">

    <uses-permission android:name="android.permission.RECORD_AUDIO" />
</manifest>
"""

_MANIFEST_NO_PACKAGE = """\
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
</manifest>
"""

def _parse_gradle_android_namespace_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "com.llfbandit.record",
        parse_gradle_android_namespace(_RECORD_ANDROID_GRADLE),
    )
    asserts.equals(
        env,
        "dev.example.kts_plugin",
        parse_gradle_android_namespace(_GRADLE_KTS_NAMESPACE),
    )
    asserts.equals(
        env,
        "dev.example.legacy",
        parse_gradle_android_namespace(_GRADLE_GROOVY_NAMESPACE_NO_ASSIGN),
    )
    asserts.equals(env, "", parse_gradle_android_namespace("android {}\n"))

    return unittest.end(env)

parse_gradle_android_namespace_test = unittest.make(_parse_gradle_android_namespace_test_impl)

def _parse_android_manifest_package_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "com.llfbandit.record",
        parse_android_manifest_package(_RECORD_ANDROID_MANIFEST),
    )
    asserts.equals(env, "", parse_android_manifest_package(_MANIFEST_NO_PACKAGE))
    asserts.equals(env, "", parse_android_manifest_package("not xml"))

    return unittest.end(env)

parse_android_manifest_package_test = unittest.make(_parse_android_manifest_package_test_impl)

def _record_android_subpackage_test_impl(ctx):
    """record_android shape: Kotlin + res/ + manifest + dep-less gradle."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "com.llfbandit.record",
        extra_maven_labels = [],
        android_manifest = "android/src/main/AndroidManifest.xml",
        has_resources = True,
    )

    # Resources must be compiled into the library so R.drawable.* resolves
    # and the drawables merge into the consuming APK.
    asserts.true(
        env,
        'resource_files = glob(["src/main/res/**"], allow_empty = False)' in content,
        "expected resource_files glob in:\n" + content,
    )

    # The R class (and BuildConfig) must be generated against the plugin's
    # own namespace.
    asserts.true(
        env,
        'custom_package = "com.llfbandit.record"' in content,
        "expected custom_package in:\n" + content,
    )
    asserts.true(
        env,
        "_build_config/com/llfbandit/record/BuildConfig.java" in content,
        "expected BuildConfig against the plugin namespace in:\n" + content,
    )
    asserts.true(
        env,
        'load("@bazel_skylib//rules:write_file.bzl", "write_file")' in content,
        content,
    )
    asserts.true(env, "write_file(\n    name = \"_build_config_src\"," in content, content)
    asserts.false(env, "genrule" in content, content)
    asserts.false(env, "cat >" in content, content)

    # The plugin's own manifest is used (RECORD_AUDIO merges into the APK).
    asserts.true(
        env,
        'manifest = "src/main/AndroidManifest.xml"' in content,
        "expected plugin manifest in:\n" + content,
    )
    asserts.true(env, "exports_manifest = 1" in content, content)

    # The androidx compile baseline comes from the engine target's exports
    # (mirroring the Flutter embedding POM), not from a per-plugin list —
    # a dep-less build.gradle still compiles against NotificationCompat etc.
    asserts.true(env, '":_engine",' in content, content)
    asserts.false(
        env,
        "@rules_android_maven//:androidx" in content,
        "androidx deps must flow via the engine's exports, not be " +
        "restated per plugin:\n" + content,
    )

    return unittest.end(env)

record_android_subpackage_test = unittest.make(_record_android_subpackage_test_impl)

def _resources_without_manifest_test_impl(ctx):
    """Resources force a manifest: synthesize one when the plugin ships none."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "dev.example.res_only_manifestless",
        extra_maven_labels = [],
        android_manifest = "",
        has_resources = True,
    )

    asserts.true(
        env,
        'resource_files = glob(["src/main/res/**"], allow_empty = False)' in content,
        content,
    )

    # rules_android requires a manifest whenever resource_files is set;
    # AGP treats a missing library manifest as an empty one, so we
    # synthesize the equivalent.
    asserts.true(env, 'manifest = ":_manifest"' in content, content)
    asserts.true(env, "write_file(\n    name = \"_manifest\"," in content, content)
    asserts.true(
        env,
        'package=\\"dev.example.res_only_manifestless\\"' in content,
        content,
    )
    asserts.false(env, "exports_manifest" in content, content)
    asserts.false(env, "genrule" in content, content)
    asserts.false(env, "cat >" in content, content)

    return unittest.end(env)

resources_without_manifest_test = unittest.make(_resources_without_manifest_test_impl)

def _no_resources_subpackage_test_impl(ctx):
    """url_launcher_android shape: sources + manifest, no res/."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "io.flutter.plugins.urllauncher",
        extra_maven_labels = ["@rules_android_maven//:androidx_browser_browser"],
        android_manifest = "android/src/main/AndroidManifest.xml",
        has_resources = False,
    )

    asserts.false(env, "resource_files" in content, content)
    asserts.true(
        env,
        '"@rules_android_maven//:androidx_browser_browser",' in content,
        "gradle-declared deps must still be wired:\n" + content,
    )

    return unittest.end(env)

no_resources_subpackage_test = unittest.make(_no_resources_subpackage_test_impl)

def _empty_subpackage_test_impl(ctx):
    """No Android sources and no resources → the empty aggregator stub."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "",
        java_package = "",
        extra_maven_labels = [],
    )

    asserts.true(env, "srcs = []" in content, content)
    asserts.false(env, "resource_files" in content, content)
    asserts.false(env, "flutter_android_engine" in content, content)

    return unittest.end(env)

empty_subpackage_test = unittest.make(_empty_subpackage_test_impl)

# The non-Dart remainder of `lib/` — the same partition rules_dart's
# `make_dart_library_build_content` emits. `srcs + resources = lib/**`
# for every spoke, whichever generator ran; a published package's `lib/`
# is addressable as `package:<name>/<path>` whatever the extension, so a
# spoke that keeps only `*.dart` is a package with pieces missing.
_RESOURCES_GLOB = """    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),"""

def _spokes_state_their_resolved_version_test_impl(ctx):
    """Every Flutter spoke shape emits the version pub resolved it at.

    The attribute has one use: when a single package name arrives from two
    hubs, two records stating different versions fail the build instead of the
    first silently standing in for the second. A spoke that omits it is
    invisible to that check, because an unstated version never conflicts — so
    "the value reached the generated BUILD file" is the whole contract, and
    it has to hold for the plugin and library shapes as well as the plain
    `dart_library` one rules_dart emits.

    `e2e/dual_hub` is the other half of this: it pins that two spokes stating
    *different* versions actually fail a build that collects both.
    """
    env = unittest.begin(ctx)

    plugin = make_flutter_plugin_build_content(
        name = "sqlite3_web",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        plugin_platforms_json = '{"web":{"pluginClass":"WebPlugin"}}',
        apple_macos_srcs_dirs = [],
        apple_ios_srcs_dirs = [],
        apple_macos_include_dirs = [],
        apple_ios_include_dirs = [],
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
        version = "2.2.0",
    )
    asserts.true(env, '\n    version = "2.2.0",' in plugin, plugin)

    library = make_flutter_library_build_content(
        name = "cupertino_icons",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {},
        pkg_shaders = {},
        version = "1.0.8",
    )
    asserts.true(env, '\n    version = "1.0.8",' in library, library)

    return unittest.end(env)

spokes_state_their_resolved_version_test = unittest.make(
    _spokes_state_their_resolved_version_test_impl,
)

def _spoke_without_a_version_states_none_test_impl(ctx):
    """An unknown version emits no attribute rather than an empty one.

    `version = ""` and no `version` at all mean the same thing to the
    agreement check — neither conflicts with anything — so the line is omitted
    rather than written blank, matching what rules_dart's own spoke generator
    does. A spoke that wrote `version = ""` would read as a package asserting
    it has no version, which is not what "we could not resolve one" means.
    """
    env = unittest.begin(ctx)

    library = make_flutter_library_build_content(
        name = "cupertino_icons",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {},
        pkg_shaders = {},
    )

    # The newline and indent matter: a bare `"version = "` also matches
    # `language_version = `, which every spoke states and which this is not
    # about.
    asserts.false(env, "\n    version = " in library, library)

    return unittest.end(env)

spoke_without_a_version_states_none_test = unittest.make(
    _spoke_without_a_version_states_none_test_impl,
)

def _plugin_spoke_carries_resources_test_impl(ctx):
    """A plugin spoke's BUILD partitions lib/ into srcs + resources."""
    env = unittest.begin(ctx)

    content = make_flutter_plugin_build_content(
        name = "sqlite3_web",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        plugin_platforms_json = '{"web":{"pluginClass":"WebPlugin"}}',
        apple_macos_srcs_dirs = [],
        apple_ios_srcs_dirs = [],
        apple_macos_include_dirs = [],
        apple_ios_include_dirs = [],
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
    )

    asserts.true(env, _RESOURCES_GLOB in content, content)

    return unittest.end(env)

plugin_spoke_carries_resources_test = unittest.make(_plugin_spoke_carries_resources_test_impl)

def _library_spoke_carries_resources_test_impl(ctx):
    """A flutter_library spoke keeps lib/'s non-Dart remainder alongside its declared assets.

    The two channels coexist by design: `resources` says the file is part
    of the package's `lib/` tree (staged wherever the whole package is),
    while `pkg_assets`/`pkg_shaders` say it is bundled into flutter_assets.
    A shader under `lib/` is legitimately both.
    """
    env = unittest.begin(ctx)

    content = make_flutter_library_build_content(
        name = "shader_pkg",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {},
        pkg_shaders = {":lib/glow.frag": "lib/glow.frag"},
    )

    asserts.true(env, _RESOURCES_GLOB in content, content)
    asserts.true(env, "pkg_shaders" in content, content)

    return unittest.end(env)

library_spoke_carries_resources_test = unittest.make(_library_spoke_carries_resources_test_impl)

def _spoke_with_shaders_declares_their_includes_test_impl(ctx):
    """A spoke with shaders lists its GLSL as what they may `#include`.

    The compile runs sandboxed with only declared inputs, so a shader that
    includes a sibling `.glsl` fails unless the spoke declares it. The globs
    stay scoped to the declared shaders' own directories: a package-wide
    `**` glob would also match `example/build/` output when a path package
    is symlinked into its spoke.
    """
    env = unittest.begin(ctx)

    def content(pkg_shaders):
        return make_flutter_library_build_content(
            name = "shader_pkg",
            deps = [],
            language_version = "3.4",
            code_assets = [],
            has_unreplaced_hook = "",
            fonts_json_str = "",
            font_files = {},
            pkg_assets = {},
            pkg_shaders = pkg_shaders,
        )

    with_shaders = content({":shaders/glow.frag": "shaders/glow.frag"})
    asserts.true(env, "shader_includes = glob(" in with_shaders, with_shaders)
    asserts.true(env, '"shaders/**/*.glsl"' in with_shaders, with_shaders)
    asserts.true(env, '"shaders/**/*.frag"' in with_shaders, with_shaders)
    asserts.true(env, '"shaders/**/*.vert"' in with_shaders, with_shaders)
    asserts.false(env, '"**/*.glsl"' in with_shaders, with_shaders)
    top_level = content({":ripple.frag": "ripple.frag"})
    asserts.true(env, '"*.glsl"' in top_level, top_level)
    asserts.false(env, "shader_includes" in content({}))

    return unittest.end(env)

spoke_with_shaders_declares_their_includes_test = unittest.make(_spoke_with_shaders_declares_their_includes_test_impl)

def _overlay_substitutes_the_language_version_test_impl(ctx):
    """An overlay declares the language version by placeholder, never by value.

    The package's own `environment.sdk` is the single source of truth; the
    spoke derives from it and substitutes here. A template that spelled the
    version out would be a second declaration of the same fact, and the
    version ladder makes the two drift silently: `ext/objective_c/9/` matches
    every 9.x, so a release that raises the SDK floor keeps the stale literal.
    """
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = 'flutter_plugin(name = "{PKG}", language_version = "{LANGUAGE_VERSION}", v = "{VERSION}", h = "{HUB_NAME}")',
        hub_name = "hub",
        package_name = "objective_c",
        version = "9.3.0",
        language_version = "3.10",
        deps = "",
    )

    asserts.equals(
        env,
        'flutter_plugin(name = "objective_c", language_version = "3.10", v = "9.3.0", h = "hub")',
        rendered,
    )

    return unittest.end(env)

def _overlay_without_a_language_version_is_left_alone_test_impl(ctx):
    """Not every overlay declares one; substitution must not invent the attribute."""
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = 'cc_library(name = "{PKG}")',
        hub_name = "hub",
        package_name = "jni",
        version = "1.0.0",
        language_version = "3.3",
        deps = "",
    )

    asserts.equals(env, 'cc_library(name = "jni")', rendered)

    return unittest.end(env)

def _hardcoded_language_version_is_rejected_test_impl(ctx):
    """A literal version in an overlay is caught, not silently obeyed.

    Substitution alone only *permits* a single declaration; this is what
    makes a second one impossible. Without it an overlay could keep spelling
    the version out and quietly win over the derived value, which is the
    state this check was written to end.
    """
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "3.3",
        find_hardcoded_language_version('flutter_plugin(\n    language_version = "3.3",\n)'),
    )

    # Whitespace around `=` is a style choice buildifier can change; the
    # check must not be evadable by reformatting.
    asserts.equals(
        env,
        "3.10",
        find_hardcoded_language_version('    language_version="3.10",'),
    )

    # The placeholder is the one accepted spelling.
    asserts.equals(
        env,
        "",
        find_hardcoded_language_version('    language_version = "{LANGUAGE_VERSION}",'),
    )

    # An overlay that declares none is fine.
    asserts.equals(env, "", find_hardcoded_language_version('cc_library(name = "x")'))

    return unittest.end(env)

hardcoded_language_version_is_rejected_test = unittest.make(
    _hardcoded_language_version_is_rejected_test_impl,
)

overlay_substitutes_the_language_version_test = unittest.make(
    _overlay_substitutes_the_language_version_test_impl,
)
overlay_without_a_language_version_is_left_alone_test = unittest.make(
    _overlay_without_a_language_version_is_left_alone_test_impl,
)

def _overlay_substitutes_the_dependencies_test_impl(ctx):
    """An overlay names its dependencies by placeholder, never by hand.

    The package's own pubspec is the single source of truth; the spoke
    intersects it with the lock and substitutes the labels here. The rendered
    body carries the eight-space indent a `deps = [` block sits at, so the
    substituted BUILD file is buildifier-clean.
    """
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = "flutter_plugin(\n    deps = [\n        {DEPS}\n    ],\n)",
        hub_name = "hub",
        package_name = "objective_c",
        version = "9.6.0",
        language_version = "3.10",
        deps = render_overlay_deps([
            "@hub__ffi//:ffi",
            "@hub__meta//:meta",
        ]),
    )

    asserts.equals(
        env,
        'flutter_plugin(\n    deps = [\n        "@hub__ffi//:ffi",\n        "@hub__meta//:meta",\n    ],\n)',
        rendered,
    )

    # A package with no in-lock dependencies renders an empty list, not a
    # dangling comma or a missing attribute.
    asserts.equals(env, "", render_overlay_deps([]))

    return unittest.end(env)

def _hardcoded_overlay_dependency_is_rejected_test_impl(ctx):
    """A hand-written sibling label in an overlay is caught, not obeyed.

    This is the check that would have caught the `objective_c` break:
    9.5.0 dropped `native_toolchain_c` from its `dependencies`, so the lock
    stopped carrying it and the hub stopped creating the spoke, while
    `ext/objective_c/9/` — one directory for the whole major — kept asking
    for `@<hub>__native_toolchain_c`. The build died on an unknown repo
    naming neither `objective_c` nor the overlay that referenced it.
    """
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "@{HUB_NAME}__native_toolchain_c//:native_toolchain_c",
        find_hardcoded_hub_dep(
            '    deps = [\n        "@{HUB_NAME}__native_toolchain_c//:native_toolchain_c",\n    ],',
        ),
    )

    # The placeholder is the one accepted spelling.
    asserts.equals(env, "", find_hardcoded_hub_dep("    deps = [\n        {DEPS}\n    ],"))

    # Naming {HUB_NAME} outside a spoke label — a doc comment, say — is not
    # the thing being prohibited.
    asserts.equals(env, "", find_hardcoded_hub_dep("# {HUB_NAME} is substituted here."))

    # A label pointing at another repo entirely stays allowed: only sibling
    # spokes are derivable from the pubspec.
    asserts.equals(
        env,
        "",
        find_hardcoded_hub_dep('    deps = ["@rules_flutter//flutter:material_icons"],'),
    )

    return unittest.end(env)

overlay_substitutes_the_dependencies_test = unittest.make(
    _overlay_substitutes_the_dependencies_test_impl,
)
hardcoded_overlay_dependency_is_rejected_test = unittest.make(
    _hardcoded_overlay_dependency_is_rejected_test_impl,
)

def _make_mock_overlay_ctx(files, root_anchors = None, hub_name = "deps"):
    """Construct a fake repository_ctx recording ctx.watch and ctx.read calls.

    Args:
        files: Dict mapping absolute path string -> file content string.
        root_anchors: Optional dict mapping anchor label string -> absolute
            anchor file path. Defaults to `{"//plugin_overlays:BUILD.bazel":
            "/workspace/plugin_overlays/BUILD.bazel"}`.
        hub_name: Value for `ctx.attr.hub_name`.

    Returns:
        A struct with `.ctx`, `.watched` (list of watched path strings), and
        `.probed` (list of all path strings constructed via `get_child`).
    """
    anchors = root_anchors if root_anchors != None else {
        "//plugin_overlays:BUILD.bazel": "/workspace/plugin_overlays/BUILD.bazel",
    }
    existing_paths = {}
    for anchor_path in anchors.values():
        existing_paths[anchor_path] = True
        parent = anchor_path.rsplit("/", 1)[0] if "/" in anchor_path else ""
        if parent:
            existing_paths[parent] = True
    for file_path in files.keys():
        existing_paths[file_path] = True
        parts = file_path.split("/")
        for i in range(1, len(parts)):
            prefix = "/".join(parts[:i])
            if prefix:
                existing_paths[prefix] = True

    watched = []
    probed = []

    def _make_path(path_str):
        parent_str = path_str.rsplit("/", 1)[0] if "/" in path_str else ""

        def _get_child(segment):
            child_str = path_str + "/" + segment
            probed.append(child_str)
            return _make_path(child_str)

        return struct(
            path = path_str,
            exists = path_str in existing_paths,
            dirname = struct(
                path = parent_str,
                exists = parent_str in existing_paths,
                get_child = lambda seg: _get_child_from(parent_str, seg),
            ) if parent_str else None,
            get_child = _get_child,
        )

    def _get_child_from(base_str, segment):
        child_str = base_str + "/" + segment
        probed.append(child_str)
        return _make_path(child_str)

    def _path(label_or_str):
        key = str(label_or_str)
        resolved = anchors.get(key, key)
        return _make_path(resolved)

    def _watch(path_obj):
        p = path_obj.path if hasattr(path_obj, "path") else str(path_obj)
        watched.append(p)

    def _read(path_obj):
        p = path_obj.path if hasattr(path_obj, "path") else str(path_obj)
        if p not in files:
            fail("mock ctx.read on missing file: " + p)
        return files[p]

    return struct(
        ctx = struct(
            attr = struct(hub_name = hub_name),
            path = _path,
            watch = _watch,
            read = _read,
        ),
        watched = watched,
        probed = probed,
    )

def _overlay_watches_missing_package_and_candidates_test_impl(ctx):
    """Probing an overlay root with no matching package watches the package dir and all version candidates.

    Without `ctx.watch` on the probed paths, adding `<root>/<pkg>/<ver>/BUILD.bazel.tpl`
    after `@<hub>__<pkg>` has been fetched once leaves the spoke repository stale
    on incremental builds.
    """
    env = unittest.begin(ctx)

    mock = _make_mock_overlay_ctx(files = {})
    rendered = resolve_overlay(
        mock.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        ["@deps__meta//:meta"],
    )

    asserts.equals(env, "", rendered)
    asserts.equals(
        env,
        [
            "/workspace/plugin_overlays/BUILD.bazel",
            "/workspace/plugin_overlays",
            "/workspace/plugin_overlays/audio_session",
            "/workspace/plugin_overlays/audio_session/0.1.21",
            "/workspace/plugin_overlays/audio_session/0.1.21/BUILD.bazel.tpl",
            "/workspace/plugin_overlays/audio_session/0.1",
            "/workspace/plugin_overlays/audio_session/0.1/BUILD.bazel.tpl",
            "/workspace/plugin_overlays/audio_session/0",
            "/workspace/plugin_overlays/audio_session/0/BUILD.bazel.tpl",
            "/workspace/plugin_overlays/audio_session/BUILD.bazel.tpl",
        ],
        mock.watched,
    )
    for p in mock.probed:
        asserts.true(
            env,
            p in mock.watched,
            "probed path %s must be watched by ctx.watch, got watched=%s" % (p, mock.watched),
        )

    return unittest.end(env)

overlay_watches_missing_package_and_candidates_test = unittest.make(
    _overlay_watches_missing_package_and_candidates_test_impl,
)

def _overlay_watches_more_specific_version_candidates_test_impl(ctx):
    """Matching `<major>/BUILD.bazel.tpl` still watches `<major>.<minor>.<patch>` and `<major>.<minor>`.

    When a user drops a more specific `<major>.<minor>.<patch>/BUILD.bazel.tpl`
    override alongside an existing `<major>/BUILD.bazel.tpl`, Bazel only
    invalidates the spoke if the higher-precedence candidate paths were watched
    during the initial lookup.
    """
    env = unittest.begin(ctx)

    files = {
        "/workspace/plugin_overlays/audio_session/0/BUILD.bazel.tpl": (
            'flutter_plugin(name = "{PKG}", version = "{VERSION}", language_version = "{LANGUAGE_VERSION}", deps = [\n        {DEPS}\n    ]) # major'
        ),
    }
    mock1 = _make_mock_overlay_ctx(files = files)
    rendered1 = resolve_overlay(
        mock1.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        ["@deps__meta//:meta"],
    )
    asserts.true(env, "# major" in rendered1, rendered1)
    asserts.true(
        env,
        "/workspace/plugin_overlays/audio_session/0.1.21/BUILD.bazel.tpl" in mock1.watched,
        "patch candidate must be watched so a later override invalidates the spoke: %s" % mock1.watched,
    )
    asserts.true(
        env,
        "/workspace/plugin_overlays/audio_session/0.1/BUILD.bazel.tpl" in mock1.watched,
        "minor candidate must be watched so a later override invalidates the spoke: %s" % mock1.watched,
    )
    asserts.true(
        env,
        "/workspace/plugin_overlays/audio_session/0/BUILD.bazel.tpl" in mock1.watched,
        "matched major candidate must be watched: %s" % mock1.watched,
    )

    # Simulate adding the patch-specific override on an incremental build: the
    # newly added path must have been in mock1.watched, and re-running resolves
    # the patch-specific template.
    patch_tpl = "/workspace/plugin_overlays/audio_session/0.1.21/BUILD.bazel.tpl"
    asserts.true(env, patch_tpl in mock1.watched)
    files_after = dict(files)
    files_after[patch_tpl] = (
        'flutter_plugin(name = "{PKG}", version = "{VERSION}", language_version = "{LANGUAGE_VERSION}", deps = [\n        {DEPS}\n    ]) # patch'
    )
    mock2 = _make_mock_overlay_ctx(files = files_after)
    rendered2 = resolve_overlay(
        mock2.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        ["@deps__meta//:meta"],
    )
    asserts.true(env, "# patch" in rendered2, rendered2)

    return unittest.end(env)

overlay_watches_more_specific_version_candidates_test = unittest.make(
    _overlay_watches_more_specific_version_candidates_test_impl,
)

def _overlay_watches_android_subpackage_candidates_test_impl(ctx):
    """Looking up `android/BUILD.bazel.tpl` watches all candidate paths along the version ladder.

    When a top-level overlay is present without an `android/BUILD.bazel.tpl`,
    the spoke emits an empty stub `android/BUILD.bazel`. If the user later adds
    `<root>/<pkg>/<ver>/android/BUILD.bazel.tpl` (or upgrades it to a more
    specific version), the spoke must re-evaluate on incremental builds.
    """
    env = unittest.begin(ctx)

    files = {
        "/workspace/plugin_overlays/audio_session/0/BUILD.bazel.tpl": (
            'flutter_plugin(name = "{PKG}", language_version = "{LANGUAGE_VERSION}")'
        ),
    }
    mock1 = _make_mock_overlay_ctx(files = files)
    android1 = resolve_overlay_template(
        mock1.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        [],
        "android/BUILD.bazel.tpl",
    )
    asserts.equals(env, "", android1)
    for expected in [
        "/workspace/plugin_overlays/audio_session/0.1.21/android",
        "/workspace/plugin_overlays/audio_session/0.1.21/android/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/audio_session/0.1/android",
        "/workspace/plugin_overlays/audio_session/0.1/android/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/audio_session/0/android",
        "/workspace/plugin_overlays/audio_session/0/android/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/audio_session/android",
        "/workspace/plugin_overlays/audio_session/android/BUILD.bazel.tpl",
    ]:
        asserts.true(
            env,
            expected in mock1.watched,
            "expected %s in watched %s" % (expected, mock1.watched),
        )

    # Adding `0/android/BUILD.bazel.tpl` touches a path watched during mock1.
    major_android_tpl = "/workspace/plugin_overlays/audio_session/0/android/BUILD.bazel.tpl"
    asserts.true(env, major_android_tpl in mock1.watched)
    files_with_android = dict(files)
    files_with_android[major_android_tpl] = 'kt_android_library(name = "lib", custom_package = "{PKG}")'
    mock2 = _make_mock_overlay_ctx(files = files_with_android)
    android2 = resolve_overlay_template(
        mock2.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        [],
        "android/BUILD.bazel.tpl",
    )
    asserts.equals(env, 'kt_android_library(name = "lib", custom_package = "audio_session")', android2)
    asserts.true(
        env,
        "/workspace/plugin_overlays/audio_session/0.1.21/android/BUILD.bazel.tpl" in mock2.watched,
    )

    return unittest.end(env)

overlay_watches_android_subpackage_candidates_test = unittest.make(
    _overlay_watches_android_subpackage_candidates_test_impl,
)

def _overlay_multi_root_watches_higher_priority_root_test_impl(ctx):
    """When a lower-priority root matches, higher-priority roots that missed are still watched.

    `flutter.plugin_overlays` prepends user roots ahead of `@rules_flutter//ext:BUILD.bazel`.
    When a package initially resolves from `@rules_flutter//ext`, the user root's
    probed candidate paths must all be watched so dropping a local override into
    the user root invalidates the spoke on the next incremental build.
    """
    env = unittest.begin(ctx)

    anchors = {
        "//plugin_overlays:BUILD.bazel": "/workspace/plugin_overlays/BUILD.bazel",
        "@rules_flutter//ext:BUILD.bazel": "/ext_repo/ext/BUILD.bazel",
    }
    files = {
        "/ext_repo/ext/objective_c/9/BUILD.bazel.tpl": (
            'flutter_plugin(name = "{PKG}", language_version = "{LANGUAGE_VERSION}", deps = [\n        {DEPS}\n    ]) # bundled'
        ),
    }
    mock = _make_mock_overlay_ctx(files = files, root_anchors = anchors)

    overlay_content, overlay_android_content = resolve_overlay_roots(
        mock.ctx,
        ["//plugin_overlays:BUILD.bazel", "@rules_flutter//ext:BUILD.bazel"],
        "objective_c",
        "9.3.0",
        "3.10",
        ["@deps__ffi//:ffi"],
    )

    asserts.true(env, "# bundled" in overlay_content, overlay_content)
    asserts.equals(env, "", overlay_android_content)
    for expected_watched in [
        "/workspace/plugin_overlays/objective_c",
        "/workspace/plugin_overlays/objective_c/9.3.0/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/objective_c/9.3/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/objective_c/9/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/objective_c/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9.3.0/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9.3/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9.3.0/android/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9.3/android/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9/android/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/android/BUILD.bazel.tpl",
    ]:
        asserts.true(
            env,
            expected_watched in mock.watched,
            "expected %s in watched: %s" % (expected_watched, mock.watched),
        )

    return unittest.end(env)

overlay_multi_root_watches_higher_priority_root_test = unittest.make(
    _overlay_multi_root_watches_higher_priority_root_test_impl,
)

def _audio_session_heredoc_tpl():
    """The audio_session BuildConfig heredoc genrule, as its overlay spells it."""
    return """\
load("@rules_flutter//flutter:android.bzl", "flutter_android_engine")
load("@rules_java//java:java_library.bzl", "java_library")

genrule(
    name = "_build_config_src",
    outs = ["_build_config/com/ryanheise/audio_session/BuildConfig.java"],
    cmd = "cat > $@ <<'EOF'\\npackage com.ryanheise.audio_session;\\npublic final class BuildConfig {\\n  public static final boolean DEBUG = false;\\n  public static final String LIBRARY_PACKAGE_NAME = \\"com.ryanheise.audio_session\\";\\n  public static final String BUILD_TYPE = \\"release\\";\\n}\\nEOF\\n",
)
"""

def _overlay_rewrites_cat_genrules_to_write_file_test_impl(ctx):
    """Overlay templates using `cat > $@ <<'EOF'` genrules are rewritten to `write_file`."""
    env = unittest.begin(ctx)

    tpl = _audio_session_heredoc_tpl()
    rendered = apply_overlay_substitutions(
        content = tpl,
        hub_name = "deps",
        package_name = "audio_session",
        version = "0.1.21",
        language_version = "3.4",
        deps = "",
    )
    asserts.true(
        env,
        'load("@bazel_skylib//rules:write_file.bzl", "write_file")' in rendered,
        rendered,
    )
    asserts.true(
        env,
        'write_file(\n    name = "_build_config_src",\n    out = "_build_config/com/ryanheise/audio_session/BuildConfig.java",' in rendered,
        rendered,
    )
    asserts.false(env, "genrule" in rendered, rendered)
    asserts.false(env, "cat >" in rendered, rendered)

    return unittest.end(env)

overlay_rewrites_cat_genrules_to_write_file_test = unittest.make(
    _overlay_rewrites_cat_genrules_to_write_file_test_impl,
)

def _overlay_heredoc_content_matches_cat_bytes_test_impl(ctx):
    """The rewritten `content` holds the bytes the heredoc `cat` would write.

    The heredoc body the rewrite cuts out is still Starlark-encoded source
    text; each rendered `content` entry must parse back to the exact file
    line, so the `write_file` output equals the `cat` output byte for byte.
    """
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = _audio_session_heredoc_tpl(),
        hub_name = "deps",
        package_name = "audio_session",
        version = "0.1.21",
        language_version = "3.4",
        deps = "",
    )
    want_lines = [
        "package com.ryanheise.audio_session;",
        "public final class BuildConfig {",
        "  public static final boolean DEBUG = false;",
        '  public static final String LIBRARY_PACKAGE_NAME = "com.ryanheise.audio_session";',
        '  public static final String BUILD_TYPE = "release";',
        "}",
        "",
    ]
    want_entries = "\n".join(["        " + starlark_string_literal(line) + "," for line in want_lines])
    asserts.true(env, want_entries in rendered, rendered)

    return unittest.end(env)

overlay_heredoc_content_matches_cat_bytes_test = unittest.make(
    _overlay_heredoc_content_matches_cat_bytes_test_impl,
)

def _overlay_heredoc_decodes_mixed_escapes_test_impl(ctx):
    """A body holding a quote, a backslash, a tab and a single quote decodes.

    Each escape in the cut-out source text must reach the rendered `content`
    as the character it names, not re-escaped: the `write_file` output must
    equal the `cat` heredoc bytes for every escape a Starlark literal holds.
    """
    env = unittest.begin(ctx)

    tpl = """\
genrule(
    name = "mixed_src",
    outs = ["mixed/out.txt"],
    cmd = "cat > $@ <<'EOF'\\nquote \\"here\\"\\nback\\\\slash\\ncol\\there\\nit\\'s fine\\nEOF\\n",
)
"""
    rendered = apply_overlay_substitutions(
        content = tpl,
        hub_name = "deps",
        package_name = "mixed_pkg",
        version = "1.0.0",
        language_version = "3.4",
        deps = "",
    )
    want_lines = [
        'quote "here"',
        "back\\slash",
        "col\there",
        "it's fine",
        "",
    ]
    want_entries = "\n".join(["        " + starlark_string_literal(line) + "," for line in want_lines])
    asserts.true(env, want_entries in rendered, rendered)

    return unittest.end(env)

overlay_heredoc_decodes_mixed_escapes_test = unittest.make(
    _overlay_heredoc_decodes_mixed_escapes_test_impl,
)

def _maven_labels_known_and_unknown_test_impl(ctx):
    """Groovy runtime configs resolve known coords and report unknown ones."""
    env = unittest.begin(ctx)

    content = """\
dependencies {
    implementation 'androidx.browser:browser:1.9.0'
    api 'androidx.core:core:1.17.0'
    runtimeOnly 'com.example:thing:2.0'
    implementation 'com.example:thing:2.0'
    implementation 'androidx.browser:browser:1.9.0'
}
"""
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(
        env,
        [
            "@rules_android_maven//:androidx_browser_browser",
            "@rules_android_maven//:androidx_core_core",
        ],
        result.labels,
    )
    asserts.equals(env, ["com.example:thing"], result.unknown)
    asserts.equals(env, [], result.unreadable)

    return unittest.end(env)

maven_labels_known_and_unknown_test = unittest.make(
    _maven_labels_known_and_unknown_test_impl,
)

def _maven_labels_kotlin_dsl_test_impl(ctx):
    """Kotlin DSL parenthesised forms resolve the same coordinates."""
    env = unittest.begin(ctx)

    content = """\
dependencies {
    implementation("androidx.annotation:annotation:1.9.1")
    api("androidx.media:media:1.7.0")
    runtimeOnly("com.example:native:3.1")
}
"""
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(
        env,
        [
            "@rules_android_maven//:androidx_annotation_annotation",
            "@rules_android_maven//:androidx_media_media",
        ],
        result.labels,
    )
    asserts.equals(env, ["com.example:native"], result.unknown)
    asserts.equals(env, [], result.unreadable)

    return unittest.end(env)

maven_labels_kotlin_dsl_test = unittest.make(
    _maven_labels_kotlin_dsl_test_impl,
)

def _maven_labels_mapping_and_ignore_test_impl(ctx):
    """Caller mapping adds labels and wins; ignore silences unknown coords."""
    env = unittest.begin(ctx)

    content = """\
dependencies {
    implementation 'androidx.browser:browser:1.9.0'
    implementation 'com.example:thing:2.0'
    implementation 'com.example:provided-elsewhere:1.0'
}
"""
    result = maven_labels_for_gradle(
        content,
        {
            # Mapping wins over the built-in table on collision.
            "androidx.browser:browser": "//third_party:browser",
            "com.example:thing": "@rules_android_maven//:com_example_thing",
        },
        ["com.example:provided-elsewhere"],
    )
    asserts.equals(
        env,
        [
            "//third_party:browser",
            "@rules_android_maven//:com_example_thing",
        ],
        result.labels,
    )
    asserts.equals(env, [], result.unknown)
    asserts.equals(env, [], result.unreadable)

    return unittest.end(env)

maven_labels_mapping_and_ignore_test = unittest.make(
    _maven_labels_mapping_and_ignore_test_impl,
)

def _maven_labels_scopes_test_impl(ctx):
    """Non-runtime scopes never surface: kotlin-stdlib, compileOnly, tests, buildscript."""
    env = unittest.begin(ctx)

    content = """\
buildscript {
    dependencies {
        classpath 'com.android.tools.build:gradle:8.3.1'
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.7.22")
    }
}

android {
    namespace = 'dev.example.plugin'

    dependencies {
        implementation "org.jetbrains.kotlin:kotlin-stdlib:$kotlin_version"
    }
}

dependencies {
    implementation 'androidx.core:core:1.17.0'
    compileOnly 'io.flutter:flutter_embedding_debug:1.0.0'
    testImplementation 'junit:junit:4.13.2'
    testImplementation("org.mockito:mockito-core:5.23.0")
    androidTestImplementation 'androidx.test:core:1.6.0'
    debugImplementation 'com.example:debug-only:1.0'
}
"""
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_core_core"],
        result.labels,
    )

    # Only the variant-prefixed runtime dep is unknown: stdlib is provided,
    # compileOnly / test scopes are left out, buildscript classpaths ignored.
    asserts.equals(env, ["com.example:debug-only"], result.unknown)
    asserts.equals(env, [], result.unreadable)

    return unittest.end(env)

maven_labels_scopes_test = unittest.make(
    _maven_labels_scopes_test_impl,
)

def _maven_labels_unreadable_test_impl(ctx):
    """Catalog refs, variables and file deps are unreadable; project refs pass."""
    env = unittest.begin(ctx)

    content = """\
dependencies {
    implementation(libs.browser)
    implementation libs.annotation
    api project(':shared')
    implementation(project(":shared"))
    runtimeOnly files('libs/bundled.jar')
    implementation someVariable
}
"""
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(env, [], result.labels)
    asserts.equals(env, [], result.unknown)
    asserts.equals(
        env,
        [
            "implementation libs.annotation",
            "implementation someVariable",
            "implementation(libs.browser)",
            "runtimeOnly files('libs/bundled.jar')",
        ],
        result.unreadable,
    )

    return unittest.end(env)

maven_labels_unreadable_test = unittest.make(
    _maven_labels_unreadable_test_impl,
)

def _gradle_reader(scripts):
    """A `read_script` callback serving `scripts` (path -> text)."""
    return lambda p: scripts.get(p, None)

def _maven_labels_single_line_test_impl(ctx):
    """A single-line `dependencies { ... }` block resolves like multiline."""
    env = unittest.begin(ctx)

    content = "dependencies { implementation 'androidx.browser:browser:1.9.0' }\n"
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        result.labels,
    )
    asserts.equals(env, [], result.unknown)
    asserts.equals(env, [], result.unreadable)

    # The same coordinate unmapped fails closed however it is laid out.
    unmapped = maven_labels_for_gradle(
        "dependencies { implementation 'com.example:thing:1.0' }\n",
        {},
        [],
    )
    asserts.equals(env, [], unmapped.labels)
    asserts.equals(env, ["com.example:thing"], unmapped.unknown)

    return unittest.end(env)

maven_labels_single_line_test = unittest.make(
    _maven_labels_single_line_test_impl,
)

def _maven_labels_semicolon_test_impl(ctx):
    """Two declarations on one line separated by `;` both resolve."""
    env = unittest.begin(ctx)

    content = """\
dependencies {
    implementation 'androidx.browser:browser:1.9.0'; implementation 'com.example:thing:1.0'
}
"""
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        result.labels,
    )
    asserts.equals(env, ["com.example:thing"], result.unknown)
    asserts.equals(env, [], result.unreadable)

    return unittest.end(env)

maven_labels_semicolon_test = unittest.make(
    _maven_labels_semicolon_test_impl,
)

def _maven_labels_add_call_test_impl(ctx):
    """Gradle's `add(config, coord)` resolves in both quote spellings."""
    env = unittest.begin(ctx)

    content = """\
dependencies {
    add('implementation', 'androidx.browser:browser:1.9.0')
    add("api", "androidx.core:core:1.17.0")
    add('testImplementation', 'junit:junit:4.13.2')
    add('implementation', project(':shared'))
}
"""
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(
        env,
        [
            "@rules_android_maven//:androidx_browser_browser",
            "@rules_android_maven//:androidx_core_core",
        ],
        result.labels,
    )
    asserts.equals(env, [], result.unknown)
    asserts.equals(env, [], result.unreadable)

    # An `add()` with a non-literal notation is unreadable, not dropped.
    bad = maven_labels_for_gradle(
        "dependencies {\n    add('implementation', libs.thing)\n}\n",
        {},
        [],
    )
    asserts.equals(env, [], bad.labels)
    asserts.equals(env, ["add('implementation', libs.thing)"], bad.unreadable)

    return unittest.end(env)

maven_labels_add_call_test = unittest.make(
    _maven_labels_add_call_test_impl,
)

def _maven_labels_comments_test_impl(ctx):
    """Comment-hidden declarations are ignored; strings keep comment marks."""
    env = unittest.begin(ctx)

    content = """\
version = '1.0 /* still the version */'
dependencies {
    // implementation 'com.example:commented:1.0'
    /* implementation 'com.example:blocked:1.0'
       implementation 'com.example:blocked2:1.0' */
    implementation 'androidx.browser:browser:1.9.0' // trailing comment
}
"""
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        result.labels,
    )
    asserts.equals(env, [], result.unknown)
    asserts.equals(env, [], result.unreadable)

    # A `//` inside a string literal is kept: the whole declaration is
    # reported, not the text before a phantom comment.
    slashes = maven_labels_for_gradle(
        "dependencies {\n    implementation 'com.exa//mple:thing:1.0'\n}\n",
        {},
        [],
    )
    asserts.equals(env, [], slashes.labels)
    asserts.equals(
        env,
        ["implementation 'com.exa//mple:thing:1.0'"],
        slashes.unreadable,
    )

    return unittest.end(env)

maven_labels_comments_test = unittest.make(
    _maven_labels_comments_test_impl,
)

def _maven_labels_buildscript_and_nested_test_impl(ctx):
    """Buildscript classpaths are excluded; nested blocks are unreadable."""
    env = unittest.begin(ctx)

    content = """\
buildscript {
    dependencies {
        classpath 'com.android.tools.build:gradle:8.3.1'
    }
}
dependencies {
    implementation 'androidx.browser:browser:1.9.0'
    constraints {
        implementation 'androidx.core:core:1.17.0'
    }
}
"""
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        result.labels,
    )
    asserts.equals(env, [], result.unknown)
    asserts.equals(
        env,
        ["constraints", "implementation 'androidx.core:core:1.17.0'"],
        result.unreadable,
    )

    return unittest.end(env)

maven_labels_buildscript_and_nested_test = unittest.make(
    _maven_labels_buildscript_and_nested_test_impl,
)

def _maven_labels_dependencies_mention_test_impl(ctx):
    """`dependencies` outside the block form is unreadable."""
    env = unittest.begin(ctx)

    content = """\
dependencies {
    implementation 'androidx.browser:browser:1.9.0'
}
project.dependencies.add('implementation', 'com.example:thing:1.0')
"""
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        result.labels,
    )
    asserts.equals(
        env,
        ["project.dependencies.add('implementation', 'com.example:thing:1.0')"],
        result.unreadable,
    )

    dotted = maven_labels_for_gradle(
        "dependencies.implementation 'com.example:thing:1.0'\n",
        {},
        [],
    )
    asserts.equals(env, [], dotted.labels)
    asserts.equals(
        env,
        ["dependencies.implementation 'com.example:thing:1.0'"],
        dotted.unreadable,
    )

    # A prose string that merely names dependencies is not a mention.
    prose = maven_labels_for_gradle(
        "description = 'manages dependencies'\ndependencies {\n    implementation 'androidx.browser:browser:1.9.0'\n}\n",
        {},
        [],
    )
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        prose.labels,
    )
    asserts.equals(env, [], prose.unreadable)

    return unittest.end(env)

maven_labels_dependencies_mention_test = unittest.make(
    _maven_labels_dependencies_mention_test_impl,
)

def _maven_labels_apply_from_test_impl(ctx):
    """In-package `apply from:` scripts resolve; the rest fail closed."""
    env = unittest.begin(ctx)

    root = """\
apply from: 'extra.gradle'
dependencies {
    implementation 'androidx.browser:browser:1.9.0'
}
"""
    scripts = {
        "extra.gradle": "dependencies {\n    implementation 'com.example:thing:1.0'\n}\n",
    }
    result = maven_labels_for_gradle(root, {}, [], _gradle_reader(scripts))
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        result.labels,
    )
    asserts.equals(env, ["com.example:thing"], result.unknown)
    asserts.equals(env, [], result.unreadable)

    # Kotlin DSL spelling.
    kts = maven_labels_for_gradle(
        "apply(from = \"extra.gradle.kts\")\n",
        {},
        [],
        _gradle_reader({
            "extra.gradle.kts": "dependencies {\n    implementation(\"androidx.core:core:1.17.0\")\n}\n",
        }),
    )
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_core_core"],
        kts.labels,
    )
    asserts.equals(env, [], kts.unreadable)

    # A URL, an escape, a missing file, and no reader at all: unreadable.
    for stmt in [
        "apply from: 'https://example.com/extra.gradle'",
        "apply from: '../extra.gradle'",
        "apply from: 'missing.gradle'",
        "apply from: extraFile",
    ]:
        bad = maven_labels_for_gradle(stmt + "\n", {}, [], _gradle_reader(scripts))
        asserts.equals(env, [], bad.labels, stmt)
        asserts.equals(env, [stmt], bad.unreadable, stmt)

    no_reader = maven_labels_for_gradle(root, {}, [])
    asserts.equals(env, ["apply from: 'extra.gradle'"], no_reader.unreadable)

    return unittest.end(env)

maven_labels_apply_from_test = unittest.make(
    _maven_labels_apply_from_test_impl,
)

def _maven_labels_apply_cycle_and_depth_test_impl(ctx):
    """Apply cycles and over-deep chains are unreadable, not hangs."""
    env = unittest.begin(ctx)

    cycle = maven_labels_for_gradle(
        "apply from: 'a.gradle'\n",
        {},
        [],
        _gradle_reader({
            "a.gradle": "apply from: 'b.gradle'\n",
            "b.gradle": "apply from: 'a.gradle'\n",
        }),
    )
    asserts.equals(env, [], cycle.labels)
    asserts.equals(env, ["apply from: 'a.gradle'"], cycle.unreadable)

    scripts = {}
    for i in range(16):
        scripts["f%d.gradle" % i] = "apply from: 'f%d.gradle'\n" % (i + 1)
    scripts["f16.gradle"] = "dependencies {\n    implementation 'com.example:deep:1.0'\n}\n"
    deep = maven_labels_for_gradle(
        "apply from: 'f0.gradle'\n",
        {},
        [],
        _gradle_reader(scripts),
    )
    asserts.equals(env, [], deep.labels)
    asserts.true(env, len(deep.unreadable) > 0, "expected the depth cap to refuse: %s" % deep.unreadable)

    return unittest.end(env)

maven_labels_apply_cycle_and_depth_test = unittest.make(
    _maven_labels_apply_cycle_and_depth_test_impl,
)

def _maven_labels_kotlin_add_test_impl(ctx):
    """Kotlin DSL `add()` and parenthesised forms resolve together."""
    env = unittest.begin(ctx)

    content = """\
dependencies {
    implementation("androidx.annotation:annotation:1.9.1")
    add("api", "androidx.media:media:1.7.0")
}
"""
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(
        env,
        [
            "@rules_android_maven//:androidx_annotation_annotation",
            "@rules_android_maven//:androidx_media_media",
        ],
        result.labels,
    )
    asserts.equals(env, [], result.unreadable)

    return unittest.end(env)

maven_labels_kotlin_add_test = unittest.make(
    _maven_labels_kotlin_add_test_impl,
)

def _maven_labels_map_and_interpolation_test_impl(ctx):
    """Map notation, catalogs and interpolation stay unreadable."""
    env = unittest.begin(ctx)

    content = """\
dependencies {
    implementation group: 'com.example', name: 'thing', version: '1.0'
    implementation "com.$ex:thing:1.0"
    implementation libs.thing
}
"""
    result = maven_labels_for_gradle(content, {}, [])
    asserts.equals(env, [], result.labels)
    asserts.equals(env, [], result.unknown)
    asserts.equals(
        env,
        [
            "implementation \"com.$ex:thing:1.0\"",
            "implementation group: 'com.example', name: 'thing', version: '1.0'",
            "implementation libs.thing",
        ],
        result.unreadable,
    )

    # Interpolation in the version still reduces the coordinate, so it
    # fails as unknown rather than resolving.
    interpolated = maven_labels_for_gradle(
        "dependencies {\n    implementation \"com.example:thing:$version\"\n}\n",
        {},
        [],
    )
    asserts.equals(env, ["com.example:thing"], interpolated.unknown)
    asserts.equals(env, [], interpolated.unreadable)

    return unittest.end(env)

maven_labels_map_and_interpolation_test = unittest.make(
    _maven_labels_map_and_interpolation_test_impl,
)

def _maven_labels_multiline_bracket_test_impl(ctx):
    """Parenthesised calls spanning lines resolve like single-line ones."""
    env = unittest.begin(ctx)

    scripts = {
        "extra.gradle": "dependencies {\n    implementation 'com.example:thing:1.0'\n}\n",
    }

    # Groovy multiline apply: the applied script's coord maps.
    root = maven_labels_for_gradle(
        "apply(\n    from: 'extra.gradle'\n)\n",
        {"com.example:thing": "@rules_android_maven//:com_example_thing"},
        [],
        _gradle_reader(scripts),
    )
    asserts.equals(env, ["@rules_android_maven//:com_example_thing"], root.labels)
    asserts.equals(env, [], root.unreadable)

    # Kotlin multiline apply.
    kts = maven_labels_for_gradle(
        "apply(\n    from = \"extra.gradle.kts\"\n)\n",
        {},
        [],
        _gradle_reader({
            "extra.gradle.kts": "dependencies {\n    implementation(\"androidx.core:core:1.17.0\")\n}\n",
        }),
    )
    asserts.equals(env, ["@rules_android_maven//:androidx_core_core"], kts.labels)
    asserts.equals(env, [], kts.unreadable)

    # Groovy map-in-parens on one line resolves too.
    paren = maven_labels_for_gradle(
        "apply(from: 'extra.gradle')\n",
        {"com.example:thing": "@rules_android_maven//:com_example_thing"},
        [],
        _gradle_reader(scripts),
    )
    asserts.equals(env, ["@rules_android_maven//:com_example_thing"], paren.labels)
    asserts.equals(env, [], paren.unreadable)

    # Multiline implementation() and add() calls.
    calls = maven_labels_for_gradle(
        "dependencies {\n    implementation(\n        'androidx.browser:browser:1.9.0'\n    )\n    add(\n        'api',\n        \"androidx.core:core:1.17.0\"\n    )\n}\n",
        {},
        [],
    )
    asserts.equals(
        env,
        [
            "@rules_android_maven//:androidx_browser_browser",
            "@rules_android_maven//:androidx_core_core",
        ],
        calls.labels,
    )
    asserts.equals(env, [], calls.unreadable)

    # A comment inside the parenthesised call is layout, not a boundary.
    commented = maven_labels_for_gradle(
        "apply( // shared deps\n    from: 'extra.gradle'\n)\n",
        {"com.example:thing": "@rules_android_maven//:com_example_thing"},
        [],
        _gradle_reader(scripts),
    )
    asserts.equals(env, ["@rules_android_maven//:com_example_thing"], commented.labels)
    asserts.equals(env, [], commented.unreadable)

    return unittest.end(env)

maven_labels_multiline_bracket_test = unittest.make(
    _maven_labels_multiline_bracket_test_impl,
)

def _maven_labels_unbalanced_bracket_test_impl(ctx):
    """An unbalanced bracket is reported unreadable, never silently ignored."""
    env = unittest.begin(ctx)

    missing_paren = maven_labels_for_gradle(
        "dependencies {\n    implementation('androidx.browser:browser:1.9.0'\n}\n",
        {},
        [],
    )
    asserts.true(
        env,
        len(missing_paren.unreadable) > 0,
        "expected the unbalanced bracket to be reported: %s" % missing_paren.unreadable,
    )

    dangling_list = maven_labels_for_gradle(
        "dependencies {\n    implementation 'androidx.browser:browser:1.9.0'\n}\ndef extra = [\n",
        {},
        [],
    )
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        dangling_list.labels,
    )
    asserts.true(
        env,
        len(dangling_list.unreadable) > 0,
        "expected the unbalanced bracket to be reported: %s" % dangling_list.unreadable,
    )

    return unittest.end(env)

maven_labels_unbalanced_bracket_test = unittest.make(
    _maven_labels_unbalanced_bracket_test_impl,
)

def _parse_gradle_namespace_model_test_impl(ctx):
    """The namespace comes from the lexed model: layout-free, ghost-free, last-wins."""
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "com.example.single",
        parse_gradle_android_namespace("android { namespace = 'com.example.single' }\n"),
    )
    asserts.equals(
        env,
        "com.example.call",
        parse_gradle_android_namespace("android { namespace 'com.example.call' }\n"),
    )
    asserts.equals(
        env,
        "com.example.setcall",
        parse_gradle_android_namespace("android {\n    namespace.set(\"com.example.setcall\")\n}\n"),
    )
    asserts.equals(
        env,
        "com.example.multi",
        parse_gradle_android_namespace("android {\n    namespace(\n        'com.example.multi'\n    )\n}\n"),
    )
    asserts.equals(
        env,
        "com.example.nested",
        parse_gradle_android_namespace("if (true) {\n    android {\n        namespace = 'com.example.nested'\n    }\n}\n"),
    )
    asserts.equals(
        env,
        "com.example.dotted",
        parse_gradle_android_namespace("android.namespace = 'com.example.dotted'\n"),
    )
    asserts.equals(
        env,
        "com.example.second",
        parse_gradle_android_namespace("android {\n    namespace = 'com.example.first'\n    namespace = 'com.example.second'\n}\n"),
    )

    # Ghosts: block comments, line comments and string literals never count.
    asserts.equals(env, "", parse_gradle_android_namespace("/*\nnamespace = 'com.example.evil'\n*/\n"))
    asserts.equals(env, "", parse_gradle_android_namespace("// namespace = 'com.example.evil'\n"))
    asserts.equals(
        env,
        "",
        parse_gradle_android_namespace("def notes = \"\"\"\nnamespace = 'com.example.str'\n\"\"\"\n"),
    )

    # A real declaration beside a ghost still resolves.
    asserts.equals(
        env,
        "com.example.real",
        parse_gradle_android_namespace("/*\nnamespace = 'com.example.evil'\n*/\nandroid {\n    namespace = 'com.example.real'\n}\n"),
    )

    # A namespace anywhere but innermost-android is not a declaration.
    asserts.equals(
        env,
        "",
        parse_gradle_android_namespace("android {\n    defaultConfig {\n        namespace = 'com.example.deep'\n    }\n}\n"),
    )
    asserts.equals(env, "", parse_gradle_android_namespace("namespace = 'com.example.top'\n"))

    return unittest.end(env)

parse_gradle_namespace_model_test = unittest.make(
    _parse_gradle_namespace_model_test_impl,
)

def _gradle_namespace_refusal_test_impl(ctx):
    """A namespace value that is not one string literal is reported for refusal."""
    env = unittest.begin(ctx)

    for bad in [
        "android {\n    namespace = libs.foo\n}\n",
        "android {\n    namespace = someVariable\n}\n",
        "android {\n    namespace = 'com.example.a' + '.b'\n}\n",
        "android {\n    namespace 'com.example.a', 'b'\n}\n",
    ]:
        found = gradle_android_namespaces(bad)
        asserts.equals(env, 1, len(found), bad)
        asserts.false(env, found[0].literal, bad)
        asserts.true(env, len(found[0].statement) > 0, bad)

    # ... while a literal beside them keeps parsing.
    mixed = gradle_android_namespaces("android {\n    namespace = 'com.example.ok'\n}\n")
    asserts.equals(env, 1, len(mixed))
    asserts.true(env, mixed[0].literal)
    asserts.equals(env, "com.example.ok", mixed[0].value)

    return unittest.end(env)

gradle_namespace_refusal_test = unittest.make(
    _gradle_namespace_refusal_test_impl,
)

def _gradle_build_file_choice_test_impl(ctx):
    """Gradle's build file wins the dual-file choice every reader shares."""
    env = unittest.begin(ctx)

    asserts.equals(env, "android/build.gradle", gradle_build_file_choice(True, True))
    asserts.equals(env, "android/build.gradle", gradle_build_file_choice(True, False))
    asserts.equals(env, "android/build.gradle.kts", gradle_build_file_choice(False, True))
    asserts.equals(env, "", gradle_build_file_choice(False, False))

    return unittest.end(env)

gradle_build_file_choice_test = unittest.make(
    _gradle_build_file_choice_test_impl,
)

def _java_package_name_validation_test_impl(ctx):
    """Plugin-controlled namespaces must be Java package names."""
    env = unittest.begin(ctx)

    asserts.true(env, is_java_package_name("com.example.plugin"))
    asserts.true(env, is_java_package_name("io.flutter.plugins.urllauncher"))
    asserts.true(env, is_java_package_name("plugin"))
    asserts.false(env, is_java_package_name(""))
    asserts.false(env, is_java_package_name("com..example"))
    asserts.false(env, is_java_package_name(".com.example"))
    asserts.false(env, is_java_package_name("com.example."))
    asserts.false(env, is_java_package_name("1com.example"))
    asserts.false(env, is_java_package_name("com.ex ample"))
    asserts.false(env, is_java_package_name("com.example-foo"))
    asserts.false(env, is_java_package_name("com.ex\"ample"))
    asserts.false(env, is_java_package_name("com.example.synth\", _x = \"pwned"))

    return unittest.end(env)

java_package_name_validation_test = unittest.make(
    _java_package_name_validation_test_impl,
)

def _maven_dep_label_validation_test_impl(ctx):
    """Workspace-provided dep values must be labels without quoting."""
    env = unittest.begin(ctx)

    asserts.true(env, is_maven_dep_label("@rules_android_maven//:androidx_core_core"))
    asserts.true(env, is_maven_dep_label("//third_party:browser"))
    asserts.false(env, is_maven_dep_label(""))
    asserts.false(env, is_maven_dep_label(":browser"))
    asserts.false(env, is_maven_dep_label("rules_android_maven//:x"))
    asserts.false(env, is_maven_dep_label("@rules_android_maven//:x\",\n_injected = 1,\n_dummy = \"y"))
    asserts.false(env, is_maven_dep_label("@rules_android_maven//:x\\y"))

    return unittest.end(env)

maven_dep_label_validation_test = unittest.make(
    _maven_dep_label_validation_test_impl,
)

def _hostile_label_renders_inert_test_impl(ctx):
    """A hostile label value cannot break out of the generated deps list."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "dev.example.ok",
        extra_maven_labels = ["@rules_android_maven//:x\",\n_injected = 1,\n_dummy = \"y"],
        android_manifest = "",
        has_resources = False,
    )

    asserts.false(env, "\n_injected = 1," in content, content)

    return unittest.end(env)

hostile_label_renders_inert_test = unittest.make(
    _hostile_label_renders_inert_test_impl,
)

def _maven_labels_dollar_slashy_test_impl(ctx):
    """Dollar-slashy literals holding comment openers never split the model."""
    env = unittest.begin(ctx)

    block = maven_labels_for_gradle(
        "def rx = $/a/*b/$\ndependencies {\n    implementation 'com.example:thing:1.0'\n}\n",
        {},
        [],
    )
    asserts.equals(env, ["com.example:thing"], block.unknown)
    asserts.equals(env, [], block.unreadable)

    line = maven_labels_for_gradle(
        "def u = $/http://example.com/$; dependencies { implementation 'com.example:thing:1.0' }\n",
        {},
        [],
    )
    asserts.equals(env, ["com.example:thing"], line.unknown)
    asserts.equals(env, [], line.unreadable)

    return unittest.end(env)

maven_labels_dollar_slashy_test = unittest.make(
    _maven_labels_dollar_slashy_test_impl,
)

def _maven_labels_slashy_and_division_test_impl(ctx):
    """Slashy strings splice whole; division stays code; neither is a dep."""
    env = unittest.begin(ctx)

    semicolon = maven_labels_for_gradle(
        "def s = /a;b/\ndependencies {\n    implementation 'androidx.browser:browser:1.9.0'\n}\n",
        {},
        [],
    )
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        semicolon.labels,
    )
    asserts.equals(env, [], semicolon.unreadable)

    division = maven_labels_for_gradle(
        "def x = 6 / 2 // half\ndependencies {\n    implementation 'androidx.browser:browser:1.9.0'\n}\n",
        {},
        [],
    )
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        division.labels,
    )
    asserts.equals(env, [], division.unreadable)

    slashy_dep = maven_labels_for_gradle(
        "dependencies {\n    implementation(/com.example:thing:1.0/)\n}\n",
        {},
        [],
    )
    asserts.equals(env, [], slashy_dep.labels)
    asserts.equals(
        env,
        ["implementation(/com.example:thing:1.0/)"],
        slashy_dep.unreadable,
    )

    slashy_apply = maven_labels_for_gradle(
        "apply from: /mobile.gradle/\n",
        {},
        [],
        _gradle_reader({}),
    )
    asserts.equals(env, [], slashy_apply.labels)
    asserts.equals(env, ["apply from: /mobile.gradle/"], slashy_apply.unreadable)

    return unittest.end(env)

maven_labels_slashy_and_division_test = unittest.make(
    _maven_labels_slashy_and_division_test_impl,
)

def _maven_labels_kotlin_nesting_test_impl(ctx):
    """Kotlin nested comments and raw-string templates never leak deps."""
    env = unittest.begin(ctx)

    nested = (
        "dependencies {\n" +
        "    /* a /* b */ implementation 'com.example:evil:1.0' */\n" +
        "    implementation(\"androidx.browser:browser:1.9.0\")\n" +
        "}\n"
    )
    kts = maven_labels_for_gradle(nested, {}, [], None, "kotlin")
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        kts.labels,
    )
    asserts.equals(env, [], kts.unknown)
    asserts.equals(env, [], kts.unreadable)

    # Groovy block comments do not nest: the "commented" declaration lands.
    groovy = maven_labels_for_gradle(nested, {}, [])
    asserts.equals(env, ["com.example:evil"], groovy.unknown)

    templated = (
        "val notes = \"\"\"\n" +
        "deps { implementation 'com.example:evil:1.0' }\n" +
        "${foo(\"}\")}\n" +
        "\"\"\"\n" +
        "dependencies {\n" +
        "    implementation(\"androidx.browser:browser:1.9.0\")\n" +
        "}\n"
    )
    raw = maven_labels_for_gradle(templated, {}, [], None, "kotlin")
    asserts.equals(
        env,
        ["@rules_android_maven//:androidx_browser_browser"],
        raw.labels,
    )
    asserts.equals(env, [], raw.unknown)
    asserts.equals(env, [], raw.unreadable)

    return unittest.end(env)

maven_labels_kotlin_nesting_test = unittest.make(
    _maven_labels_kotlin_nesting_test_impl,
)

def _gradle_native_scan_test_impl(ctx):
    """Native builds resolve inline, applied, and applied-by-applied; ghosts do not."""
    env = unittest.begin(ctx)

    inline = gradle_collect_files(
        "android/build.gradle",
        "android {\n    externalNativeBuild {\n        cmake {}\n    }\n}\n",
        "groovy",
        None,
    )
    found_inline = gradle_scan_native(inline.files)
    asserts.equals(env, 1, len(found_inline))
    asserts.equals(env, "android/build.gradle", found_inline[0].file)

    applied = gradle_collect_files(
        "android/build.gradle",
        "apply from: 'native.gradle'\n",
        "groovy",
        _gradle_reader({"native.gradle": "android {\n    externalNativeBuild {\n        cmake {}\n    }\n}\n"}),
    )
    found_applied = gradle_scan_native(applied.files)
    asserts.equals(env, 1, len(found_applied))
    asserts.equals(env, "native.gradle", found_applied[0].file)

    chained = gradle_collect_files(
        "android/build.gradle",
        "apply from: 'a.gradle'\n",
        "groovy",
        _gradle_reader({
            "a.gradle": "apply from: 'b.gradle'\n",
            "b.gradle": "android {\n    externalNativeBuild {\n        cmake {}\n    }\n}\n",
        }),
    )
    found_chained = gradle_scan_native(chained.files)
    asserts.equals(env, 1, len(found_chained))
    asserts.equals(env, "b.gradle", found_chained[0].file)

    ghosts = gradle_collect_files(
        "android/build.gradle",
        "// externalNativeBuild\ndef s = 'externalNativeBuild'\nandroid {}\n",
        "groovy",
        None,
    )
    asserts.equals(env, [], gradle_scan_native(ghosts.files))

    return unittest.end(env)

gradle_native_scan_test = unittest.make(
    _gradle_native_scan_test_impl,
)

def _gradle_proguard_shapes_test_impl(ctx):
    """Keep-rule declarations resolve multiline, multi-file and wrapped; variables refuse."""
    env = unittest.begin(ctx)

    multi = gradle_collect_files(
        "android/build.gradle",
        "android {\n    buildTypes {\n        release {\n            consumerProguardFiles(\n                'consumer-rules.pro'\n            )\n        }\n    }\n}\n",
        "groovy",
        None,
    )
    scanned_multi = gradle_scan_proguard(multi.files)
    asserts.equals(env, ["consumer-rules.pro"], scanned_multi.paths)
    asserts.equals(env, [], scanned_multi.bad)

    several = gradle_collect_files(
        "android/build.gradle",
        "android {\n    consumerProguardFiles 'a.pro', 'b.pro'\n}\n",
        "groovy",
        None,
    )
    asserts.equals(env, ["a.pro", "b.pro"], gradle_scan_proguard(several.files).paths)

    wrapped = gradle_collect_files(
        "android/build.gradle",
        "android {\n    consumerProguardFiles file('consumer-rules.pro')\n}\n",
        "groovy",
        None,
    )
    scanned_wrapped = gradle_scan_proguard(wrapped.files)
    asserts.equals(env, ["consumer-rules.pro"], scanned_wrapped.paths)
    asserts.equals(env, [], scanned_wrapped.bad)

    var = gradle_collect_files(
        "android/build.gradle",
        "def rulesFile = 'consumer-rules.pro'\nandroid {\n    consumerProguardFiles rulesFile\n}\n",
        "groovy",
        None,
    )
    scanned_var = gradle_scan_proguard(var.files)
    asserts.equals(env, [], scanned_var.paths)
    asserts.equals(env, 1, len(scanned_var.bad))

    empty = gradle_collect_files(
        "android/build.gradle",
        "android {\n    consumerProguardFiles()\n}\n",
        "groovy",
        None,
    )
    asserts.equals(env, 1, len(gradle_scan_proguard(empty.files).bad))

    applied = gradle_collect_files(
        "android/build.gradle",
        "apply from: 'rules.gradle'\n",
        "groovy",
        _gradle_reader({"rules.gradle": "android {\n    consumerProguardFiles 'consumer-rules.pro'\n}\n"}),
    )
    scanned_applied = gradle_scan_proguard(applied.files)
    asserts.equals(env, ["consumer-rules.pro"], scanned_applied.paths)
    asserts.equals(env, [], scanned_applied.bad)

    return unittest.end(env)

gradle_proguard_shapes_test = unittest.make(
    _gradle_proguard_shapes_test_impl,
)

def _gradle_namespace_qualified_test_impl(ctx):
    """Qualified and deferred namespace shapes resolve; ghosts and variables do not."""
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "com.example.delegated",
        parse_gradle_android_namespace("android {\n    android.namespace = 'com.example.delegated'\n}\n"),
    )
    asserts.equals(
        env,
        "com.example.after",
        parse_gradle_android_namespace("android {\n    compileSdk = 34\n}\nafterEvaluate {\n    android.namespace = 'com.example.after'\n}\n"),
    )
    asserts.equals(
        env,
        "com.example.applied",
        parse_gradle_android_namespace("android.apply {\n    namespace = 'com.example.applied'\n}\n"),
    )
    asserts.equals(
        env,
        "com.example.configured",
        parse_gradle_android_namespace("configure<LibraryExtension> {\n    namespace = 'com.example.configured'\n}\n"),
    )
    asserts.equals(
        env,
        "com.example.slashy",
        parse_gradle_android_namespace("android {\n    namespace = /com.example.slashy/\n}\n"),
    )

    ghosted = parse_gradle_android_namespace(
        "def rx = $/namespace = 'com.example.evil'/$\nandroid {\n    namespace = 'com.example.real'\n}\n",
    )
    asserts.equals(env, "com.example.real", ghosted)

    interpolated = gradle_android_namespaces("android {\n    namespace = \"com.exa$mple\"\n}\n")
    asserts.equals(env, 1, len(interpolated))
    asserts.false(env, interpolated[0].literal)

    charred = gradle_android_namespaces(
        "android {\n    namespace = 'com.example.c'\n}\n",
        "kotlin",
    )
    asserts.equals(env, 1, len(charred))
    asserts.false(env, charred[0].literal)

    layered = gradle_collect_files(
        "android/build.gradle",
        "apply from: 'ns.gradle'\nandroid {\n    namespace = 'com.example.root'\n}\n",
        "groovy",
        _gradle_reader({"ns.gradle": "android {\n    namespace = 'com.example.applied'\n}\n"}),
    )
    ordered = [ns.value for ns in gradle_scan_namespaces(layered.files) if ns.literal]
    asserts.equals(env, ["com.example.root", "com.example.applied"], ordered)

    return unittest.end(env)

gradle_namespace_qualified_test = unittest.make(
    _gradle_namespace_qualified_test_impl,
)

def flutter_pub_package_test_suite(name):
    unittest.suite(
        name,
        spokes_state_their_resolved_version_test,
        spoke_without_a_version_states_none_test,
        hardcoded_language_version_is_rejected_test,
        overlay_substitutes_the_language_version_test,
        overlay_without_a_language_version_is_left_alone_test,
        overlay_substitutes_the_dependencies_test,
        hardcoded_overlay_dependency_is_rejected_test,
        overlay_watches_missing_package_and_candidates_test,
        overlay_watches_more_specific_version_candidates_test,
        overlay_watches_android_subpackage_candidates_test,
        overlay_multi_root_watches_higher_priority_root_test,
        overlay_rewrites_cat_genrules_to_write_file_test,
        overlay_heredoc_content_matches_cat_bytes_test,
        overlay_heredoc_decodes_mixed_escapes_test,
        parse_gradle_android_namespace_test,
        parse_android_manifest_package_test,
        record_android_subpackage_test,
        resources_without_manifest_test,
        no_resources_subpackage_test,
        empty_subpackage_test,
        plugin_spoke_carries_resources_test,
        library_spoke_carries_resources_test,
        spoke_with_shaders_declares_their_includes_test,
        maven_labels_known_and_unknown_test,
        maven_labels_kotlin_dsl_test,
        maven_labels_mapping_and_ignore_test,
        maven_labels_scopes_test,
        maven_labels_unreadable_test,
        maven_labels_single_line_test,
        maven_labels_semicolon_test,
        maven_labels_add_call_test,
        maven_labels_comments_test,
        maven_labels_buildscript_and_nested_test,
        maven_labels_dependencies_mention_test,
        maven_labels_apply_from_test,
        maven_labels_apply_cycle_and_depth_test,
        maven_labels_kotlin_add_test,
        maven_labels_map_and_interpolation_test,
        maven_labels_multiline_bracket_test,
        maven_labels_unbalanced_bracket_test,
        maven_labels_dollar_slashy_test,
        maven_labels_slashy_and_division_test,
        maven_labels_kotlin_nesting_test,
        gradle_native_scan_test,
        gradle_proguard_shapes_test,
        gradle_namespace_qualified_test,
        parse_gradle_namespace_model_test,
        gradle_namespace_refusal_test,
        gradle_build_file_choice_test,
        java_package_name_validation_test,
        maven_dep_label_validation_test,
        hostile_label_renders_inert_test,
    )
