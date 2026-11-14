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
load("//flutter/private:cmake_link_libraries.bzl", "parse_cmake_link_libraries")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "apply_overlay_substitutions",
    "find_hardcoded_hub_dep",
    "find_hardcoded_language_version",
    "flavor_restrictions",
    "has_removed_hub_placeholder",
    "make_android_subpackage_build_content",
    "make_dart_member_build_content",
    "make_flutter_member_build_content",
    "own_lib_path",
    "parse_android_manifest_package",
    "parse_gradle_android_namespace",
    "removed_hub_placeholder_error",
    "render_overlay_deps",
)

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
        'android_build_config(\n    name = "_build_config",\n    package = "com.llfbandit.record",' in content,
        "expected BuildConfig against the plugin namespace in:\n" + content,
    )

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
    # One engine target for every plugin, and the BuildConfig compiled with
    # the plugin's own sources, as Gradle compiles it in the module.
    asserts.true(env, '["@rules_flutter//flutter/private/android:plugin_engine"]' in content, content)
    asserts.true(env, '+ [":_build_config"],' in content, content)
    asserts.false(env, "flutter_android_engine(" in content, content)
    asserts.false(
        env,
        "@rules_flutter_maven//:androidx" in content,
        "androidx deps must flow via the engine's exports, not be " +
        "restated per plugin:\n" + content,
    )

    return unittest.end(env)

record_android_subpackage_test = unittest.make(_record_android_subpackage_test_impl)

def _annotated_deps_test_impl(ctx):
    """`flutter_pub.annotation(android_deps)` land in the library's `deps`."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "dev.example.annotated",
        annotated_deps = ["@@maven//:androidx_browser_browser"],
    )
    asserts.true(env, '+ ["@@maven//:androidx_browser_browser"]' in content, content)
    return unittest.end(env)

annotated_deps_test = unittest.make(_annotated_deps_test_impl)

def _resources_without_manifest_test_impl(ctx):
    """Resources force a manifest: synthesize one when the plugin ships none."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "dev.example.res_only_manifestless",
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
    asserts.true(
        env,
        'package="dev.example.res_only_manifestless">' in content,
        content,
    )

    # Written by Starlark, with the same bytes on every host: no shell.
    asserts.true(env, 'name = "_manifest"' in content, content)
    asserts.true(env, "write_file(" in content, content)
    asserts.false(env, "genrule" in content, content)
    asserts.false(env, "exports_manifest" in content, content)

    return unittest.end(env)

resources_without_manifest_test = unittest.make(_resources_without_manifest_test_impl)

def _no_resources_subpackage_test_impl(ctx):
    """url_launcher_android shape: sources + manifest, no res/."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "io.flutter.plugins.urllauncher",
        maven_deps = [
            {"kind": "deps", "coordinate": "androidx.browser:browser", "version": "1.8.0", "line": ""},
            {"kind": "compile_only", "coordinate": "androidx.annotation:annotation", "version": None, "line": ""},
            {"kind": "runtime", "coordinate": "androidx.core:core", "version": None, "line": ""},
        ],
        android_manifest = "android/src/main/AndroidManifest.xml",
        has_resources = False,
    )

    asserts.false(env, "resource_files" in content, content)
    asserts.false(env, "check()" in content, "the spoke runs no build-wide check:\n" + content)
    for needle in [
        'load("@flutter_pub_android_maven//:resolved.bzl", "RESOLVED")',
        'load("@rules_flutter//flutter/private:android_plugin_maven.bzl", "maven_labels")',
        "_maven = maven_labels(",
        ", RESOLVED)",
        "deps = [\"@rules_flutter//flutter/private/android:plugin_engine\"] + _maven.deps + [\":_compile_only\"],",
        "runtime_deps = _maven.runtime_deps,",
        "exports = _maven.compile_only,",
        "neverlink = True,",
    ]:
        asserts.true(env, needle in content, needle + " missing:\n" + content)

    return unittest.end(env)

no_resources_subpackage_test = unittest.make(_no_resources_subpackage_test_impl)

def _member_exports_android_lib_test_impl(ctx):
    """A member lists its Android library under `exports` on Android only, and only if it has one.

    So a non-Android build never loads `android/BUILD.bazel`, and a package
    with no Android code has no such package to load.
    """
    env = unittest.begin(ctx)

    with_lib = make_flutter_member_build_content(
        name = "some_android_plugin",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        plugin_platforms = {},
        has_android_lib = True,
    )
    asserts.true(
        env,
        'exports = select({\n        "@platforms//os:android": ["//android:lib"],\n        "//conditions:default": [],\n    }),' in with_lib,
        with_lib,
    )

    without = make_flutter_member_build_content(
        name = "some_apple_plugin",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        plugin_platforms = {},
    )
    asserts.false(env, "exports" in without, without)

    return unittest.end(env)

member_exports_android_lib_test = unittest.make(_member_exports_android_lib_test_impl)

def _member_declares_fonts_and_platforms_test_impl(ctx):
    """A member's fonts and plugin platforms are targets it lists, one for each.

    A font with no weight, style or `asset` is its file in the family; the
    rest are `flutter_font`s. Each `flutter.plugin.platforms` entry is a
    `flutter_plugin_platform` with its keys in snake case and its library,
    and keys flutter_tools does not read on that platform are left out.
    """
    env = unittest.begin(ctx)

    content = make_flutter_member_build_content(
        name = "p",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        plugin_platforms = {
            "android": {"package": "com.example.p", "pluginClass": "PPlugin"},
            "ios": {"dartPluginClass": "PIos", "dartFileName": "p_ios.dart", "sharedDarwinSource": True},
            "ohos": {"pluginClass": "Unknown"},
            "web": {"fileName": "p_web.dart", "package": "ignored", "pluginClass": "PWeb"},
        },
        apple_libs = {"ios": "@flutter_pub_apple__p//:p_apple_ios"},
        android_group = "com.example.group",
        fonts = [
            struct(family = "Plain", fonts = [struct(src = ":fonts/a.ttf", asset = None, weight = None, style = None)]),
            struct(family = "Borrowed", fonts = [struct(src = ":_fonts_of_other_packages/o/b.ttf", asset = "packages/o/b.ttf", weight = 700, style = "italic")]),
        ],
    )
    for part in [
        '    platforms = [\n        ":plugin_android",\n        ":plugin_ios",\n        ":plugin_web",\n    ],',
        'flutter_plugin_platform(\n    name = "plugin_android",\n    group = "com.example.group",\n    package = "com.example.p",\n    platform = "android",\n    plugin_class = "PPlugin",\n)',
        'flutter_plugin_platform(\n    name = "plugin_ios",\n    dart_file_name = "p_ios.dart",\n    dart_plugin_class = "PIos",\n    lib = "@flutter_pub_apple__p//:p_apple_ios",\n    platform = "ios",\n)',
        'flutter_plugin_platform(\n    name = "plugin_web",\n    file_name = "p_web.dart",\n    platform = "web",\n    plugin_class = "PWeb",\n)',
        '    fonts = [\n        ":font_family_0",\n        ":font_family_1",\n    ],',
        'flutter_font_family(\n    name = "font_family_0",\n    family = "Plain",\n    fonts = [\n        ":fonts/a.ttf",\n    ],\n)',
        'flutter_font(\n    name = "font_family_1_0",\n    asset = "packages/o/b.ttf",\n    src = ":_fonts_of_other_packages/o/b.ttf",\n    style = "italic",\n    weight = 700,\n)',
        'flutter_font_family(\n    name = "font_family_1",\n    family = "Borrowed",\n    fonts = [\n        ":font_family_1_0",\n    ],\n)',
    ]:
        asserts.true(env, part in content, "%r not in:\n%s" % (part, content))
    asserts.false(env, "Unknown" in content, content)
    asserts.false(env, "sharedDarwinSource" in content or "shared_darwin" in content, content)
    return unittest.end(env)

member_declares_fonts_and_platforms_test = unittest.make(_member_declares_fonts_and_platforms_test_impl)

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

    plugin = make_flutter_member_build_content(
        name = "sqlite3_web",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        plugin_platforms = {"web": {"pluginClass": "WebPlugin"}},
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
        version = "2.2.0",
    )
    asserts.true(env, '\n    version = "2.2.0",' in plugin, plugin)

    library = make_flutter_member_build_content(
        name = "cupertino_icons",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        assets = [],
        shaders = [],
        version = "1.0.8",
    )
    asserts.true(env, '\n    version = "1.0.8",' in library, library)

    # Both are members, not libraries: they state no dependencies, which belong
    # to the library of the package's dependency cycle.
    asserts.true(env, "\nflutter_pub_member(" in plugin, plugin)
    asserts.true(env, "\nflutter_pub_member(" in library, library)
    asserts.false(env, "deps" in plugin, plugin)
    asserts.false(env, "deps" in library, library)

    # A pure-Dart package is rules_dart's own member kind, and states its
    # version too.
    dart = make_dart_member_build_content(
        name = "meta",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        version = "1.17.0",
    )
    asserts.true(env, "\npub_package_member(" in dart, dart)
    asserts.true(env, '\n    version = "1.17.0",' in dart, dart)
    asserts.true(env, _RESOURCES_GLOB in dart, dart)

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

    library = make_flutter_member_build_content(
        name = "cupertino_icons",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        assets = [],
        shaders = [],
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

    content = make_flutter_member_build_content(
        name = "sqlite3_web",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        plugin_platforms = {"web": {"pluginClass": "WebPlugin"}},
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
    while `assets`/`shaders` say it is bundled into flutter_assets.
    A shader under `lib/` is legitimately both.
    """
    env = unittest.begin(ctx)

    content = make_flutter_member_build_content(
        name = "shader_pkg",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        assets = [],
        shaders = [":lib/glow.frag"],
    )

    asserts.true(env, _RESOURCES_GLOB in content, content)
    asserts.true(env, "\n    shaders = [" in content, content)

    return unittest.end(env)

library_spoke_carries_resources_test = unittest.make(_library_spoke_carries_resources_test_impl)

def _file_names_are_written_as_string_literals_test_impl(ctx):
    """A file name never becomes BUILD syntax: it is quoted, whatever it holds.

    A name comes from a package's pubspec (or its directory listing). Spliced
    into the BUILD file between bare quotes, `a"+fail("x")+".txt` would end the
    string and run as code in the spoke's repository.
    """
    env = unittest.begin(ctx)

    name = 'assets/a"+fail("x")+".txt'
    for content in [
        make_flutter_member_build_content(
            name = "p",
            language_version = "3.4",
            code_assets = [],
            unreplaced_hook = "",
            fonts = [struct(family = "F", fonts = [struct(src = ":" + name, asset = None, weight = 700, style = None)])],
            assets = [":" + name],
            shaders = [":" + name],
        ),
        make_flutter_member_build_content(
            name = "p",
            language_version = "3.4",
            code_assets = [],
            unreplaced_hook = "",
            plugin_platforms = {},
            apple_libs = {"macos": "@flutter_pub_apple__p//:p_apple_macos"},
            apple_macos_privacy_manifests = [name],
            apple_ios_privacy_manifests = [],
            linux_src_dir = "",
            windows_src_dir = "",
            assets = [":" + name],
        ),
    ]:
        asserts.true(env, repr(":" + name) in content or repr(name) in content, content)
        asserts.false(env, '"' + name in content, content)
    return unittest.end(env)

file_names_are_written_as_string_literals_test = unittest.make(
    _file_names_are_written_as_string_literals_test_impl,
)

def _spoke_with_shaders_declares_their_includes_test_impl(ctx):
    """A spoke with shaders lists its GLSL as what they may `#include`.

    The compile runs sandboxed with only declared inputs, so a shader that
    includes a sibling `.glsl` fails unless the spoke declares it.
    """
    env = unittest.begin(ctx)

    def content(shaders):
        return make_flutter_member_build_content(
            name = "shader_pkg",
            language_version = "3.4",
            code_assets = [],
            unreplaced_hook = "",
            assets = [],
            shaders = shaders,
        )

    with_shaders = content([":shaders/glow.frag"])
    asserts.true(env, "shader_includes = glob(" in with_shaders, with_shaders)
    asserts.true(env, '"**/*.glsl"' in with_shaders, with_shaders)
    asserts.false(env, "shader_includes" in content([]))

    return unittest.end(env)

spoke_with_shaders_declares_their_includes_test = unittest.make(_spoke_with_shaders_declares_their_includes_test_impl)

def _own_lib_path_test_impl(ctx):
    """A file entry `packages/<self>/x` is the package's lib/x, unless a file is at the path as written."""
    env = unittest.begin(ctx)
    asserts.equals(env, "shaders/ink_sparkle.frag", own_lib_path("material_ui", "packages/material_ui/shaders/ink_sparkle.frag", False))
    asserts.equals(env, None, own_lib_path("material_ui", "packages/material_ui/shaders/ink_sparkle.frag", True))
    asserts.equals(env, None, own_lib_path("glass_plugin", "shaders/tint.frag", False))

    # Another package's prefix is not this package's lib/.
    asserts.equals(env, None, own_lib_path("glass_plugin", "packages/material_ui/x.png", False))
    asserts.equals(env, None, own_lib_path("material", "packages/material_ui/x.png", False))
    return unittest.end(env)

own_lib_path_test = unittest.make(_own_lib_path_test_impl)

def _overlay_substitutes_the_language_version_test_impl(ctx):
    """An overlay declares the language version by placeholder, never by value.

    The package's own `environment.sdk` is the single source of truth; the
    spoke derives from it and substitutes here. A template that spelled the
    version out would be a second declaration of the same fact, and the
    version ladder makes the two drift silently: `flutter/ext/objective_c/9/` matches
    every 9.x, so a release that raises the SDK floor keeps the stale literal.
    """
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = 'flutter_plugin(name = "{PKG}", language_version = "{LANGUAGE_VERSION}", v = "{VERSION}", h = "x")',
        package_name = "objective_c",
        version = "9.3.0",
        language_version = "3.10",
        deps = "",
    )

    asserts.equals(
        env,
        'flutter_plugin(name = "objective_c", language_version = "3.10", v = "9.3.0", h = "x")',
        rendered,
    )

    return unittest.end(env)

def _overlay_without_a_language_version_is_left_alone_test_impl(ctx):
    """Not every overlay declares one; substitution must not invent the attribute."""
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = 'cc_library(name = "{PKG}")',
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

def _members_state_their_license_file_test_impl(ctx):
    """Both member kinds name the package's licence, and say nothing without one."""
    env = unittest.begin(ctx)

    dart = make_dart_member_build_content("meta", "3.4", [], "", license_file = "LICENSE")
    asserts.true(env, '\n    license_file = "LICENSE",' in dart, dart)
    flutter = make_flutter_member_build_content("cupertino_icons", "3.4", [], "", license_file = "NOTICES")
    asserts.true(env, '\n    license_file = "NOTICES",' in flutter, flutter)

    asserts.false(env, "license_file" in make_dart_member_build_content("meta", "3.4", [], ""))
    asserts.false(env, "license_file" in make_flutter_member_build_content("cupertino_icons", "3.4", [], ""))

    return unittest.end(env)

members_state_their_license_file_test = unittest.make(_members_state_their_license_file_test_impl)

def _members_name_their_package_metadata_test_impl(ctx):
    """Both member kinds state the package's facts on a `dart_package_metadata` they name."""
    env = unittest.begin(ctx)

    dart = make_dart_member_build_content("meta", "3.4", ["//:meta_asset"], "hook/build.dart", version = "1.17.0", link_hook = "hook/link.dart")
    flutter = make_flutter_member_build_content("cupertino_icons", "3.4", [], "", version = "1.0.8")
    for content in [dart, flutter]:
        asserts.true(env, 'load("@rules_dart//dart:defs.bzl", "dart_package_metadata")' in content, content)
        asserts.true(env, '\ndart_package_metadata(\n    name = "pubspec-metadata",\n' in content, content)
        asserts.true(env, '\n    package = ":pubspec-metadata",' in content, content)
        asserts.false(env, "\n    package_name = " in content.split("dart_package_metadata(")[1].split(")\n")[1], content)
    asserts.true(env, '\n    package_name = "meta",\n    language_version = "3.4",\n    version = "1.17.0",' in dart, dart)
    asserts.true(env, '\n    build_hook = "hook/build.dart",' in dart, dart)
    asserts.true(env, '\n    link_hook = "hook/link.dart",' in dart, dart)
    asserts.true(env, '\n        "//:meta_asset",' in dart, dart)

    # The package called `pubspec` has a library of that name, beside the
    # declaration, whose name no package can have.
    named_pubspec = make_dart_member_build_content("pubspec", "3.4", [], "")
    asserts.true(env, '\n    name = "pubspec",' in named_pubspec, named_pubspec)
    asserts.true(env, '\n    name = "pubspec-metadata",' in named_pubspec, named_pubspec)
    asserts.true(env, '\n    package = ":pubspec-metadata",' in named_pubspec, named_pubspec)

    return unittest.end(env)

members_name_their_package_metadata_test = unittest.make(_members_name_their_package_metadata_test_impl)

def _overlay_substitutes_the_license_test_impl(ctx):
    """An overlay's `{LICENSE}` becomes the attribute line, or its line goes."""
    env = unittest.begin(ctx)

    template = 'flutter_plugin(\n    name = "{PKG}",\n    {LICENSE}\n    visibility = [],\n)'
    args = dict(package_name = "jni", version = "1.0.0", language_version = "3.4", deps = "")

    asserts.equals(
        env,
        'flutter_plugin(\n    name = "jni",\n    license_file = "LICENSE",\n    visibility = [],\n)',
        apply_overlay_substitutions(template, license_file = "LICENSE", **args),
    )
    asserts.equals(
        env,
        'flutter_plugin(\n    name = "jni",\n    visibility = [],\n)',
        apply_overlay_substitutions(template, **args),
    )

    return unittest.end(env)

overlay_substitutes_the_license_test = unittest.make(_overlay_substitutes_the_license_test_impl)

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
        package_name = "objective_c",
        version = "9.6.0",
        language_version = "3.10",
        deps = render_overlay_deps([
            "@flutter_pub__ffi//:ffi",
            "@flutter_pub__meta//:meta",
        ]),
    )

    asserts.equals(
        env,
        'flutter_plugin(\n    deps = [\n        "@flutter_pub__ffi//:ffi",\n        "@flutter_pub__meta//:meta",\n    ],\n)',
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
    `flutter/ext/objective_c/9/` — one directory for the whole major — kept asking
    for `@<hub>__native_toolchain_c` (a repository per hub, as it was then). The build died on an unknown repo
    naming neither `objective_c` nor the overlay that referenced it.
    """
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "@flutter_pub__native_toolchain_c//:native_toolchain_c",
        find_hardcoded_hub_dep(
            '    deps = [\n        "@flutter_pub__native_toolchain_c//:native_toolchain_c",\n    ],',
        ),
    )
    asserts.equals(
        env,
        "@flutter_pub_lib__ffi//:ffi",
        find_hardcoded_hub_dep('    deps = ["@flutter_pub_lib__ffi//:ffi"],'),
    )

    # The placeholder is the one accepted spelling.
    asserts.equals(env, "", find_hardcoded_hub_dep("    deps = [\n        {DEPS}\n    ],"))

    # Naming a repository outside a label — a doc comment, say — is not the
    # thing being prohibited.
    asserts.equals(env, "", find_hardcoded_hub_dep("# the flutter_pub repositories are named here."))

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

def _desktop_plugin_libraries_carry_their_link_libraries_test_impl(ctx):
    """A plugin's CMake link libraries reach its generated library targets."""
    env = unittest.begin(ctx)

    windows = parse_cmake_link_libraries(
        "add_library(p SHARED a.cpp)\ntarget_link_libraries(p PRIVATE flutter shlwapi.lib ${vars})\n",
        "windows",
        "windows/CMakeLists.txt",
    )
    linux = parse_cmake_link_libraries(
        "add_library(p SHARED a.cc)\ntarget_link_libraries(p PRIVATE flutter PkgConfig::GTK)\n",
        "linux",
        "linux/CMakeLists.txt",
    )
    content = make_flutter_member_build_content(
        name = "url_launcher_windows",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        plugin_platforms = {"linux": {"pluginClass": "UrlLauncherLinux"}, "windows": {"pluginClass": "UrlLauncherWindows"}},
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "linux",
        windows_src_dir = "windows",
        linux_link = linux,
        windows_link = windows,
    )
    windows_target = content[content.index("flutter_windows_plugin_library("):]
    asserts.true(env, '    linkopts = ["shlwapi.lib"],\n' in windows_target, content)
    asserts.true(
        env,
        '    link_errors = ["windows/CMakeLists.txt:2: `${vars}` is a CMake variable that this file does not set once, outside any block, to literal values before this call"],\n' in windows_target,
        content,
    )

    # The Linux library needs nothing the runner does not link already, so it
    # states neither attribute.
    linux_target = content[content.index("flutter_linux_plugin_library("):content.index("flutter_windows_plugin_library(")]
    asserts.false(env, "linkopts" in linux_target, linux_target)
    asserts.false(env, "link_errors" in linux_target, linux_target)

    return unittest.end(env)

desktop_plugin_libraries_carry_their_link_libraries_test = unittest.make(
    _desktop_plugin_libraries_carry_their_link_libraries_test_impl,
)

def _platform_restricted_assets_are_stated_in_the_spoke_test_impl(ctx):
    """An asset a `platforms:` entry restricts is stated with its platforms."""
    env = unittest.begin(ctx)

    content = make_flutter_member_build_content(
        name = "restricted",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        assets = [":assets/a.txt", ":assets/b.txt"],
        shaders = [],
        asset_platforms = {"assets/a.txt": ["android", "web"]},
    )

    asserts.true(env, "asset_platforms" in content, content)
    asserts.true(env, '"assets/a.txt": ["android", "web"]' in content, content)
    asserts.false(env, '"assets/b.txt": [' in content, content)

    return unittest.end(env)

platform_restricted_assets_are_stated_in_the_spoke_test = unittest.make(
    _platform_restricted_assets_are_stated_in_the_spoke_test_impl,
)

def _platform_restricted_shaders_are_stated_in_the_spoke_test_impl(ctx):
    """A shader a `platforms:` entry restricts is stated with its platforms."""
    env = unittest.begin(ctx)

    content = make_flutter_member_build_content(
        name = "restricted",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        assets = [],
        shaders = [":shaders/a.frag", ":shaders/b.frag"],
        shader_platforms = {"shaders/a.frag": ["android", "web"]},
    )

    asserts.true(env, "shader_platforms" in content, content)
    asserts.true(env, '"shaders/a.frag": ["android", "web"]' in content, content)
    asserts.false(env, '"shaders/b.frag": [' in content, content)

    return unittest.end(env)

platform_restricted_shaders_are_stated_in_the_spoke_test = unittest.make(
    _platform_restricted_shaders_are_stated_in_the_spoke_test_impl,
)

def _flavor_restricted_assets_are_stated_in_the_spoke_test_impl(ctx):
    """An asset a `flavors:` entry restricts is stated with its flavors."""
    env = unittest.begin(ctx)

    content = make_flutter_member_build_content(
        name = "restricted",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        assets = [":assets/a.txt", ":assets/b.txt"],
        shaders = [],
        asset_flavors = {"assets/a.txt": ["paid", "premium"]},
    )

    asserts.true(env, "asset_flavors" in content, content)
    asserts.true(env, '"assets/a.txt": ["paid", "premium"]' in content, content)
    asserts.false(env, '"assets/b.txt": [' in content, content)

    return unittest.end(env)

flavor_restricted_assets_are_stated_in_the_spoke_test = unittest.make(
    _flavor_restricted_assets_are_stated_in_the_spoke_test_impl,
)

def _flavor_restricted_shaders_are_stated_in_the_spoke_test_impl(ctx):
    """A shader a `flavors:` entry restricts is stated with its flavors."""
    env = unittest.begin(ctx)

    content = make_flutter_member_build_content(
        name = "restricted",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        assets = [],
        shaders = [":shaders/a.frag", ":shaders/b.frag"],
        shader_flavors = {"shaders/a.frag": ["paid", "premium"]},
    )

    asserts.true(env, "shader_flavors" in content, content)
    asserts.true(env, '"shaders/a.frag": ["paid", "premium"]' in content, content)
    asserts.false(env, '"shaders/b.frag": [' in content, content)

    return unittest.end(env)

flavor_restricted_shaders_are_stated_in_the_spoke_test = unittest.make(
    _flavor_restricted_shaders_are_stated_in_the_spoke_test_impl,
)

def _flavor_conflict_message_test_impl(ctx):
    """One file under entries with different flavor sets is refused, naming both entries."""
    env = unittest.begin(ctx)

    tracker = flavor_restrictions("pkg")
    asserts.equals(env, None, tracker.add("assets/a.txt", "assets/a.txt", []))
    error = tracker.add("assets/a.txt", "assets/a.txt", ["free"])

    asserts.equals(
        env,
        "package pkg: Multiple assets entries include the file \"assets/a.txt\", " +
        "but they specify different lists of flavors.\n" +
        "An entry with the path \"assets/a.txt\" does not specify any flavors.\n" +
        "An entry with the path \"assets/a.txt\" specifies the flavor(s): \"free\".",
        error,
    )

    return unittest.end(env)

flavor_conflict_message_test = unittest.make(_flavor_conflict_message_test_impl)

def _flavor_conflict_through_a_directory_entry_test_impl(ctx):
    """A conflict that involves a directory entry also suggests separate directories."""
    env = unittest.begin(ctx)

    tracker = flavor_restrictions("pkg")
    asserts.equals(env, None, tracker.add("assets/a.txt", "assets/", ["paid", "free"]))
    error = tracker.add("assets/a.txt", "assets/a.txt", ["paid"])

    asserts.true(env, "specifies the flavor(s): \"free\", \"paid\"." in error, error)
    asserts.true(env, "specifies the flavor(s): \"paid\"." in error, error)
    asserts.true(env, error.endswith("\n\nConsider organizing assets with different flavors into different directories."), error)

    return unittest.end(env)

flavor_conflict_through_a_directory_entry_test = unittest.make(
    _flavor_conflict_through_a_directory_entry_test_impl,
)

def _flavor_order_and_other_files_do_not_conflict_test_impl(ctx):
    """The same flavors in another order, or different flavors on different files, are fine."""
    env = unittest.begin(ctx)

    tracker = flavor_restrictions("pkg")
    asserts.equals(env, None, tracker.add("assets/a.txt", "assets/a.txt", ["paid", "free"]))
    asserts.equals(env, None, tracker.add("assets/a.txt", "assets/", ["free", "paid"]))
    asserts.equals(env, None, tracker.add("assets/b.txt", "assets/b.txt", ["other"]))
    asserts.equals(env, None, tracker.add("assets/c.txt", "assets/c.txt", []))

    # Only the files that are restricted are reported, with their flavors sorted.
    asserts.equals(
        env,
        {"assets/a.txt": ["free", "paid"], "assets/b.txt": ["other"]},
        tracker.flavors(),
    )

    return unittest.end(env)

flavor_order_and_other_files_do_not_conflict_test = unittest.make(
    _flavor_order_and_other_files_do_not_conflict_test_impl,
)

def _flavor_variants_inherit_the_entry_flavors_test_impl(ctx):
    """A resolution variant is recorded with its entry's flavors and is not checked."""
    env = unittest.begin(ctx)

    tracker = flavor_restrictions("pkg")
    asserts.equals(env, None, tracker.add("assets/a.png", "assets/a.png", ["paid"]))
    asserts.equals(env, None, tracker.add("assets/2.0x/a.png", "assets/a.png", ["paid"], main = False))
    asserts.equals(
        env,
        {"assets/a.png": ["paid"], "assets/2.0x/a.png": ["paid"]},
        tracker.flavors(),
    )

    return unittest.end(env)

flavor_variants_inherit_the_entry_flavors_test = unittest.make(
    _flavor_variants_inherit_the_entry_flavors_test_impl,
)

def _removed_hub_placeholder_is_refused_test_impl(ctx):
    """`{HUB_NAME}` is gone: a spoke is one repository for the whole build."""
    env = unittest.begin(ctx)

    asserts.true(env, has_removed_hub_placeholder('    deps = ["@{HUB_NAME}__x//:x"],'))
    asserts.false(env, has_removed_hub_placeholder("    deps = [\n        {DEPS}\n    ],"))
    message = removed_hub_placeholder_error("flutter/ext/x/1/BUILD.bazel.tpl")
    for fragment in ["flutter/ext/x/1/BUILD.bazel.tpl", "{HUB_NAME}", "is gone", "{DEPS}"]:
        asserts.true(env, fragment in message, fragment + " not in " + message)

    return unittest.end(env)

removed_hub_placeholder_is_refused_test = unittest.make(_removed_hub_placeholder_is_refused_test_impl)

def flutter_pub_package_test_suite(name):
    unittest.suite(
        name,
        spokes_state_their_resolved_version_test,
        spoke_without_a_version_states_none_test,
        hardcoded_language_version_is_rejected_test,
        overlay_substitutes_the_language_version_test,
        overlay_without_a_language_version_is_left_alone_test,
        overlay_substitutes_the_dependencies_test,
        overlay_substitutes_the_license_test,
        members_state_their_license_file_test,
        members_name_their_package_metadata_test,
        hardcoded_overlay_dependency_is_rejected_test,
        removed_hub_placeholder_is_refused_test,
        parse_gradle_android_namespace_test,
        parse_android_manifest_package_test,
        record_android_subpackage_test,
        resources_without_manifest_test,
        annotated_deps_test,
        no_resources_subpackage_test,
        member_exports_android_lib_test,
        member_declares_fonts_and_platforms_test,
        plugin_spoke_carries_resources_test,
        library_spoke_carries_resources_test,
        file_names_are_written_as_string_literals_test,
        spoke_with_shaders_declares_their_includes_test,
        own_lib_path_test,
        desktop_plugin_libraries_carry_their_link_libraries_test,
        platform_restricted_assets_are_stated_in_the_spoke_test,
        platform_restricted_shaders_are_stated_in_the_spoke_test,
        flavor_restricted_assets_are_stated_in_the_spoke_test,
        flavor_restricted_shaders_are_stated_in_the_spoke_test,
        flavor_conflict_message_test,
        flavor_conflict_through_a_directory_entry_test,
        flavor_order_and_other_files_do_not_conflict_test,
        flavor_variants_inherit_the_entry_flavors_test,
    )
