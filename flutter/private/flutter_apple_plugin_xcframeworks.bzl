"""The plugin and code-asset xcframeworks of Apple add-to-app.

`flutter build ios-framework` packages each plugin with Apple code as its own
xcframework, and each code asset (a Dart build hook's dynamic library) as one
more. These rules do the same, from the plugin libraries an application
carries (`FlutterApplicationInfo.apple_plugin_libraries`) and the code assets
it ships, in the build mode of the configuration.

A plugin's framework holds only that plugin's code. It is linked here, slice by
slice, from the plugin's own static libraries: Flutter is linked dynamically
(`@rpath/Flutter.framework/Flutter`, not copied in), and another plugin the
plugin uses is that plugin's own framework. The framework has the module the
host imports:

- a Swift plugin: `Headers/<module>-Swift.h`, a module map naming it, and
  `Modules/<module>.swiftmodule/<triple>.swiftinterface`, compiled with
  library evolution as Xcode's `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` compiles
  it;
- an Objective-C plugin: its public headers in `Headers/`, under the umbrella
  header and module map CocoaPods gives a framework pod;
- a plugin of both: one module of the two, the Swift part its `Swift`
  submodule, as Xcode builds a mixed framework.

Plus `Info.plist`, the plugin's privacy manifest and resource bundles, and
in profile and release a dSYM.
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING", "program_assets_action_args")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:apple_add_to_app.bzl", "BUNDLE_ATTRS", "SLICES", "SLICES_TRANSITION", "assemble_bundle", "framework_resources", "framework_root", "xcframework_info_plist")
load("//flutter/private:apple_xcode.bzl", "XCODE_TOOL_ATTRS", "XCODE_TOOL_FRAGMENTS", "XCODE_TOOL_TOOLCHAINS", "process_native_library", "rewrite_install_names", "run_xcode_tool")
load("//flutter/private:constants.bzl", "IOS_MINIMUM_OS_VERSION", "MACOS_MINIMUM_OS_VERSION")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//flutter/private:flutter_native_assets.bzl", "CODE_ASSETS_TOOL_ATTRS", "app_ios_framework_names", "candidate_code_asset_libraries", "run_code_assets_tool")
load("//flutter/private:native_libraries.bzl", "native_library_files")
load("//flutter/private:unbuilt_native_code.bzl", "fail_on_unbuilt_native_code")

visibility("//flutter/...")

_MINIMUM_OS_VERSION = {"ios": IOS_MINIMUM_OS_VERSION, "macos": MACOS_MINIMUM_OS_VERSION}

# The engine framework a plugin links, by platform.
_FLUTTER = {"ios": "Flutter", "macos": "FlutterMacOS"}

# Where a framework's binary looks for the frameworks it links: an app's
# `Frameworks/`, and the framework's own (none, but upstream sets it).
_RPATHS = {
    "ios": ["@executable_path/Frameworks", "@loader_path/Frameworks"],
    "macos": ["@executable_path/../Frameworks", "@loader_path/Frameworks"],
}

# AppleResourceInfo fields copied into a framework as they are. A plugin's
# resources of another kind (storyboards, asset catalogs, strings) would need
# compiling, which no plugin of a Flutter app has been seen to ship.
_COPIED_RESOURCES = ["processed", "unprocessed", "plists"]
_RESOURCE_KINDS = [
    "alternate_icons",
    "asset_catalogs",
    "datamodels",
    "framework",
    "infoplists",
    "metals",
    "mlmodels",
    "pngs",
    "storyboards",
    "strings",
    "texture_atlases",
    "xcstrings",
    "xibs",
]

_FRAMEWORK_INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>{name}</string>
	<key>CFBundleIdentifier</key>
	<string>{bundle_id}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>{name}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>{minimum_os_key}</key>
	<string>{minimum_os_version}</string>
</dict>
</plist>
"""

def _framework_info_plist(ctx, output, name, prefix, platform):
    ctx.actions.write(output, _FRAMEWORK_INFO_PLIST.format(
        name = name,
        bundle_id = (prefix + name).replace("_", "-"),
        minimum_os_key = "MinimumOSVersion" if platform == "ios" else "LSMinimumSystemVersion",
        minimum_os_version = ctx.attr.minimum_os_version,
    ))

def _static_libraries(linker_input):
    return [
        lib.static_library or lib.pic_static_library
        for lib in linker_input.libraries
        if lib.static_library or lib.pic_static_library
    ]

def _same_package(a, b):
    return a.repo_name == b.repo_name and a.package == b.package

def _plugin_module(entry):
    """How a plugin library's module is made: its name, headers and interface.

    Args:
        entry: An `apple_plugin_libraries` struct.

    Returns:
        A struct of `name`, `objc_headers` (public headers), `swift_header`
        (the generated `-Swift.h`, or None), `swift` (the Swift module's
        `swift` struct, or None).
    """
    name = entry.package
    modules = {m.name: m for m in entry.swift_info.transitive_modules.to_list()} if entry.swift_info else {}
    if name not in modules:
        fail("%s: the plugin %s has no module named %s, the name its registrant imports" % (entry.label, entry.package, name))
    module = modules[name]
    swift_header = None
    if module.swift and module.clang and module.clang.compilation_context:
        for header in module.clang.compilation_context.direct_public_headers:
            if header.basename == name + "-Swift.h":
                swift_header = header
    return struct(
        name = name,
        objc_headers = [
            h
            for h in (getattr(entry, "module_headers", None) or [])
            if not h.basename.endswith("-Bridging-Header.h")
        ],
        swift_header = swift_header,
        swift = module.swift if swift_header else None,
    )

def _module_map(name, module):
    umbrella = 'framework module {name} {{\n  umbrella header "{name}-umbrella.h"\n\n  export *\n  module * {{ export * }}\n}}\n'.format(name = name)
    swift = '{framework}module {name}{sub} {{\n  header "{name}-Swift.h"\n  requires objc\n}}\n'
    if module.objc_headers and module.swift_header:
        return umbrella + swift.format(framework = "", name = name, sub = ".Swift")
    if module.objc_headers:
        return umbrella
    return swift.format(framework = "framework ", name = name, sub = "")

# The start of the umbrella header CocoaPods writes for a framework pod
# (`Pod::Generator::Header`), the one `flutter build ios-framework` and
# `macos-framework` build a plugin as.
_UMBRELLA_PROLOGUE = """#ifdef __OBJC__
#import <{framework}/{framework}.h>
#else
#ifndef FOUNDATION_EXPORT
#if defined(__cplusplus)
#define FOUNDATION_EXPORT extern "C"
#else
#define FOUNDATION_EXPORT extern
#endif
#endif
#endif

"""

def _umbrella_header(platform_type, headers):
    """A framework's umbrella header: the platform's UI framework, then the module's public headers."""
    return _UMBRELLA_PROLOGUE.format(framework = "Cocoa" if platform_type == "macos" else "UIKit") + "".join([
        '#import "%s"\n' % h.basename
        for h in headers
    ])

def _resource_steps(entry, resources_root):
    info = getattr(entry, "resource_info", None)
    if not info:
        return []
    for kind in _RESOURCE_KINDS:
        if getattr(info, kind, None):
            fail(("%s: the plugin %s has %s resources, which an add-to-app framework " +
                  "does not compile yet. Only plain files are copied.") % (entry.label, entry.package, kind))
    steps = []
    for kind in _COPIED_RESOURCES:
        for parent_dir, _, files in getattr(info, kind, []) or []:
            for f in files.to_list():
                steps.append(("file", "%s/%s%s" % (resources_root, parent_dir + "/" if parent_dir else "", f.basename), f))
    return steps

def _link(ctx, slice, toolchain, module, libraries, flags, additional, dependencies):
    """Links one plugin's dynamic library for one slice."""
    cc_toolchain = toolchain[cc_common.CcToolchainInfo]
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    platform = slice.platform_type
    install_name = "@rpath/{n}.framework/{v}{n}".format(n = module.name, v = "Versions/A/" if platform == "macos" else "")
    link_flags = list(flags) + [
        # A framework, linked as `apple_support` links one: an executable
        # output with `-dynamiclib`, so its install name is the framework's
        # rather than `@rpath/lib<name>.dylib`.
        "-dynamiclib",
        "-Wl,-install_name," + install_name,
    ] + ["-Wl,-rpath," + r for r in _RPATHS[platform]]
    for directory, name in dependencies:
        link_flags.extend(["-F" + directory, "-framework", name])
    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset([
            cc_common.create_library_to_link(
                actions = ctx.actions,
                feature_configuration = feature_configuration,
                cc_toolchain = cc_toolchain,
                static_library = lib,
                # Every object of the plugin, as Xcode links a framework
                # target's: code that only Dart reaches has no reference from
                # the link to pull it in.
                alwayslink = True,
            )
            for lib in libraries
        ]),
        user_link_flags = link_flags,
        additional_inputs = depset(additional),
    )
    return cc_common.link(
        actions = ctx.actions,
        name = "%s_slices/%s/bin/%s" % (ctx.label.name, slice.id, module.name),
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        linking_contexts = [cc_common.create_linking_context(linker_inputs = depset([linker_input]))],
        output_type = "executable",
    ).executable

def _archive(ctx, slice, module, libraries):
    """Archives one plugin's objects as a static framework binary."""
    archive = ctx.actions.declare_file("%s_slices/%s/bin/%s.a" % (ctx.label.name, slice.id, module.name))
    run_xcode_tool(
        ctx,
        command = 'out="$1"; shift; xcrun libtool -static -no_warning_for_no_symbols -o "$out" "$@"',
        arguments = [ctx.actions.args().add(archive).add_all(libraries)],
        inputs = libraries,
        outputs = [archive],
        mnemonic = "FlutterPluginStaticFramework",
        execution_requirements = PATH_MAPPING,
        progress_message = "Archiving %s.framework for %s" % (module.name, slice.id),
    )
    return archive

def _dsym(ctx, slice, module, binary):
    """The dSYM bundle of a framework binary, as `dsymutil` writes it."""
    bundle = "%s_slices/%s/dsym/%s.framework.dSYM" % (ctx.label.name, slice.id, module.name)
    plist = ctx.actions.declare_file(bundle + "/Contents/Info.plist")
    dwarf = ctx.actions.declare_file(bundle + "/Contents/Resources/DWARF/" + module.name)
    run_xcode_tool(
        ctx,
        command = 'xcrun dsymutil "$1" -o "$2"',
        arguments = [ctx.actions.args().add(binary).add(plist.dirname.rsplit("/", 1)[0])],
        inputs = [binary],
        outputs = [plist, dwarf],
        mnemonic = "FlutterPluginDsym",
        progress_message = "Extracting the dSYM of %s.framework for %s" % (module.name, slice.id),
    )
    return [plist, dwarf]

def _slice_plugins(ctx, slice, app_info, toolchain, debug):
    """The plugin frameworks of one slice: a dict from module name to its steps."""
    platform = slice.platform_type
    entries = [e for e in app_info.apple_plugin_libraries.to_list() if e.platform == platform]
    fail_on_unbuilt_native_code(entries)
    for e in entries:
        if getattr(e, "app_library", None):
            fail(("%s: the plugin %s decides its build from the app's Info.plist or environment " +
                  "(its Package.swift reads them), which add-to-app does not support yet.") % (e.label, e.package))
        if not e.cc_info:
            fail("%s: the plugin %s has no C-family or Swift library" % (e.label, e.package))

    modules = {e.package: _plugin_module(e) for e in entries}

    # Each plugin's own static libraries: those of the targets in its
    # library's package. Another plugin's are that plugin's framework.
    owner_of = {}
    for e in entries:
        for linker_input in e.cc_info.linking_context.linker_inputs.to_list():
            if _same_package(linker_input.owner, e.label):
                for lib in _static_libraries(linker_input):
                    owner_of[lib.path] = e.package

    by_package = {e.package: e for e in entries}

    def plugin_of(owner):
        for e in entries:
            if _same_package(owner, e.label):
                return e.package
        return None

    # What each plugin links: its own libraries and flags, the plugins it
    # uses, and the engine.
    plans = {}
    for package, entry in by_package.items():
        libraries = []
        flags = []
        additional = []
        engine = []
        uses = {}
        foreign = {}
        for linker_input in entry.cc_info.linking_context.linker_inputs.to_list():
            owner = plugin_of(linker_input.owner)
            statics = _static_libraries(linker_input)
            dynamics = [
                lib.resolved_symlink_dynamic_library or lib.dynamic_library
                for lib in linker_input.libraries
                if lib.dynamic_library and not (lib.static_library or lib.pic_static_library)
            ]
            for real in dynamics:
                marker = "/%s.framework/" % _FLUTTER[platform]
                if marker not in real.path:
                    fail("%s: the plugin %s links the dynamic library %s, which add-to-app does not package yet" % (entry.label, package, real.path))
                framework_dir = real.path[:real.path.index(marker)]
                if framework_dir not in engine:
                    engine.append(framework_dir)
                additional.append(real)
            if statics:
                lib_owner = owner_of.get(statics[0].path)
                if lib_owner == package:
                    libraries.extend(statics)
                elif lib_owner:
                    uses[lib_owner] = True
                    continue
                else:
                    foreign[str(linker_input.owner)] = True
                    continue
            elif owner and owner != package:
                # Another plugin's flags come with its framework.
                continue
            flags.extend(linker_input.user_link_flags)
            additional.extend(linker_input.additional_inputs)
        if foreign:
            fail(("%s: the plugin %s links %s, which are not plugins. Add-to-app packages a " +
                  "plugin's own code; a Swift package or library a plugin depends on would be " +
                  "an xcframework of its own, which add-to-app does not build yet.") % (
                entry.label,
                package,
                ", ".join(sorted(foreign.keys())),
            ))
        plans[package] = struct(
            libraries = libraries,
            flags = flags,
            additional = additional,
            engine = engine,
            uses = sorted(uses.keys()),
        )

    # Built in an order where a plugin follows the plugins it links (no
    # recursion in Starlark: one pass per level).
    order = []
    placed = {}
    for _ in range(len(plans) + 1):
        ready = [p for p in sorted(plans.keys()) if p not in placed and all([u in placed for u in plans[p].uses])]
        for p in ready:
            placed[p] = True
            order.append(p)
    if len(order) != len(plans):
        fail("Apple plugins %s link each other in a cycle" % ", ".join(sorted([p for p in plans if p not in placed])))

    built = {}
    for package in order:
        entry = by_package[package]
        module = modules[package]
        plan = plans[package]
        dependencies = [(d, _FLUTTER[platform]) for d in plan.engine]
        additional = list(plan.additional)
        for other in plan.uses:
            dependencies.append((built[other].binary_dir, other))
            additional.append(built[other].binary)

        if ctx.attr.static:
            binary = _archive(ctx, slice, module, plan.libraries)
            dsym_files = []
        else:
            linked = _link(ctx, slice, toolchain, module, plan.libraries, plan.flags, additional, dependencies)

            # A copy named as the framework names it, for a plugin that links
            # this one to find with `-F`.
            binary = ctx.actions.declare_file("%s_slices/%s/link/%s.framework/%s" % (ctx.label.name, slice.id, module.name, module.name))
            ctx.actions.symlink(output = binary, target_file = linked)
            dsym_files = [] if debug else _dsym(ctx, slice, module, linked)

        steps = _framework_steps(ctx, slice, entry, module, binary)
        for f in dsym_files:
            rest = f.path[f.path.index(".dSYM/") + len(".dSYM/"):]
            steps.append(("file", "%s/dSYMs/%s.framework.dSYM/%s" % (slice.id, module.name, rest), f))
        built[package] = struct(
            steps = steps,
            binary = binary,
            binary_dir = binary.dirname.rsplit("/", 1)[0],
            has_dsym = bool(dsym_files),
        )
    return built

def _framework_steps(ctx, slice, entry, module, binary):
    name = module.name
    static = ctx.attr.static
    root = framework_root(slice, name, static)
    resources = framework_resources(slice, name, static)
    directory = "%s_slices/%s/%s" % (ctx.label.name, slice.id, name)
    steps = [("file", "%s/%s" % (root, name), binary)]

    plist = ctx.actions.declare_file(directory + "/Info.plist")
    _framework_info_plist(ctx, plist, name, "io.flutter.flutter.plugins.", slice.platform_type)
    steps.append(("file", resources + "/Info.plist", plist))

    modulemap = ctx.actions.declare_file(directory + "/module.modulemap")
    ctx.actions.write(modulemap, _module_map(name, module))
    steps.append(("file", root + "/Modules/module.modulemap", modulemap))

    if module.objc_headers:
        umbrella = ctx.actions.declare_file(directory + "/%s-umbrella.h" % name)
        ctx.actions.write(umbrella, _umbrella_header(slice.platform_type, module.objc_headers))
        steps.append(("file", "%s/Headers/%s-umbrella.h" % (root, name), umbrella))
        for header in module.objc_headers:
            steps.append(("file", "%s/Headers/%s" % (root, header.basename), header))

    if module.swift_header:
        interface = module.swift.swiftinterface
        if not interface:
            fail("%s: the plugin %s has no Swift module interface; it is compiled without library evolution" % (entry.label, entry.package))
        swift_header = "%s/Headers/%s-Swift.h" % (root, name)
        swiftmodule = "%s/Modules/%s.swiftmodule/%s" % (root, name, slice.triple)
        steps.append(("file", swift_header, module.swift_header))
        steps.append(("file", swiftmodule + ".swiftinterface", interface))
        if module.swift.swiftdoc:
            steps.append(("file", swiftmodule + ".swiftdoc", module.swift.swiftdoc))

    privacy = getattr(entry, "privacy_manifests", [])
    if len(privacy) > 1:
        fail("%s: the plugin %s has %d privacy manifests, and a framework holds one" % (entry.label, entry.package, len(privacy)))
    for manifest in privacy:
        steps.append(("file", resources + "/PrivacyInfo.xcprivacy", manifest))
    steps.extend(_resource_steps(entry, resources))
    return steps

def _plugin_xcframeworks_impl(ctx):
    platform = ctx.attr._platform
    slices = SLICES[platform]
    per_package = {}
    for slice in slices:
        app_info = ctx.split_attr.application[slice.id][FlutterApplicationInfo]
        debug = slice.debug or app_info.is_debug
        for package, framework in _slice_plugins(ctx, slice, app_info, ctx.split_attr._cc_toolchain[slice.id], debug).items():
            per_package.setdefault(package, {})[slice.id] = framework

    outputs = []
    for package, frameworks in sorted(per_package.items()):
        if len(frameworks) != len(slices):
            fail("The plugin %s is built for %s only" % (package, ", ".join(sorted(frameworks.keys()))))
        plist = ctx.actions.declare_file("%s_slices/%s.xcframework.plist" % (ctx.label.name, package))
        xcframework_info_plist(
            ctx,
            plist,
            package,
            slices,
            dsyms = [slice_id for slice_id, f in frameworks.items() if f.has_dsym],
            static = ctx.attr.static,
        )
        xcframework = ctx.actions.declare_directory("%s/%s.xcframework" % (ctx.label.name, package))
        steps = [("file", "Info.plist", plist)]
        for slice in slices:
            steps.extend(frameworks[slice.id].steps)
        assemble_bundle(
            ctx,
            xcframework,
            steps,
            mnemonic = "FlutterPluginXCFramework",
            progress_message = "Assembling %s.xcframework for %%{label}" % package,
        )
        outputs.append(xcframework)
    return [DefaultInfo(files = depset(outputs))]

def _plugin_xcframeworks_rule(platform):
    return rule(
        implementation = _plugin_xcframeworks_impl,
        attrs = dicts.add(
            XCODE_TOOL_ATTRS,
            BUNDLE_ATTRS,
            {
                "application": attr.label(
                    doc = "The `flutter_application` whose Apple plugins are packaged.",
                    mandatory = True,
                    providers = [FlutterApplicationInfo],
                    cfg = SLICES_TRANSITION[platform],
                ),
                "minimum_os_version": attr.string(
                    doc = "The minimum %s version of the frameworks." % ("iOS" if platform == "ios" else "macOS"),
                    default = _MINIMUM_OS_VERSION[platform],
                ),
                "static": attr.bool(
                    doc = "Static frameworks, each binary an archive of the plugin's objects, as " +
                          "`flutter build %s-framework --static` makes them. Link them; do not " % platform +
                          "embed them.",
                ),
                "_cc_toolchain": attr.label(
                    default = "@rules_cc//cc:current_cc_toolchain",
                    cfg = SLICES_TRANSITION[platform],
                ),
                "_platform": attr.string(default = platform),
            },
        ),
        exec_groups = PORTABLE_EXEC_GROUPS,
        fragments = XCODE_TOOL_FRAGMENTS + ["cpp", "objc"],
        toolchains = XCODE_TOOL_TOOLCHAINS,
        doc = ("One xcframework per plugin of the application with %s code, named after the " +
               "plugin's module, as `flutter build %s-framework` makes them.") % (
            "iOS" if platform == "ios" else "macOS",
            platform,
        ),
    )

flutter_ios_plugin_xcframeworks = _plugin_xcframeworks_rule("ios")
flutter_macos_plugin_xcframeworks = _plugin_xcframeworks_rule("macos")

def _code_asset_xcframeworks_impl(ctx):
    platform = ctx.attr._platform
    slices = SLICES[platform]

    # Every library a slice could ship, by its name in the bundle: the
    # `native_deps` libraries, which always ship, and every code-asset
    # candidate. Which candidates ship is known only to the action below,
    # which reads each slice's program assets. `flutter_application` has
    # checked that no two of a slice's share a name.
    #
    # On iOS each is named by its framework, `ios_framework_names` of the
    # slice's libraries, as the slice's own manifest names it; a library is
    # one framework in every slice, so the slices must agree on its name.
    per_name = {}
    file_names = {}
    always = {}
    program_assets = {}
    framework_of = {}
    for slice in slices:
        app_info = ctx.split_attr.application[slice.id][FlutterApplicationInfo]
        program_assets[slice.id] = app_info.program_assets
        frameworks = app_ios_framework_names(native_library_files(app_info), app_info.program_assets) if platform == "ios" else {}
        for file_name, framework in frameworks.items():
            other = framework_of.setdefault(file_name, (framework, slice.id))
            if other[0] != framework:
                fail((
                    "%s: %s ships as `%s.framework` in the %s slice and as " +
                    "`%s.framework` in the %s slice, since the slices bundle " +
                    "different libraries whose framework names collide. One " +
                    "xcframework holds a library for every slice, under one name."
                ) % (ctx.label, file_name, other[0], other[1], framework, slice.id))
        for dylib in list(native_library_files(app_info)) + candidate_code_asset_libraries(app_info.program_assets):
            name = frameworks[dylib.basename] if platform == "ios" else dylib.basename
            per_name.setdefault(name, {})[slice.id] = dylib
            file_names[name] = dylib.basename
        for dylib in native_library_files(app_info):
            name = frameworks[dylib.basename] if platform == "ios" else dylib.basename
            always.setdefault(name, []).append(slice.id)

    # The libraries a slice bundles, each with its install name there: a
    # library that links another records it by its old install name, which
    # is rewritten, as the app's bundle does.
    install_name_changes = {}
    if platform == "ios":
        for slice in slices:
            install_name_changes[slice.id] = rewrite_install_names(
                ctx,
                "%s_slices/%s_install_names" % (ctx.label.name, slice.id),
                [
                    (dylibs[slice.id], "@rpath/%s.framework/%s" % (name, name))
                    for name, dylibs in sorted(per_name.items())
                    if len(dylibs) == len(slices)
                ],
            )

    candidates = {}
    for name, dylibs in sorted(per_name.items()):
        # As upstream's `verifyCodeAssetConsistency`: the device and simulator
        # builds must agree on every code asset. Of the `native_deps`
        # libraries that is known now; of the code assets, which a link hook
        # may keep in one slice and not the other, when they are built.
        if len(dylibs) != len(slices):
            if name in always:
                fail("The code asset %s is built for %s only; each slice must build the same code assets" % (name, ", ".join(sorted(dylibs.keys()))))
            continue
        steps = []
        for slice in slices:
            dylib = dylibs[slice.id]
            if platform == "ios":
                # A framework, as the app's bundle has it and its native-assets
                # manifest names it.
                binary = ctx.actions.declare_file("%s_slices/%s/%s.framework/%s" % (ctx.label.name, slice.id, name, name))
                process_native_library(
                    ctx,
                    library = dylib,
                    output = binary,
                    symbols = struct(dsym = False, strip = False),
                    mnemonic = "FlutterCodeAssetFramework",
                    install_name = "@rpath/%s.framework/%s" % (name, name),
                    install_name_changes = install_name_changes[slice.id],
                )
                plist = ctx.actions.declare_file("%s_slices/%s/%s.framework/Info.plist" % (ctx.label.name, slice.id, name))
                _framework_info_plist(ctx, plist, name, "io.flutter.flutter.native-assets.", platform)
                steps.extend([
                    ("file", "%s/%s.framework/%s" % (slice.id, name, name), binary),
                    ("file", "%s/%s.framework/Info.plist" % (slice.id, name), plist),
                ])
            else:
                # A library, as the macOS app's bundle has it (`Contents/Frameworks/<name>`)
                # and its native-assets manifest names it, its install name its
                # own name there: a host that links it (a Swift package's binary
                # target is linked) finds it through `@rpath`.
                library = ctx.actions.declare_file("%s_slices/%s/%s" % (ctx.label.name, slice.id, name))
                run_xcode_tool(
                    ctx,
                    command = 'cp "$1" "$2" && chmod u+w "$2" && xcrun install_name_tool -id "$3" "$2"',
                    arguments = [ctx.actions.args().add_all([dylib, library, "@rpath/" + name])],
                    inputs = [dylib],
                    outputs = [library],
                    mnemonic = "FlutterCodeAssetLibrary",
                    execution_requirements = PATH_MAPPING,
                    progress_message = "Naming %s for add-to-app" % name,
                )
                steps.append(("file", "%s/%s" % (slice.id, name), library))
        plist = ctx.actions.declare_file("%s_slices/%s.xcframework.plist" % (ctx.label.name, name))
        base = name[:-len(".dylib")] if name.endswith(".dylib") else name
        if platform == "ios":
            xcframework_info_plist(ctx, plist, name, slices)
        else:
            _library_xcframework_plist(ctx, plist, name, slices)
        xcframework = ctx.actions.declare_directory("%s_candidates/%s.xcframework" % (ctx.label.name, base))
        assemble_bundle(
            ctx,
            xcframework,
            [("file", "Info.plist", plist)] + steps,
            mnemonic = "FlutterCodeAssetXCFramework",
            progress_message = "Assembling %s.xcframework for %%{label}" % base,
        )
        candidates[name] = xcframework

    # One directory of the xcframeworks that ship.
    output = ctx.actions.declare_directory(ctx.label.name)
    args = ctx.actions.args()
    args.add_all("--output", [output], expand_directories = False)
    arguments = [args]
    inputs = []
    for slice in slices:
        code_assets = program_assets_action_args(ctx.actions, program_assets[slice.id], data = False, code = "names")
        arguments.extend([ctx.actions.args().add("--slice", slice.id), code_assets.args])
        inputs.append(code_assets.inputs)
    rest = ctx.actions.args()
    for name, xcframework in sorted(candidates.items()):
        if name in always:
            rest.add_all("--always", [xcframework], expand_directories = False)
        else:
            rest.add("--candidate", file_names[name])
            rest.add_all([xcframework], expand_directories = False)
    arguments.append(rest)
    run_code_assets_tool(
        ctx,
        "xcframeworks",
        arguments,
        depset(candidates.values(), transitive = inputs),
        [output],
        mnemonic = "FlutterCodeAssetXCFrameworks",
        progress_message = "Collecting the code-asset xcframeworks that ship for %{label}",
    )
    return [DefaultInfo(files = depset([output]))]

_LIBRARY_XCFRAMEWORK_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
{libraries}	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
"""

def _library_xcframework_plist(ctx, output, name, slices):
    """The `Info.plist` of an xcframework of a dynamic library, not a framework."""
    ctx.actions.write(output, _LIBRARY_XCFRAMEWORK_PLIST.format(libraries = "".join([
        ("\t\t<dict>\n\t\t\t<key>BinaryPath</key>\n\t\t\t<string>{name}</string>\n" +
         "\t\t\t<key>LibraryIdentifier</key>\n\t\t\t<string>{id}</string>\n" +
         "\t\t\t<key>LibraryPath</key>\n\t\t\t<string>{name}</string>\n" +
         "\t\t\t<key>SupportedArchitectures</key>\n\t\t\t<array>\n\t\t\t\t<string>{arch}</string>\n\t\t\t</array>\n" +
         "\t\t\t<key>SupportedPlatform</key>\n\t\t\t<string>{platform}</string>\n\t\t</dict>\n").format(
            name = name,
            id = slice.id,
            arch = slice.arch,
            platform = slice.platform_type,
        )
        for slice in slices
    ])))

def _code_asset_xcframeworks_rule(platform):
    return rule(
        implementation = _code_asset_xcframeworks_impl,
        attrs = dicts.add(
            XCODE_TOOL_ATTRS,
            BUNDLE_ATTRS,
            {
                "application": attr.label(
                    doc = "The `flutter_application` whose code assets are packaged.",
                    mandatory = True,
                    providers = [FlutterApplicationInfo],
                    cfg = SLICES_TRANSITION[platform],
                ),
                "minimum_os_version": attr.string(
                    doc = "The minimum version written into each framework's `Info.plist`.",
                    default = _MINIMUM_OS_VERSION[platform],
                ),
                "_platform": attr.string(default = platform),
            },
            CODE_ASSETS_TOOL_ATTRS,
        ),
        exec_groups = PORTABLE_EXEC_GROUPS,
        fragments = XCODE_TOOL_FRAGMENTS,
        toolchains = XCODE_TOOL_TOOLCHAINS,
        doc = ("A directory of one xcframework per code asset that ships (a dynamic library a Dart build hook or " +
               "`flutter_native_asset` bundles, less those a release build's link hooks drop), as " +
               "`flutter build %s-framework` makes them. The device build is the source of truth, as in " +
               "upstream's `verifyCodeAssetConsistency`: another slice may not ship a code asset it does " +
               "not. On iOS the simulator slice is built in debug, as upstream builds it, and runs no link " +
               "hook, so a release build whose link hooks drop a code asset fails, as " +
               "`flutter build ios-framework` does. %s") % (
            platform,
            "Each slice is a framework, as the app's native-assets manifest names it." if platform == "ios" else "Each slice is the library itself, as the app's native-assets manifest names it.",
        ),
    )

flutter_ios_code_asset_xcframeworks = _code_asset_xcframeworks_rule("ios")
flutter_macos_code_asset_xcframeworks = _code_asset_xcframeworks_rule("macos")
