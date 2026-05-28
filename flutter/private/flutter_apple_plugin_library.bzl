"""Compile a Flutter plugin's Apple sources into a swift_library.

This is the rules_flutter analog of the Podfile-driven CocoaPods build a
Flutter plugin author would otherwise rely on. It wraps `swift_library`
with the platform's Flutter framework as a dep, and routes any `.m`/
`.mm` ObjC sources through `objc_library`.

Public Tier-2 API: re-exported from `flutter/macos.bzl` and
`flutter/ios.bzl` so users can wire a monorepo plugin's BUILD.bazel
without going through the `ext/` overlay system.

Usage:

    flutter_apple_plugin_library(
        name = "my_plugin_apple_macos",
        srcs = glob(["macos/Classes/**/*.swift"]),
        module_name = "my_plugin",
        platform = "macos",
    )
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_dynamic_xcframework_import")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_swift//swift:swift.bzl", "swift_library")

def _split_srcs(srcs):
    """Split srcs into (swift_files, objc_files, headers).

    Returns lists by extension so we can route ObjC through objc_library
    while keeping Swift on swift_library.
    """
    swift_files = []
    objc_files = []
    headers = []
    for f in srcs:
        if f.endswith(".swift"):
            swift_files.append(f)
        elif f.endswith(".m") or f.endswith(".mm"):
            objc_files.append(f)
        elif f.endswith(".h"):
            headers.append(f)
    return swift_files, objc_files, headers

def flutter_apple_plugin_library(
        name,
        srcs = [],
        module_name = None,
        platform = "macos",
        deps = [],
        copts = [],
        includes = [],
        sdk_frameworks = [],
        sdk_dylibs = [],
        visibility = None,
        tags = None,
        **kwargs):
    """Build a Flutter plugin's Apple sources into a swift_library.

    Auto-routes `.m`/`.mm` files through an internal `objc_library` and
    feeds it into the `swift_library` as a dep. Bridging-header support:
    when `<module_name>-Bridging-Header.h` is present in `srcs`, it's
    passed via the swift_library's `swiftc_inputs` and a `-import-
    objc-header` copt.

    Args:
        name: Target name. Pass to runner deps (or via the aspect-based
            aggregator that discovers them automatically).
        srcs: Swift, ObjC, and header source files.
        module_name: Swift module name. Defaults to `name`.
        platform: `"macos"` or `"ios"`. Picks the Flutter framework dep.
        deps: Additional swift_library / cc_library deps (other plugins).
        copts: Additional Swift compile options.
        includes: Header search paths forwarded to the inner
            `objc_library`. Mirrors `objc_library.includes` semantics —
            each entry becomes `-I <package>/<entry>` for both the
            ObjC compile and downstream consumers, matching SwiftPM's
            `publicHeadersPath` behavior. Required for plugins that
            follow SwiftPM's canonical layout (header at
            `Sources/<pkg>/include/<pkg>/Foo.h`, `.m` does bare-basename
            `#import "Foo.h"`); without the include path the .m's import
            fails with `'Foo.h' file not found`.
        sdk_frameworks: Apple SDK frameworks to link (e.g. `["AVFoundation"]`).
            Forwarded to the inner `objc_library`. Required when the plugin's
            ObjC sources `#import <Foo/Bar.h>` against an Apple SDK
            framework — Clang's `enable_modules` auto-link metadata
            (`LC_LINKER_OPTION`) is stripped by Apple's `libtool` static-archive
            step, so explicit declaration is the only reliable path. When the
            plugin declares its frameworks in `Package.swift`'s
            `linkerSettings.linkedFramework` they are auto-detected by
            `flutter_pub_package`; otherwise users supply them here (typically
            via an `ext/<pkg>/<major>/BUILD.bazel.tpl` overlay).
        sdk_dylibs: Apple SDK dynamic libraries to link (e.g. `["c++"]`,
            `["sqlite3"]`). Forwarded to the inner `objc_library`. Same
            rationale as `sdk_frameworks`; auto-detected from
            `linkerSettings.linkedLibrary` when present.
        visibility: Target visibility.
        tags: Bazel tags. Defaults to `["manual"]` so the spoke target
            is only built when something depends on it.
        **kwargs: Forwarded to the underlying swift_library.
    """
    if platform not in ("macos", "ios"):
        fail("flutter_apple_plugin_library: platform must be 'macos' or 'ios', got '%s'" % platform)

    if tags == None:
        tags = ["manual"]

    if module_name == None:
        module_name = name

    # Both per-platform plugin spokes share the same module_name (so the
    # registrant's `import <module>` resolves identically on each platform).
    # Without target_compatible_with, both swift_library targets analyze in
    # the same configuration and produce conflicting `<module>.swiftmodule`
    # outputs. Constrain each to its OS so only one is reachable per build.
    target_compatible_with = ["@platforms//os:%s" % platform]

    swift_files, objc_files, headers = _split_srcs(srcs)

    # The Flutter framework is loaded at runtime (extracted via
    # flutter_macos_engine / flutter_ios_engine elsewhere). For
    # compile-time symbol resolution we depend on a framework import that
    # brings in the framework headers. macOS ships a dynamic framework;
    # iOS ships an xcframework wrapper.
    framework_target = "_%s__flutter_framework" % name
    if platform == "macos":
        apple_dynamic_framework_import(
            name = framework_target,
            framework_imports = ["@flutter_macos_engine//:engine_library"],
            tags = tags,
            target_compatible_with = target_compatible_with,
            visibility = ["//visibility:private"],
        )
    else:
        apple_dynamic_xcframework_import(
            name = framework_target,
            xcframework_imports = ["@flutter_ios_engine//:Flutter_xcframework"],
            tags = tags,
            target_compatible_with = target_compatible_with,
            visibility = ["//visibility:private"],
        )

    swift_deps = [":" + framework_target] + list(deps)

    objc_module_name = ""
    if objc_files:
        # Compile ObjC pieces in their own objc_library and feed into the
        # swift_library so `.m`/`.mm` sources are linked into the plugin
        # module via the produced CcInfo. The objc_library also needs the
        # Flutter framework for `#import <FlutterMacOS/FlutterMacOS.h>` etc.
        # Set module_name so the swift_library can `@_exported import` the
        # ObjC module — this makes ObjC classes (e.g. FPPPackageInfoPlusPlugin)
        # visible to Swift consumers that `import <module_name>`.
        objc_target = "_%s__objc" % name
        objc_module_name = "%s_objc" % module_name
        objc_library(
            name = objc_target,
            srcs = objc_files,
            hdrs = headers,
            includes = includes,
            sdk_frameworks = sdk_frameworks,
            sdk_dylibs = sdk_dylibs,
            module_name = objc_module_name,
            enable_modules = True,
            copts = copts,
            deps = [":" + framework_target],
            tags = tags,
            target_compatible_with = target_compatible_with,
            visibility = ["//visibility:private"],
        )
        swift_deps.append(":" + objc_target)

    bridging_header = None
    extra_copts = list(copts)
    for h in headers:
        if h.endswith("%s-Bridging-Header.h" % module_name):
            bridging_header = h
            extra_copts.extend([
                "-import-objc-header",
                "$(execpath %s)" % h,
            ])
            break

    # swift_library requires non-empty srcs. ObjC-only plugins (e.g.
    # package_info_plus's `.m`-only macOS impl) get a synthetic placeholder
    # Swift file. The Swift module is essentially empty; the ObjC interface
    # reaches Swift consumers via the objc_library dep's clang module map.
    if not swift_files:
        # ObjC-only plugin: emit a placeholder Swift file that
        # `@_exported import`s the ObjC module so consumers that
        # `import <module_name>` see the ObjC classes.
        placeholder_target = "_%s__swift_placeholder" % name
        placeholder_file = "_%s__placeholder.swift" % name
        placeholder_content = ["// GENERATED — re-exports the ObjC module so Swift `import %s` works." % module_name]
        if objc_module_name:
            placeholder_content.append("@_exported import %s" % objc_module_name)
        write_file(
            name = placeholder_target,
            out = placeholder_file,
            content = placeholder_content,
            tags = tags,
            target_compatible_with = target_compatible_with,
        )
        swift_files = [":" + placeholder_target]

    swift_library(
        name = name,
        srcs = swift_files,
        module_name = module_name,
        copts = extra_copts,
        deps = swift_deps,
        swiftc_inputs = [bridging_header] if bridging_header else [],
        tags = tags,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
        **kwargs
    )
