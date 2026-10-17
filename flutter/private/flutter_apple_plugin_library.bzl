"""Compile a Flutter plugin's Apple sources into a swift_library or xtool plugin library.

This is the rules_flutter analog of the Podfile-driven CocoaPods build a
Flutter plugin author would otherwise rely on. It wraps `swift_library`
with the platform's Flutter framework as a dep on the `rules_apple` backend,
and selects a host-agnostic `flutter_xtool_apple_plugin_library` on the
`xtool` backend so Linux -> iOS/macOS cross-builds do not require an
Apple host `@rules_swift` toolchain.

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
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo", "swift_library")
load("//flutter:providers.bzl", _FlutterApplePluginInfo = "FlutterApplePluginInfo")
load(":flutter_xtool_bundle.bzl", "flutter_darwin_xcframework_import")

FlutterApplePluginInfo = _FlutterApplePluginInfo

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

def _flutter_xtool_apple_plugin_library_impl(ctx):
    swift_files = []
    objc_files = []
    headers = []
    include_dirs = {}

    for f in ctx.files.srcs:
        if f.path.endswith(".swift"):
            swift_files.append(f)
        elif f.path.endswith(".m") or f.path.endswith(".mm") or f.path.endswith(".c") or f.path.endswith(".cc") or f.path.endswith(".cpp"):
            objc_files.append(f)
        elif f.path.endswith(".h"):
            headers.append(f)
            include_dirs[f.dirname] = True

    pkg_prefix = ctx.label.package
    for inc in ctx.attr.includes:
        if pkg_prefix:
            include_dirs["%s/%s" % (pkg_prefix, inc)] = True
        else:
            include_dirs[inc] = True

    module_name = ctx.attr.module_name if ctx.attr.module_name else ctx.label.name
    modulemap_file = ctx.actions.declare_file("%s.modulemap" % ctx.label.name)
    mm_lines = ["module %s {" % module_name]
    for h in headers:
        mm_lines.append('  header "%s"' % h.basename)
    mm_lines.append("  export *")
    mm_lines.append("}")
    ctx.actions.write(
        output = modulemap_file,
        content = "\n".join(mm_lines) + "\n",
    )

    all_plugin_files = swift_files + objc_files + headers + [modulemap_file]
    own_cc_info = CcInfo(
        compilation_context = cc_common.create_compilation_context(
            headers = depset(all_plugin_files),
            direct_public_headers = headers,
            direct_textual_headers = swift_files + objc_files + [modulemap_file],
            includes = depset(include_dirs.keys()),
        ),
    )
    dep_cc_infos = [dep[CcInfo] for dep in ctx.attr.deps if CcInfo in dep]
    merged_cc_info = cc_common.merge_cc_infos(
        direct_cc_infos = [own_cc_info],
        cc_infos = dep_cc_infos,
    )
    dep_swift_infos = [dep[SwiftInfo] for dep in ctx.attr.deps if SwiftInfo in dep]

    return [
        DefaultInfo(files = depset(all_plugin_files)),
        merged_cc_info,
        SwiftInfo(swift_infos = dep_swift_infos),
        FlutterApplePluginInfo(
            module_name = module_name,
            platform = ctx.attr.platform,
            swift_srcs = depset(swift_files),
            objc_srcs = depset(objc_files),
            headers = depset(headers),
            modulemap = modulemap_file,
            sdk_frameworks = ctx.attr.sdk_frameworks,
            sdk_dylibs = ctx.attr.sdk_dylibs,
        ),
    ]

flutter_xtool_apple_plugin_library = rule(
    implementation = _flutter_xtool_apple_plugin_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Swift, Objective-C, and header source files for the plugin.",
        ),
        "module_name": attr.string(
            default = "",
            doc = "Module name for the plugin.",
        ),
        "platform": attr.string(
            default = "macos",
            values = ["macos", "ios"],
            doc = "Target Apple platform ('ios' or 'macos').",
        ),
        "includes": attr.string_list(
            default = [],
            doc = "Header search paths relative to the package.",
        ),
        "sdk_frameworks": attr.string_list(
            default = [],
            doc = "Apple SDK frameworks to link.",
        ),
        "sdk_dylibs": attr.string_list(
            default = [],
            doc = "Apple SDK dynamic libraries to link.",
        ),
        "deps": attr.label_list(
            default = [],
            doc = "Dependencies providing CcInfo or SwiftInfo.",
        ),
    },
    provides = [
        DefaultInfo,
        CcInfo,
        SwiftInfo,
        FlutterApplePluginInfo,
    ],
    doc = "Host-agnostic Apple plugin library rule for the xtool backend.",
)

def _flutter_apple_plugin_library_target_impl(ctx):
    dep = ctx.attr.dep
    providers = [
        DefaultInfo(
            files = dep[DefaultInfo].files,
            runfiles = dep[DefaultInfo].default_runfiles,
        ),
    ]
    if CcInfo in dep:
        providers.append(dep[CcInfo])
    if SwiftInfo in dep:
        providers.append(dep[SwiftInfo])
    if OutputGroupInfo in dep:
        providers.append(dep[OutputGroupInfo])
    if FlutterApplePluginInfo in dep:
        providers.append(dep[FlutterApplePluginInfo])
    else:
        providers.append(
            FlutterApplePluginInfo(
                module_name = ctx.attr.module_name,
                platform = ctx.attr.platform,
                swift_srcs = depset(),
                objc_srcs = depset(),
                headers = depset(),
                modulemap = None,
                sdk_frameworks = ctx.attr.sdk_frameworks,
                sdk_dylibs = ctx.attr.sdk_dylibs,
            ),
        )
    return providers

_flutter_apple_plugin_library_target = rule(
    implementation = _flutter_apple_plugin_library_target_impl,
    attrs = {
        "dep": attr.label(
            mandatory = True,
            doc = "Backend-specific Apple plugin library target.",
        ),
        "module_name": attr.string(
            mandatory = True,
            doc = "Swift/Clang module name of the plugin.",
        ),
        "platform": attr.string(
            mandatory = True,
            values = ["macos", "ios"],
            doc = "Target Apple platform ('ios' or 'macos').",
        ),
        "sdk_frameworks": attr.string_list(
            default = [],
            doc = "Apple SDK frameworks linked by this plugin.",
        ),
        "sdk_dylibs": attr.string_list(
            default = [],
            doc = "Apple SDK dylibs linked by this plugin.",
        ),
    },
    provides = [
        DefaultInfo,
        CcInfo,
        SwiftInfo,
        FlutterApplePluginInfo,
    ],
    doc = "Forwards backend providers and attaches FlutterApplePluginInfo.",
)

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
        engine = None,
        visibility = None,
        tags = None,
        **kwargs):
    """Build a Flutter plugin's Apple sources into a swift_library or xtool plugin target.

    Auto-routes `.m`/`.mm` files through an internal `objc_library` and
    feeds it into the `swift_library` as a dep on `rules_apple`, while
    selecting `flutter_xtool_apple_plugin_library` under the `xtool` backend.

    Args:
        name: Target name. Pass to runner deps (or via the aspect-based
            aggregator that discovers them automatically).
        srcs: Swift, ObjC, and header source files.
        module_name: Swift module name. Defaults to `name`.
        platform: `"macos"` or `"ios"`. Picks the Flutter framework dep.
        deps: Additional swift_library / cc_library deps (other plugins).
        copts: Additional Swift compile options.
        includes: Header search paths forwarded to the inner `objc_library`.
        sdk_frameworks: Apple SDK frameworks to link (e.g. `["AVFoundation"]`).
        sdk_dylibs: Apple SDK dynamic libraries to link (e.g. `["c++"]`,
            `["sqlite3"]`).
        engine: Optional override for the Flutter engine framework label.
        visibility: Target visibility.
        tags: Bazel tags. Defaults to `["manual"]` so the spoke target
            is only built when something depends on it.
        **kwargs: Forwarded to the underlying swift_library.
    """
    if platform not in ("macos", "ios"):
        fail("flutter_apple_plugin_library: platform must be 'macos' or 'ios', got '%s'" % platform)

    if tags == None:
        tags = ["manual"]
    internal_tags = tags if "manual" in tags else tags + ["manual"]

    if module_name == None:
        module_name = name

    target_compatible_with = kwargs.pop(
        "target_compatible_with",
        ["@platforms//os:%s" % platform],
    )

    swift_files, objc_files, headers = _split_srcs(srcs)

    framework_target = "_%s__flutter_framework" % name
    framework_apple_target = "_%s__flutter_framework_apple" % name
    framework_xtool_target = "_%s__flutter_framework_xtool" % name
    if platform == "macos":
        engine_imports = [engine] if engine else [Label("@flutter_macos_engine//:engine_library")]
        apple_dynamic_framework_import(
            name = framework_apple_target,
            framework_imports = engine_imports,
            tags = internal_tags,
            target_compatible_with = target_compatible_with,
            visibility = ["//visibility:private"],
        )
        flutter_darwin_xcframework_import(
            name = framework_xtool_target,
            framework_name = "FlutterMacOS",
            xcframework_imports = engine_imports,
            tags = internal_tags,
            target_compatible_with = target_compatible_with,
            visibility = ["//visibility:private"],
        )
    else:
        engine_imports = [engine] if engine else [Label("@flutter_ios_engine//:Flutter_xcframework")]
        apple_dynamic_xcframework_import(
            name = framework_apple_target,
            xcframework_imports = engine_imports,
            tags = internal_tags,
            target_compatible_with = target_compatible_with,
            visibility = ["//visibility:private"],
        )
        flutter_darwin_xcframework_import(
            name = framework_xtool_target,
            framework_name = "Flutter",
            xcframework_imports = engine_imports,
            tags = internal_tags,
            target_compatible_with = target_compatible_with,
            visibility = ["//visibility:private"],
        )

    native.alias(
        name = framework_target,
        actual = select({
            Label("@rules_flutter//flutter/settings:use_xtool_backend"): ":" + framework_xtool_target,
            "//conditions:default": ":" + framework_apple_target,
        }),
        tags = internal_tags,
        visibility = ["//visibility:private"],
    )

    swift_deps = [":" + framework_target] + list(deps)

    objc_module_name = ""
    if objc_files:
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
            tags = internal_tags,
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

    if not swift_files:
        placeholder_target = "_%s__swift_placeholder" % name
        placeholder_file = "_%s__placeholder.swift" % name
        placeholder_content = ["// GENERATED — re-exports the ObjC module so Swift `import %s` works." % module_name]
        if objc_module_name:
            placeholder_content.append("@_exported import %s" % objc_module_name)
        write_file(
            name = placeholder_target,
            out = placeholder_file,
            content = placeholder_content,
            tags = internal_tags,
            target_compatible_with = target_compatible_with,
        )
        swift_files = [":" + placeholder_target]

    apple_target = "_%s__apple" % name
    xtool_target = "_%s__xtool" % name

    swift_library(
        name = apple_target,
        srcs = swift_files,
        module_name = module_name,
        copts = extra_copts,
        deps = swift_deps,
        swiftc_inputs = [bridging_header] if bridging_header else [],
        tags = internal_tags,
        target_compatible_with = target_compatible_with,
        visibility = ["//visibility:private"],
        **kwargs
    )

    flutter_xtool_apple_plugin_library(
        name = xtool_target,
        srcs = srcs,
        module_name = module_name,
        platform = platform,
        includes = includes,
        sdk_frameworks = sdk_frameworks,
        sdk_dylibs = sdk_dylibs,
        deps = [":" + framework_xtool_target] + list(deps),
        tags = internal_tags,
        target_compatible_with = target_compatible_with,
        visibility = ["//visibility:private"],
    )

    _flutter_apple_plugin_library_target(
        name = name,
        dep = select({
            Label("@rules_flutter//flutter/settings:use_xtool_backend"): ":" + xtool_target,
            "//conditions:default": ":" + apple_target,
        }),
        module_name = module_name,
        platform = platform,
        sdk_frameworks = sdk_frameworks,
        sdk_dylibs = sdk_dylibs,
        tags = tags,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
    )
