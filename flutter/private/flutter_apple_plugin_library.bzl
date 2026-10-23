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
load("//flutter:providers.bzl", "FlutterDarwinFrameworkInfo", _FlutterApplePluginInfo = "FlutterApplePluginInfo")
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

def _classify_plugin_srcs(files):
    """Split rule srcs into a struct of swift, objc and header Files plus include dirs."""
    swift_files = []
    objc_files = []
    headers = []
    include_dirs = {}
    for f in files:
        if f.path.endswith(".swift"):
            swift_files.append(f)
        elif f.path.endswith(".m") or f.path.endswith(".mm") or f.path.endswith(".c") or f.path.endswith(".cc") or f.path.endswith(".cpp"):
            objc_files.append(f)
        elif f.path.endswith(".h"):
            headers.append(f)
            include_dirs[f.dirname] = True
    return struct(swift = swift_files, objc = objc_files, headers = headers, include_dirs = include_dirs)

def _plugin_include_dirs(package, includes, include_dirs):
    """Fold package-relative `includes` into the header-dir set from sources."""
    for inc in includes:
        if package:
            include_dirs["%s/%s" % (package, inc)] = True
        else:
            include_dirs[inc] = True
    return include_dirs

def _write_plugin_modulemap(ctx, module_name, headers):
    """Write the plugin's modulemap covering its headers."""
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
    return modulemap_file

def _collect_plugin_dep_infos(ctx):
    """Collect CcInfo, SwiftInfo and framework files from the plugin's deps."""
    return struct(
        cc_infos = [dep[CcInfo] for dep in ctx.attr.deps if CcInfo in dep],
        swift_infos = [dep[SwiftInfo] for dep in ctx.attr.deps if SwiftInfo in dep],
        framework_files = [
            dep[FlutterDarwinFrameworkInfo].framework_files
            for dep in ctx.attr.deps
            if FlutterDarwinFrameworkInfo in dep and not dep.label.name.endswith("__flutter_framework")
        ],
    )

def _merge_plugin_sdk_lists(ctx, sdk_frameworks, sdk_dylibs):
    """Union the rule's SDK frameworks/dylibs with the ones plugin deps declare."""
    frameworks = list(sdk_frameworks)
    dylibs = list(sdk_dylibs)
    for dep in ctx.attr.deps:
        if FlutterApplePluginInfo in dep:
            for fw in dep[FlutterApplePluginInfo].sdk_frameworks:
                if fw not in frameworks:
                    frameworks.append(fw)
            for dylib in dep[FlutterApplePluginInfo].sdk_dylibs:
                if dylib not in dylibs:
                    dylibs.append(dylib)
    return frameworks, dylibs

def _flutter_xtool_apple_plugin_library_impl(ctx):
    srcs = _classify_plugin_srcs(ctx.files.srcs)
    include_dirs = _plugin_include_dirs(ctx.label.package, ctx.attr.includes, srcs.include_dirs)

    module_name = ctx.attr.module_name if ctx.attr.module_name else ctx.label.name
    modulemap_file = _write_plugin_modulemap(ctx, module_name, srcs.headers)

    all_plugin_files = srcs.swift + srcs.objc + srcs.headers + [modulemap_file]
    own_cc_info = CcInfo(
        compilation_context = cc_common.create_compilation_context(
            headers = depset(all_plugin_files),
            direct_public_headers = srcs.headers,
            direct_textual_headers = srcs.swift + srcs.objc + [modulemap_file],
            includes = depset(include_dirs.keys()),
        ),
    )
    dep_infos = _collect_plugin_dep_infos(ctx)
    merged_cc_info = cc_common.merge_cc_infos(
        direct_cc_infos = [own_cc_info],
        cc_infos = dep_infos.cc_infos,
    )
    sdk_frameworks, sdk_dylibs = _merge_plugin_sdk_lists(ctx, ctx.attr.sdk_frameworks, ctx.attr.sdk_dylibs)

    return [
        DefaultInfo(files = depset(all_plugin_files, transitive = dep_infos.framework_files)),
        merged_cc_info,
        SwiftInfo(swift_infos = dep_infos.swift_infos),
        FlutterApplePluginInfo(
            module_name = module_name,
            platform = ctx.attr.platform,
            swift_srcs = depset(srcs.swift),
            objc_srcs = depset(srcs.objc),
            headers = depset(srcs.headers),
            modulemap = modulemap_file,
            sdk_frameworks = tuple(sdk_frameworks),
            sdk_dylibs = tuple(sdk_dylibs),
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

def _apple_plugin_engine_imports(platform, engine):
    """The Flutter framework import labels for an Apple plugin platform."""
    if platform == "macos":
        return [engine] if engine else [Label("@flutter_macos_engine//:engine_library")]
    return [engine] if engine else [Label("@flutter_ios_engine//:Flutter_xcframework")]

def _emit_xtool_plugin_branch(spec):
    flutter_darwin_xcframework_import(
        name = spec.framework_target,
        framework_name = "FlutterMacOS" if spec.platform == "macos" else "Flutter",
        xcframework_imports = spec.engine_imports,
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    flutter_xtool_apple_plugin_library(
        name = spec.name,
        srcs = spec.srcs,
        module_name = spec.module_name,
        platform = spec.platform,
        includes = spec.includes,
        sdk_frameworks = spec.sdk_frameworks,
        sdk_dylibs = spec.sdk_dylibs,
        deps = [":" + spec.framework_target] + list(spec.deps),
        tags = spec.tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = spec.visibility,
    )

def _emit_apple_framework_import(spec):
    if spec.platform == "macos":
        apple_dynamic_framework_import(
            name = spec.framework_target,
            framework_imports = spec.engine_imports,
            tags = spec.internal_tags,
            target_compatible_with = spec.target_compatible_with,
            visibility = ["//visibility:private"],
        )
    else:
        apple_dynamic_xcframework_import(
            name = spec.framework_target,
            xcframework_imports = spec.engine_imports,
            tags = spec.internal_tags,
            target_compatible_with = spec.target_compatible_with,
            visibility = ["//visibility:private"],
        )

def _emit_plugin_objc_target(spec, objc_files, headers):
    """Emit the inner `objc_library`; return `(objc_module_name, dep_label_or_None)`."""
    if not objc_files:
        return "", None
    objc_target = "_%s__objc" % spec.name
    objc_module_name = "%s_objc" % spec.module_name
    objc_library(
        name = objc_target,
        srcs = objc_files,
        hdrs = headers,
        includes = spec.includes,
        sdk_frameworks = spec.sdk_frameworks,
        sdk_dylibs = spec.sdk_dylibs,
        module_name = objc_module_name,
        enable_modules = True,
        copts = spec.copts,
        deps = [":" + spec.framework_target],
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    return objc_module_name, ":" + objc_target

def _plugin_bridging_copts(spec, headers):
    """Find the `<module>-Bridging-Header.h` and return `(header_or_None, copts)`."""
    extra_copts = list(spec.copts)
    for h in headers:
        if h.endswith("%s-Bridging-Header.h" % spec.module_name):
            extra_copts.extend([
                "-import-objc-header",
                "$(execpath %s)" % h,
            ])
            return h, extra_copts
    return None, extra_copts

def _plugin_swift_srcs(spec, swift_files, objc_module_name):
    """Return the swift_library srcs, emitting a re-export placeholder when empty."""
    if swift_files:
        return swift_files
    placeholder_target = "_%s__swift_placeholder" % spec.name
    placeholder_file = "_%s__placeholder.swift" % spec.name
    placeholder_content = ["// GENERATED — re-exports the ObjC module so Swift `import %s` works." % spec.module_name]
    if objc_module_name:
        placeholder_content.append("@_exported import %s" % objc_module_name)
    write_file(
        name = placeholder_target,
        out = placeholder_file,
        content = placeholder_content,
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
    )
    return [":" + placeholder_target]

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
        backend = "rules_apple",
        visibility = None,
        tags = None,
        **kwargs):
    """Build a Flutter plugin's Apple sources into a swift_library.

    Auto-routes `.m`/`.mm` files through an internal `objc_library` and
    feeds it into the `swift_library` as a dep.

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
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in).
        visibility: Target visibility.
        tags: Bazel tags. Defaults to `["manual"]` so the spoke target
            is only built when something depends on it.
        **kwargs: Forwarded to the underlying swift_library.
    """
    if platform not in ("macos", "ios"):
        fail("flutter_apple_plugin_library: platform must be 'macos' or 'ios', got '%s'" % platform)
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_apple_plugin_library: backend must be 'rules_apple' or 'xtool', got %r" % backend)

    if tags == None:
        tags = ["manual"]
    internal_tags = tags if "manual" in tags else tags + ["manual"]

    if module_name == None:
        module_name = name

    target_compatible_with = kwargs.pop(
        "target_compatible_with",
        ["@platforms//os:%s" % platform],
    )

    spec = struct(
        name = name,
        srcs = srcs,
        module_name = module_name,
        platform = platform,
        deps = deps,
        copts = copts,
        includes = includes,
        sdk_frameworks = sdk_frameworks,
        sdk_dylibs = sdk_dylibs,
        engine_imports = _apple_plugin_engine_imports(platform, engine),
        framework_target = "_%s__flutter_framework" % name,
        internal_tags = internal_tags,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
        tags = tags,
    )

    if backend == "xtool":
        _emit_xtool_plugin_branch(spec)
        return

    swift_files, objc_files, headers = _split_srcs(srcs)
    _emit_apple_framework_import(spec)

    swift_deps = [":" + spec.framework_target] + list(deps)

    objc_module_name, objc_dep = _emit_plugin_objc_target(spec, objc_files, headers)
    if objc_dep:
        swift_deps.append(objc_dep)

    bridging_header, extra_copts = _plugin_bridging_copts(spec, headers)
    swift_files = _plugin_swift_srcs(spec, swift_files, objc_module_name)

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
