"""Compile a Flutter plugin's Apple sources into a swift_library.

This is the rules_flutter analog of the Podfile-driven CocoaPods build a
Flutter plugin author would otherwise rely on. It wraps `swift_library`
with the platform's Flutter framework as a dep. A plugin of Swift and C-family
sources both is one module of the two, rules_swift's
`mixed_language_library`, as SwiftPM and CocoaPods build it; a plugin of
C-family sources alone is an `objc_library`.

Public Tier-2 API: re-exported from `flutter/macos.bzl` and
`flutter/ios.bzl` so users can wire a monorepo plugin's BUILD.bazel
without going through the `flutter/ext/` overlay system.

Usage:

    flutter_apple_plugin_library(
        name = "my_plugin_apple_macos",
        srcs = glob(["macos/Classes/**/*.swift"]),
        module_name = "my_plugin",
        platform = "macos",
    )
"""

load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_dynamic_xcframework_import")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//mixed_language:mixed_language_library.bzl", "mixed_language_library")
load("@rules_swift//swift:swift.bzl", "SwiftInfo", "swift_clang_module_aspect", "swift_library")
load(":apple_engine.bzl", "IOS_ENGINE_XCFRAMEWORK", "MACOS_ENGINE_FRAMEWORK", "flutter_engine_module_maps")

visibility("//flutter/...")

_CLANG_SOURCE_EXTENSIONS = ("m", "mm", "c", "cc", "cpp", "cxx", "c++", "s", "S")
_HEADER_EXTENSIONS = ("h", "hh", "hpp", "hxx", "h++", "inc")

# Xcode compiles a plugin, from its Swift package or its podspec, with Clang's
# module autolinking on (`CLANG_MODULES_AUTOLINK`): an SDK framework its sources
# import, as `@import CoreTelephony;` or `#import <CoreTelephony/...>` does, is
# linked into the app without the plugin naming it. apple_support's toolchain
# turns autolinking off for every C-family compile, so it is turned back on here.
_AUTOLINK = ["-fautolink"]

def _swift_header_include_impl(ctx):
    module = ctx.attr.swift[SwiftInfo].direct_modules[0]
    header = ctx.actions.declare_file("%s/%s/%s" % (ctx.label.name, module.name, module.swift.generated_header.basename))
    ctx.actions.symlink(output = header, target_file = module.swift.generated_header)
    return [CcInfo(compilation_context = cc_common.create_compilation_context(
        headers = depset([header]),
        includes = depset([header.dirname.rsplit("/", 1)[0], header.dirname]),
    ))]

# The generated header of a mixed module's Swift half, for its Objective-C
# half to import as Xcode lets it: `<module>/<module>-Swift.h` or
# `"<module>-Swift.h"`, the two that Flutter's plugin template tries.
_swift_header_include = rule(
    implementation = _swift_header_include_impl,
    attrs = {"swift": attr.label(mandatory = True, providers = [SwiftInfo])},
)

FlutterAppleModuleHeadersInfo = provider(
    doc = "The public C-family headers of a plugin's module, which its add-to-app framework holds.",
    fields = {"headers": "The module's own public headers, as Files."},
)

def _module_headers_aspect_impl(target, ctx):
    if FlutterAppleModuleHeadersInfo in target or CcInfo not in target:
        return []

    # A `mixed_language_library`'s C-family half is its `clang_target`, whose
    # public headers are the module's and the generated umbrella header.
    clang = getattr(ctx.rule.attr, "clang_target", None)
    if clang and CcInfo in clang and SwiftInfo in target:
        umbrella = ctx.rule.file.umbrella_header
        return [FlutterAppleModuleHeadersInfo(headers = [
            h
            for h in clang[CcInfo].compilation_context.direct_public_headers
            if h != umbrella
        ])]

    # A library of C-family sources alone is its own module.
    if SwiftInfo not in target:
        return [FlutterAppleModuleHeadersInfo(headers = target[CcInfo].compilation_context.direct_public_headers)]
    return []

module_headers_aspect = aspect(
    implementation = _module_headers_aspect_impl,
    doc = "Gives a `flutter_apple_plugin_library` of C-family sources its module's " +
          "public headers (`FlutterAppleModuleHeadersInfo`), which an add-to-app framework holds.",
)

FlutterAppleLinkedTargetsInfo = provider(
    doc = "The C-family and Swift targets an application's Apple plugins are linked from, which " +
          "add-to-app makes frameworks of: the plugins' own, and those of the Swift packages they " +
          "depend on.",
    fields = {
        "targets": "depset of structs: `label`, `cc_info` (CcInfo), `swift_info` (SwiftInfo or None), " +
                   "`xcframework_files` (every file of a prebuilt xcframework it imports, or None).",
    },
)

# From an application to its plugins' Apple libraries (through Dart
# libraries, the pub hub's `members` and a plugin's `platforms`), and on to
# the targets a library is linked from.
_LINKED_TARGETS_EDGES = ["deps", "exports", "members", "platforms", "apple_lib", "implementation_deps"]

def _linked_targets_aspect_impl(target, ctx):
    transitive = []
    for attr in _LINKED_TARGETS_EDGES:
        value = getattr(ctx.rule.attr, attr, None)
        for dep in (value if type(value) == "list" else [value]):
            if type(dep) == "Target" and FlutterAppleLinkedTargetsInfo in dep:
                transitive.append(dep[FlutterAppleLinkedTargetsInfo].targets)
    direct = []
    if CcInfo in target:
        direct.append(struct(
            label = target.label,
            cc_info = target[CcInfo],
            swift_info = target[SwiftInfo] if SwiftInfo in target else None,
            # An `apple_dynamic_xcframework_import`'s, which add-to-app
            # copies into the layout.
            xcframework_files = getattr(ctx.rule.files, "xcframework_imports", None),
        ))
    return [FlutterAppleLinkedTargetsInfo(targets = depset(direct, transitive = transitive))]

linked_targets_aspect = aspect(
    implementation = _linked_targets_aspect_impl,
    attr_aspects = _LINKED_TARGETS_EDGES,
    # The Clang module `swift_clang_module_aspect` gives a C-family library.
    requires = [swift_clang_module_aspect],
    provides = [FlutterAppleLinkedTargetsInfo],
    doc = "Records each target an application's Apple plugins are linked from, with its CcInfo " +
          "and its module, for the add-to-app frameworks: one per plugin, and one per module of " +
          "a Swift package a plugin depends on. Attached by add-to-app's plugin xcframeworks " +
          "alone, so an app's build does not pay for it.",
)

def _extension(path):
    name = path.rsplit("/", 1)[-1]
    return name.rsplit(".", 1)[-1] if "." in name else ""

def _split_srcs(srcs, public_hdrs):
    """Split srcs into (swift_files, clang_files, public_headers, private_headers).

    Returns lists by extension so we can route C, C++ and Objective-C through
    objc_library while keeping Swift on swift_library. With `public_hdrs`,
    those are the module's public headers and the other headers are private.
    Otherwise headers are public, part of the plugin's module, unless the
    sources follow SwiftPM's layout, where only the headers under an
    `include/` directory (`publicHeadersPath`'s default) are: the rest are
    the target's own, compiled with its sources but not importable, and a
    private header that does not stand on its own (one that uses `NS_ENUM`
    without importing Foundation) would fail the module's build.
    """
    swift_files = []
    objc_files = []
    headers = []
    for f in srcs:
        ext = _extension(f)
        if ext == "swift":
            swift_files.append(f)
        elif ext in _CLANG_SOURCE_EXTENSIONS:
            objc_files.append(f)
        elif ext in _HEADER_EXTENSIONS:
            headers.append(f)
    if public_hdrs != None:
        public = {h: True for h in public_hdrs}
        return swift_files, objc_files, list(public_hdrs), [h for h in headers if h not in public]
    public = [h for h in headers if _under_include_dir(h)]
    if not public:
        return swift_files, objc_files, headers, []
    private = [h for h in headers if not _under_include_dir(h)]
    return swift_files, objc_files, public, private

def _under_include_dir(path):
    return path.startswith("include/") or "/include/" in path

def flutter_apple_plugin_library(
        name,
        srcs = [],
        module_name = None,
        platform = "macos",
        deps = [],
        copts = [],
        clang_copts = [],
        cxxopts = [],
        conlyopts = [],
        swift_copts = [],
        linkopts = [],
        public_hdrs = None,
        textual_hdrs = [],
        includes = [],
        sdk_frameworks = [],
        sdk_dylibs = [],
        swift_language_mode = None,
        data = [],
        visibility = None,
        tags = None,
        **kwargs):
    """Build a Flutter plugin's Apple sources into one module named `module_name`.

    With Swift and C, C++ or Objective-C sources (`.m`, `.mm`, `.c`, `.cpp`
    and the like) both, the library is one module of the two, as SwiftPM
    and CocoaPods build it: the Swift sees the module's public headers
    without an import, the C-family sources see the Swift through
    `<module_name>-Swift.h` (`#import <module_name/module_name-Swift.h>` or
    `#import "module_name-Swift.h"`), and importers see both. With C-family
    sources alone, the library is an `objc_library` whose Clang module is
    `module_name`, as SwiftPM, CocoaPods and Xcode build an Objective-C
    plugin; Swift sees it as a module through rules_swift's
    `swift_clang_module_aspect`. A Swift-only library may have
    a bridging header, `<module_name>-Bridging-Header.h` in `srcs`, which
    the Swift compile imports.

    Args:
        name: Target name. Pass to runner deps (or via the aspect-based
            aggregator that discovers them automatically).
        srcs: Swift, C, C++, Objective-C and header source files. When some
            headers are under an `include/` directory, as in SwiftPM's
            layout, and `public_hdrs` is not given, only those are the
            module's public headers; the others are private to the ObjC
            compile, as SwiftPM treats them.
        module_name: The module's name, which the plugin registrant imports.
            Defaults to `name`.
        platform: `"macos"` or `"ios"`, which picks the Flutter framework
            the sources compile against; or `"darwin"` for sources that build
            for both (`sharedDarwinSource`), which compile against the
            framework of the platform the build is for. List a `darwin`
            library as the `lib` of both the plugin's `ios` and `macos`
            `flutter_plugin_platform`.
        deps: Additional swift_library / cc_library deps: other plugins,
            other targets of the plugin's package. Both compiles see them.
        copts: Additional compile options, for both the Swift and the ObjC
            compile: a define a plugin's `Package.swift` sets is `-DNAME`,
            which Clang reads as `NAME=1` and Swift as a condition.
        clang_copts: Compile options for the C, C++ and Objective-C sources
            only: a `Package.swift`'s C and C++ defines and its C
            `unsafeFlags`. Split as a shell would, as `objc_library.copts`.
        cxxopts: Compile options for the C++ and Objective-C++ sources only:
            the package's C++ language standard, its C++ `unsafeFlags`. Only
            for a library without Swift sources, as a Swift package target
            is; a library of both takes `clang_copts`.
        conlyopts: Compile options for the C sources only: the package's C
            language standard. Only for a library without Swift sources.
        swift_copts: Compile options for the Swift sources only: a
            `Package.swift`'s Swift defines (`-DNAME`) and its Swift
            `unsafeFlags`.
        linkopts: Options for the link of any binary that links the plugin:
            a `Package.swift`'s linker `unsafeFlags`.
        public_hdrs: The headers of the plugin's module, which the
            `publicHeadersPath` of a `Package.swift` target holds; the other
            headers in `srcs` are private to its compile. Without it, see
            `srcs`.
        textual_hdrs: Headers the C-family sources may include that are
            not the library's own: those of the other targets of a Swift
            package, which SwiftPM lets any target include by path.
        includes: Header search paths forwarded to the inner
            `objc_library`. Mirrors `objc_library.includes` semantics —
            each entry becomes `-I <package>/<entry>` for both the
            ObjC compile and downstream consumers, matching SwiftPM's
            `publicHeadersPath` behavior. Required for plugins that
            follow SwiftPM's canonical layout (header at
            `Sources/<pkg>/include/<pkg>/Foo.h`, `.m` does bare-basename
            `#import "Foo.h"`); without the include path the .m's import
            fails with `'Foo.h' file not found`.
        sdk_frameworks: Apple SDK frameworks to link (e.g. `["AVFoundation"]`),
            as a `Package.swift`'s `linkedFramework` does. A framework the
            C-family sources import is linked without this, as Xcode links
            it: the library compiles them with Clang's module autolinking on.
            A plugin built from its `Package.swift` gets its `linkerSettings`
            without this; an overlay lists them here.
        sdk_dylibs: Apple SDK dynamic libraries to link (e.g. `["c++"]`,
            `["sqlite3"]`), as a `Package.swift`'s `linkedLibrary` does.
        data: Resources the app carries for the library, such as the
            `apple_resource_bundle` of a Swift package target's resources.
        swift_language_mode: `"6"` to compile the Swift sources in Swift 6
            mode, as SwiftPM compiles a target of a `swift-tools-version:
            6.0` package; Swift 5 (the default) otherwise.
        visibility: Target visibility.
        tags: Bazel tags. Defaults to `["manual"]` so the spoke target
            is only built when something depends on it.
        **kwargs: Forwarded to the underlying `swift_library`,
            `mixed_language_library` or `objc_library`.
    """
    if platform not in ("macos", "ios", "darwin"):
        fail("flutter_apple_plugin_library: platform must be 'macos', 'ios' or 'darwin', got '%s'" % platform)

    if swift_language_mode not in (None, "5", "6"):
        fail("flutter_apple_plugin_library: swift_language_mode must be \"5\" or \"6\", got %r" % swift_language_mode)

    if tags == None:
        tags = ["manual"]

    if module_name == None:
        module_name = name

    # Both per-platform plugin spokes share the same module_name (so the
    # registrant's `import <module>` resolves identically on each platform).
    # Without target_compatible_with, both swift_library targets analyze in
    # the same configuration and produce conflicting `<module>.swiftmodule`
    # outputs. Constrain each to its OS so only one is reachable per build;
    # a `darwin` library, the one of both, to either.
    if platform == "darwin":
        target_compatible_with = select({
            Label("@platforms//os:ios"): [],
            Label("@platforms//os:macos"): [],
            "//conditions:default": [Label("@platforms//:incompatible")],
        })
    else:
        target_compatible_with = ["@platforms//os:%s" % platform]

    swift_files, objc_files, headers, private_headers = _split_srcs(srcs, public_hdrs)

    # The Flutter framework is loaded at runtime (extracted via
    # flutter_macos_engine / flutter_ios_engine elsewhere). For
    # compile-time symbol resolution we depend on a framework import that
    # brings in the framework headers. macOS ships a dynamic framework;
    # iOS ships an xcframework wrapper. The import is the build mode's
    # engine, the one the application bundles: an import of another mode's
    # engine under the same framework name breaks the bundle. A `darwin`
    # library picks the engine of the platform it is built for.
    framework_targets = {}
    for os in (("macos", "ios") if platform == "darwin" else (platform,)):
        framework_target = "_%s__flutter_framework%s" % (name, "_" + os if platform == "darwin" else "")
        framework_targets[os] = ":" + framework_target
        if os == "macos":
            apple_dynamic_framework_import(
                name = framework_target,
                framework_imports = MACOS_ENGINE_FRAMEWORK,
                tags = tags,
                target_compatible_with = ["@platforms//os:macos"],
                visibility = ["//visibility:private"],
            )
        else:
            apple_dynamic_xcframework_import(
                name = framework_target,
                xcframework_imports = IOS_ENGINE_XCFRAMEWORK,
                tags = tags,
                target_compatible_with = ["@platforms//os:ios"],
                visibility = ["//visibility:private"],
            )
    if platform == "darwin":
        framework_deps = select({
            Label("@platforms//os:ios"): [framework_targets["ios"]],
            Label("@platforms//os:macos"): [framework_targets["macos"]],
            "//conditions:default": [],
        })
        framework_files = select({
            Label("@platforms//os:ios"): IOS_ENGINE_XCFRAMEWORK,
            Label("@platforms//os:macos"): MACOS_ENGINE_FRAMEWORK,
            "//conditions:default": [],
        })
    else:
        framework_deps = [framework_targets[platform]]
        framework_files = MACOS_ENGINE_FRAMEWORK if platform == "macos" else IOS_ENGINE_XCFRAMEWORK

    swift_deps = framework_deps + list(deps)

    # The engine's module map, for C-family sources that `@import Flutter`.
    module_maps_target = "_%s__flutter_module_maps" % name
    flutter_engine_module_maps(
        name = module_maps_target,
        framework = framework_files,
        tags = tags,
        target_compatible_with = target_compatible_with,
        visibility = ["//visibility:private"],
    )
    clang_deps = framework_deps + [":" + module_maps_target] + list(deps)

    # The SDK frameworks and libraries are the plugin's to link whatever its
    # sources are in; a Swift-only plugin has no objc_library to carry them.
    sdk_linkopts = ["-Wl,-framework," + f for f in sdk_frameworks] + ["-l" + d for d in sdk_dylibs]

    if not swift_files:
        # A plugin of C-family sources alone is one Clang module named
        # `module_name`, as SwiftPM, CocoaPods and Xcode build it. Swift
        # importers, the app's plugin registrant among them, see it through
        # `swift_clang_module_aspect`, which `flutter_plugin_platform.lib`
        # applies.
        kwargs.pop("swiftc_inputs", None)
        objc_library(
            name = name,
            srcs = objc_files + private_headers,
            hdrs = headers,
            textual_hdrs = textual_hdrs,
            includes = includes,
            module_name = module_name,
            enable_modules = True,
            copts = _AUTOLINK + copts + clang_copts,
            cxxopts = cxxopts,
            conlyopts = conlyopts,
            linkopts = sdk_linkopts + linkopts,
            # Every object of the plugin is in the app, as Xcode links a
            # Swift package's objects and CocoaPods its framework: code that
            # only Dart reaches, through `DynamicLibrary.process()`, has no
            # reference from the app's link to pull it in.
            alwayslink = True,
            data = data,
            deps = clang_deps,
            tags = tags,
            target_compatible_with = target_compatible_with,
            visibility = visibility,
            **kwargs
        )
        return

    features = list(kwargs.pop("features", []))
    swiftc_inputs = list(kwargs.pop("swiftc_inputs", []))
    if swift_language_mode == "6":
        features.append("swift.enable_v6")

    if swift_files and objc_files:
        # One module of both halves, as SwiftPM and CocoaPods build a target
        # of Swift and Objective-C: the Swift sees the module's public
        # headers without importing anything (`-import-underlying-module`),
        # the Objective-C sees the Swift through `<module>-Swift.h`, and
        # importers see both, the generated header the module's `Swift`
        # submodule. A bridging header is one more private header: the
        # module's own headers are what Swift sees.
        if cxxopts or conlyopts:
            fail(("flutter_apple_plugin_library %s: `cxxopts` and `conlyopts` apply to a library " +
                  "of C-family sources alone, and this one has Swift sources too; use `clang_copts`") % name)

        # `mixed_language_library` names its Swift half `<name>_swift`.
        swift_header = "_%s__swift_header" % name
        _swift_header_include(
            name = swift_header,
            swift = ":%s_swift" % name,
            tags = tags,
            target_compatible_with = target_compatible_with,
            visibility = ["//visibility:private"],
        )
        bridging = [h for h in headers if h.endswith("%s-Bridging-Header.h" % module_name)]
        mixed_language_library(
            name = name,
            swift_srcs = swift_files,
            clang_srcs = objc_files + private_headers + bridging,
            hdrs = [h for h in headers if h not in bridging],
            textual_hdrs = textual_hdrs,
            includes = includes,
            module_name = module_name,
            enable_modules = True,
            clang_copts = _AUTOLINK + copts + clang_copts,
            swift_copts = copts + swift_copts,
            swiftc_inputs = swiftc_inputs,
            sdk_frameworks = sdk_frameworks,
            sdk_dylibs = sdk_dylibs,
            linkopts = linkopts,
            # Every object of the plugin is in the app, as for one of
            # C-family sources alone.
            alwayslink = True,
            data = data,
            features = features,
            clang_deps = [":" + module_maps_target, ":" + swift_header],
            deps = framework_deps + list(deps),
            tags = tags,
            target_compatible_with = target_compatible_with,
            visibility = visibility,
            **kwargs
        )
        return

    bridging_header = None
    extra_copts = []
    for h in headers + private_headers:
        if h.endswith("%s-Bridging-Header.h" % module_name):
            bridging_header = h
            extra_copts.extend([
                "-import-objc-header",
                "$(execpath %s)" % h,
            ])
            break

    swift_library(
        name = name,
        features = features,
        data = data,
        srcs = swift_files,
        module_name = module_name,
        copts = copts + swift_copts + extra_copts,
        linkopts = sdk_linkopts + linkopts,
        deps = swift_deps,
        swiftc_inputs = swiftc_inputs + ([bridging_header] if bridging_header else []),
        generates_header = True,
        generated_header_name = module_name + "-Swift.h",
        tags = tags,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
        **kwargs
    )
