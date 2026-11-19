"""The plugin and code-asset xcframeworks of Apple add-to-app.

`flutter build ios-framework` packages each plugin with Apple code as its own
xcframework, and each code asset (a Dart build hook's dynamic library) as one
more. These rules do the same, from the plugin libraries an application
carries (`FlutterApplicationInfo.apple_plugin_libraries`) and the code assets
it ships, in the build mode of the configuration.

A plugin's framework holds only that plugin's code. It is linked here, slice by
slice, from the plugin's own static libraries: Flutter is linked dynamically
(`@rpath/Flutter.framework/Flutter`, not copied in), and another plugin the
plugin uses is that plugin's own framework. So is each module of a Swift
package the plugins depend on, and each module of a plugin's own besides the
one named after it, as upstream makes each pod a plugin depends on a framework
of its own. The framework has the module the host imports:

- a Swift plugin: `Headers/<module>-Swift.h`, a module map naming it, and
  `Modules/<module>.swiftmodule/<triple>.swiftinterface`, compiled with
  library evolution as Xcode's `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` compiles
  it;
- an Objective-C plugin: its public headers in `Headers/`, under the umbrella
  header and module map CocoaPods gives a framework pod;
- a plugin of both: one module of the two, the Swift part its `Swift`
  submodule, as Xcode builds a mixed framework.

Plus `Info.plist`, the plugin's privacy manifest and resource bundles.

In profile and release, each slice of a plugin's framework and of a code
asset has its dSYM in `dSYMs/`, read from the objects its binary was linked
from, as `flutter build ios-framework` and `macos-framework` make one in every
such build. A code asset's binary is stripped of its local symbols and
debugging map, as upstream's `copyNativeCodeAssetsIOS` and `MacOS` strip it,
and a plugin's is not, as upstream's `xcodebuild build` of the Pods project
leaves it. A debug slice, the iOS simulator's in every mode, gets neither.
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING", "program_assets_action_args")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:apple_add_to_app.bzl", "BUNDLE_ATTRS", "MODULE_APP_SETTINGS_ATTRS", "SLICES", "SLICES_TRANSITION", "assemble_bundle", "framework_resources", "framework_root", "xcframework_info_plist")
load("//flutter/private:apple_xcode.bzl", "XCODE_TOOL_ATTRS", "XCODE_TOOL_FRAGMENTS", "XCODE_TOOL_TOOLCHAINS", "declare_library_dsym", "process_native_library", "rewrite_install_names", "run_xcode_tool")
load("//flutter/private:constants.bzl", "IOS_MINIMUM_OS_VERSION", "MACOS_MINIMUM_OS_VERSION")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//flutter/private:flutter_apple_plugin_library.bzl", "FlutterAppleLinkedTargetsInfo", "linked_targets_aspect")
load("//flutter/private:flutter_native_assets.bzl", "CODE_ASSETS_TOOL_ATTRS", "app_apple_framework_names", "app_macos_framework_names", "bundled_library_debug_info", "candidate_code_asset_libraries", "run_code_assets_tool")
load("//flutter/private:native_libraries.bzl", "native_library_files")
load("//flutter/private:swiftpm_app_settings.bzl", "FlutterSwiftPMAppLibrariesInfo", "SWIFTPM_APP_LIBRARIES", "app_library_entry", "check_swift_package_environment")
load("//flutter/private:unbuilt_native_code.bzl", "fail_on_unbuilt_native_code")

visibility("//flutter/...")

_MINIMUM_OS_VERSION = {"ios": IOS_MINIMUM_OS_VERSION, "macos": MACOS_MINIMUM_OS_VERSION}

# What a slice's binaries get, as `native_library_symbols` structs: in a
# debug slice nothing. Outside debug, a plugin's framework a dSYM and no
# stripping, as upstream builds it with `xcodebuild build` in the Pods
# project, whose release configurations are `DEBUG_INFORMATION_FORMAT =
# dwarf-with-dsym` and `STRIP_INSTALLED_PRODUCT = NO`; a code asset a dSYM and
# `strip -x -S`, as upstream's `dsymutilDylib` and `stripDylib`.
_DEBUG_SYMBOLS = struct(dsym = False, strip = False)
_PLUGIN_SYMBOLS = struct(dsym = True, strip = False)
_CODE_ASSET_SYMBOLS = struct(dsym = True, strip = True)

def _dsym_steps(dsym, path):
    """The steps that put a `declare_library_dsym` bundle at `path`, `<slice>/dSYMs/<bundle>.dSYM`."""
    return [
        ("file", path + "/" + f.path[f.path.index(".dSYM/") + len(".dSYM/"):], f)
        for f in dsym.files
    ]

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

def _dependency_units(entries, linked_targets):
    """The modules the plugins link besides their own, each a framework of its own.

    `flutter build ios-framework` builds each pod a plugin depends on as a
    framework of its own beside the plugin's, so two plugins on one pod share
    it. A Swift package's unit is its module (one SwiftPM target): the targets
    a plugin's library is linked from (`FlutterAppleLinkedTargetsInfo`) that
    own a static library, grouped by the module each is. A plugin's own
    targets are its framework, but for those of another module (a plugin's
    Package.swift of two targets, its Swift and its Objective-C, say), which
    its interface imports by that module's name.

    Args:
        entries: The `apple_plugin_libraries` structs of one slice.
        linked_targets: `FlutterAppleLinkedTargetsInfo.targets` of the slice's
            application and app-settings libraries, which may hold targets
            of plugin implementations the application did not choose.

    Returns:
        A list of entry-like structs: `label`, `package` (the module's name,
        which names its framework), `cc_info`, `swift_module`,
        `module_headers`, `owners` (the labels of its targets), `statics`
        (their own static libraries), `dependency` (whether it is no
        plugin's).
    """

    # The targets the chosen plugins link: the owners of their libraries.
    linked = {}
    for e in entries:
        for linker_input in e.cc_info.linking_context.linker_inputs.to_list():
            linked[str(linker_input.owner)] = True
    records = {}
    for record in linked_targets.to_list():
        if str(record.label) in linked:
            records.setdefault(str(record.label), record)

    by_name = {}
    for key in sorted(records.keys()):
        record = records[key]
        statics = []
        for linker_input in record.cc_info.linking_context.linker_inputs.to_list():
            if linker_input.owner == record.label:
                statics.extend(_static_libraries(linker_input))
        if not statics:
            continue
        modules = record.swift_info.direct_modules if record.swift_info else []
        if len(modules) > 1:
            fail("%s is the modules %s, and a framework is one" % (record.label, ", ".join([m.name for m in modules])))
        module = modules[0] if modules else None
        plugin = [e for e in entries if _same_package(record.label, e.label)]
        if plugin and (not module or module.name == plugin[0].package):
            continue
        name = module.name if module else record.label.name
        by_name.setdefault(name, []).append(struct(record = record, module = module, statics = statics, dependency = not plugin))

    units = []
    for name, parts in sorted(by_name.items()):
        # A module of Swift and C-family sources is two targets, its Swift
        # module and its Clang one.
        swift = [p for p in parts if p.module and p.module.swift]
        clang = [p for p in parts if not (p.module and p.module.swift)]
        if len(swift) > 1 or len(clang) > 1:
            fail("The targets %s are all the module %s" % (", ".join([str(p.record.label) for p in parts]), name))
        units.append(struct(
            label = parts[0].record.label,
            package = name,
            cc_info = cc_common.merge_cc_infos(cc_infos = [p.record.cc_info for p in parts]),
            swift_module = swift[0].module if swift else None,
            module_headers = clang[0].record.cc_info.compilation_context.direct_public_headers if clang and clang[0].module else [],
            owners = [p.record.label for p in parts],
            statics = [lib for p in parts for lib in p.statics],
            dependency = parts[0].dependency,
        ))
    return units

def _vendored_xcframeworks(entries, linked_targets):
    """The prebuilt dynamic xcframeworks the plugins link: a dict from a slice's binary path to its xcframework.

    A Swift package's `binaryTarget` of a dynamic framework, which
    rules_swift_package_manager imports with `apple_dynamic_xcframework_import`,
    as a pod's `vendored_frameworks` is one. `flutter build ios-framework`
    copies a vendored xcframework into the layout as it is, and so does
    add-to-app: the plugin's framework links the slice's framework.

    Returns:
        A dict from the path of a binary in an xcframework to a struct of
        `name` (the xcframework's, without the extension), `root` (its
        path) and `files` (every file of it).
    """
    linked = {}
    for e in entries:
        for linker_input in e.cc_info.linking_context.linker_inputs.to_list():
            linked[str(linker_input.owner)] = True
    vendored = {}
    for record in linked_targets.to_list():
        if not record.xcframework_files or str(record.label) not in linked:
            continue
        for linker_input in record.cc_info.linking_context.linker_inputs.to_list():
            if linker_input.owner != record.label:
                continue
            for lib in linker_input.libraries:
                binary = lib.resolved_symlink_dynamic_library or lib.dynamic_library
                if not binary or ".xcframework/" not in binary.path:
                    continue
                root = binary.path[:binary.path.index(".xcframework/") + len(".xcframework")]
                vendored[binary.path] = struct(
                    name = root.rsplit("/", 1)[-1][:-len(".xcframework")],
                    root = root,
                    files = [f for f in record.xcframework_files if f.path.startswith(root + "/")],
                )
    return vendored

def _vendored_steps(prebuilt):
    """The steps that copy a prebuilt xcframework's files into its copy.

    A versioned (macOS) framework's links arrive as files, since a glob
    follows them: `Versions/Current/` and the entries at its top. These rules
    keep a versioned framework as its version directory alone, whose links the
    export makes (`framework_root`), so those copies are left out, and the
    exported framework has the links it was signed with.
    """
    paths = [(f.path[len(prebuilt.root) + 1:], f) for f in prebuilt.files]
    versioned = {
        path.split(".framework/", 1)[0]: True
        for path, _ in paths
        if ".framework/Versions/" in path
    }
    steps = []
    for path, f in paths:
        if ".framework/" in path:
            framework, inside = path.split(".framework/", 1)
            if framework in versioned and (not inside.startswith("Versions/") or inside.startswith("Versions/Current/")):
                continue
        steps.append(("file", path, f))
    return steps

def _dependency_module(unit):
    """`_plugin_module` of a Swift package's module."""
    swift = unit.swift_module
    swift_header = None
    if swift and swift.clang and swift.clang.compilation_context:
        for header in swift.clang.compilation_context.direct_public_headers:
            if header.basename == unit.package + "-Swift.h":
                swift_header = header
    return struct(
        name = unit.package,
        # A Swift package's public headers directory may hold its own
        # module map, which the framework's replaces.
        objc_headers = [h for h in unit.module_headers if h.extension == "h" and not h.basename.endswith("-Swift.h")],
        swift_header = swift_header,
        swift = swift.swift if swift else None,
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

def _resources(entries, unit_of_label):
    """The resources of each framework: a dict from unit name to (path in the framework, File) pairs.

    A plugin's library carries the resources of every target it is linked
    from. Each goes to the framework of the target that owns it: a Swift
    package module's resource bundle to that module's framework, where its
    `Bundle.module` looks, and the rest to the plugin's.
    """
    resources = {}
    for entry in entries:
        info = getattr(entry, "resource_info", None)
        if not info:
            continue
        for kind in _RESOURCE_KINDS:
            if getattr(info, kind, None):
                fail(("%s: the plugin %s has %s resources, which an add-to-app framework " +
                      "does not compile yet. Only plain files are copied.") % (entry.label, entry.package, kind))
        owners = {path: owner for path, owner in info.owners.to_list()}
        for kind in _COPIED_RESOURCES:
            for parent_dir, _, files in getattr(info, kind, []) or []:
                for f in files.to_list():
                    unit = unit_of_label.get(str(owners.get(f.short_path)), entry.package)
                    path = "%s%s" % (parent_dir + "/" if parent_dir else "", f.basename)
                    if (path, f) not in resources.setdefault(unit, []):
                        resources[unit].append((path, f))
    return resources

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

def _slice_plugins(ctx, slice, app_info, app_libraries, linked_targets, toolchain, symbols):
    """The frameworks of one slice.

    Returns:
        A struct of `built` (a dict from module name to its framework's
        steps) and `vendored` (the prebuilt xcframeworks they link, by name).
    """
    platform = slice.platform_type

    # A plugin whose Package.swift decides its defines from the app is built
    # for the module, in the slice's configuration, as an app builds it for
    # itself (`swiftpm_app_settings.bzl`).
    entries = [
        app_library_entry(e, app_libraries)
        for e in app_info.apple_plugin_libraries.to_list()
        if e.platform == platform
    ]
    fail_on_unbuilt_native_code(entries)
    for e in entries:
        if not e.cc_info:
            fail("%s: the plugin %s has no C-family or Swift library" % (e.label, e.package))

    modules = {e.package: _plugin_module(e) for e in entries}
    vendored = _vendored_xcframeworks(entries, linked_targets)
    used_vendored = {}
    dependencies = _dependency_units(entries, linked_targets)
    for d in dependencies:
        if d.package in modules:
            fail("%s: the module %s of a Swift package the plugins depend on has the name of the plugin %s, and the two frameworks would collide" % (d.label, d.package, d.package))
        modules[d.package] = _dependency_module(d)

    # Each plugin's own static libraries: those of the targets in its
    # library's package. Each dependency module's: those of its targets.
    # Another unit's are that unit's framework.
    owner_of = {}
    for e in entries:
        for linker_input in e.cc_info.linking_context.linker_inputs.to_list():
            if _same_package(linker_input.owner, e.label):
                for lib in _static_libraries(linker_input):
                    owner_of[lib.path] = e.package
    unit_of_label = {}
    for d in dependencies:
        for owner in d.owners:
            unit_of_label[str(owner)] = d.package
        for lib in d.statics:
            owner_of[lib.path] = d.package

    by_package = {e.package: e for e in entries + dependencies}

    def plugin_of(owner):
        if str(owner) in unit_of_label:
            return unit_of_label[str(owner)]
        for e in entries:
            if _same_package(owner, e.label):
                return e.package
        return None

    # What each unit links: its own libraries and flags, the units it uses,
    # and the engine.
    plans = {}
    for package, entry in by_package.items():
        libraries = []
        flags = []
        additional = []
        frameworks = []
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
                # The engine's framework, or a prebuilt xcframework's, which
                # the layout carries as it is.
                marker = "/%s.framework/" % _FLUTTER[platform]
                if marker in real.path:
                    framework = (real.path[:real.path.index(marker)], _FLUTTER[platform])
                elif real.path in vendored:
                    framework_path = real.path[:real.path.rindex(".framework/") + len(".framework")]
                    directory, framework_name = framework_path.rsplit("/", 1)
                    framework = (directory, framework_name[:-len(".framework")])
                    used_vendored[vendored[real.path].name] = vendored[real.path]
                else:
                    fail("%s: %s links the dynamic library %s, which add-to-app does not package yet" % (entry.label, package, real.path))
                if framework not in frameworks:
                    frameworks.append(framework)
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
            # Every target a plugin's library is linked from is a unit, so
            # only a library no target's CcInfo owns lands here.
            fail("%s: %s links %s, which no target it depends on owns" % (
                entry.label,
                package,
                ", ".join(sorted(foreign.keys())),
            ))
        plans[package] = struct(
            libraries = libraries,
            flags = flags,
            additional = additional,
            frameworks = frameworks,
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
        fail("The Apple plugins and Swift package modules %s link each other in a cycle" % ", ".join(sorted([p for p in plans if p not in placed])))

    resources = _resources(entries, unit_of_label)
    built = {}
    for package in order:
        entry = by_package[package]
        module = modules[package]
        plan = plans[package]
        dependencies = list(plan.frameworks)
        additional = list(plan.additional)
        for other in plan.uses:
            dependencies.append((built[other].binary_dir, other))
            additional.append(built[other].binary)

        dsym = None
        if ctx.attr.static:
            binary = _archive(ctx, slice, module, plan.libraries)
        else:
            linked = _link(ctx, slice, toolchain, module, plan.libraries, plan.flags, additional, dependencies)

            # The binary the framework ships, named as the framework names
            # it, for a plugin that links this one to find with `-F`. Its
            # debugging map names the plugin's own static libraries, which
            # its dSYM is read from.
            binary = ctx.actions.declare_file("%s_slices/%s/link/%s.framework/%s" % (ctx.label.name, slice.id, module.name, module.name))
            if symbols.dsym or symbols.strip:
                dsym = declare_library_dsym(ctx, "%s_slices/%s/dsym" % (ctx.label.name, slice.id), module.name + ".framework", module.name) if symbols.dsym else None
                process_native_library(
                    ctx,
                    library = linked,
                    output = binary,
                    symbols = symbols,
                    mnemonic = "FlutterPluginFramework",
                    dsym = dsym,
                    debug_info = struct(link_inputs = depset(plan.libraries + plan.additional), dsym = None),
                )
            else:
                ctx.actions.symlink(output = binary, target_file = linked)

        steps = _framework_steps(ctx, slice, entry, module, binary, resources.get(package, []))
        if dsym:
            steps.extend(_dsym_steps(dsym, "%s/dSYMs/%s.framework.dSYM" % (slice.id, module.name)))
        built[package] = struct(
            steps = steps,
            binary = binary,
            binary_dir = binary.dirname.rsplit("/", 1)[0],
            has_dsym = bool(dsym),
        )
    for name in used_vendored:
        if name in built:
            fail("The prebuilt %s.xcframework has the name of a framework built from %s" % (name, by_package[name].label))
    return struct(built = built, vendored = used_vendored)

def _framework_steps(ctx, slice, entry, module, binary, resource_files):
    name = module.name
    static = ctx.attr.static
    root = framework_root(slice, name, static)
    resources = framework_resources(slice, name, static)
    directory = "%s_slices/%s/%s" % (ctx.label.name, slice.id, name)
    steps = [("file", "%s/%s" % (root, name), binary)]

    plist = ctx.actions.declare_file(directory + "/Info.plist")
    prefix = "io.flutter.flutter.swift-packages." if getattr(entry, "dependency", False) else "io.flutter.flutter.plugins."
    _framework_info_plist(ctx, plist, name, prefix, slice.platform_type)
    steps.append(("file", resources + "/Info.plist", plist))

    # A Swift module with no Objective-C interface is its `.swiftmodule`
    # alone, as Xcode builds one.
    if module.objc_headers or module.swift_header:
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
        steps.append(("file", "%s/Headers/%s-Swift.h" % (root, name), module.swift_header))
    if module.swift:
        interface = module.swift.swiftinterface
        if not interface:
            fail("%s: %s has no Swift module interface; it is compiled without library evolution" % (entry.label, entry.package))
        swiftmodule = "%s/Modules/%s.swiftmodule/%s" % (root, name, slice.triple)
        steps.append(("file", swiftmodule + ".swiftinterface", interface))
        if module.swift.swiftdoc:
            steps.append(("file", swiftmodule + ".swiftdoc", module.swift.swiftdoc))

    privacy = getattr(entry, "privacy_manifests", [])
    if len(privacy) > 1:
        fail("%s: the plugin %s has %d privacy manifests, and a framework holds one" % (entry.label, entry.package, len(privacy)))
    for manifest in privacy:
        steps.append(("file", resources + "/PrivacyInfo.xcprivacy", manifest))
    steps.extend([("file", "%s/%s" % (resources, path), f) for path, f in resource_files])
    return steps

def _plugin_xcframeworks_impl(ctx):
    check_swift_package_environment(ctx)
    platform = ctx.attr._platform
    slices = SLICES[platform]
    per_package = {}
    vendored = {}
    for slice in slices:
        app_info = ctx.split_attr.application[slice.id][FlutterApplicationInfo]
        debug = slice.debug or app_info.is_debug
        app_libraries = ctx.split_attr._app_settings_libraries[slice.id][FlutterSwiftPMAppLibrariesInfo]
        linked_targets = depset(transitive = [
            ctx.split_attr.application[slice.id][FlutterAppleLinkedTargetsInfo].targets,
            ctx.split_attr._app_settings_libraries[slice.id][FlutterAppleLinkedTargetsInfo].targets,
        ])
        result = _slice_plugins(ctx, slice, app_info, app_libraries, linked_targets, ctx.split_attr._cc_toolchain[slice.id], _DEBUG_SYMBOLS if debug else _PLUGIN_SYMBOLS)
        for package, framework in result.built.items():
            per_package.setdefault(package, {})[slice.id] = framework
        for name, xcframework in result.vendored.items():
            vendored.setdefault(name, xcframework)

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

    # A prebuilt xcframework, copied as it is, as upstream copies a pod's
    # vendored one, with every slice it has and its own signature.
    for name, prebuilt in sorted(vendored.items()):
        xcframework = ctx.actions.declare_directory("%s/%s.xcframework" % (ctx.label.name, name))
        assemble_bundle(
            ctx,
            xcframework,
            _vendored_steps(prebuilt),
            mnemonic = "FlutterVendoredXCFramework",
            progress_message = "Copying %s.xcframework for %%{label}" % name,
        )
        outputs.append(xcframework)
    return [DefaultInfo(files = depset(outputs))]

def _plugin_xcframeworks_rule(platform):
    return rule(
        implementation = _plugin_xcframeworks_impl,
        attrs = dicts.add(
            XCODE_TOOL_ATTRS,
            BUNDLE_ATTRS,
            MODULE_APP_SETTINGS_ATTRS,
            {
                "application": attr.label(
                    doc = "The `flutter_application` whose Apple plugins are packaged.",
                    mandatory = True,
                    providers = [FlutterApplicationInfo],
                    cfg = SLICES_TRANSITION[platform],
                    # The targets the plugins are linked from, of which the
                    # Swift package modules' frameworks are made.
                    aspects = [linked_targets_aspect],
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
                # The plugins whose Package.swift decides its defines from the
                # app, built in each slice's configuration, which carries the
                # module's `info_plist` and `swift_package_environment`.
                "_app_settings_libraries": attr.label(
                    default = SWIFTPM_APP_LIBRARIES,
                    cfg = SLICES_TRANSITION[platform],
                    providers = [FlutterSwiftPMAppLibrariesInfo],
                    aspects = [linked_targets_aspect],
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
    check_swift_package_environment(ctx)
    platform = ctx.attr._platform
    slices = SLICES[platform]

    # Every library a slice could ship, by its name in the bundle: the
    # `native_deps` libraries, which always ship, and every code-asset
    # candidate. Which candidates ship is known only to the action below,
    # which reads each slice's program assets. `flutter_application` has
    # checked that no two of a slice's share a name.
    #
    # A library the app wraps in a framework (on iOS each, on macOS each code
    # asset's) is named by it, `apple_framework_names` of the slice's
    # libraries, as the slice's own manifest names it; a library is one
    # framework in every slice, so the slices must agree on its name. Any
    # other is named by its file name.
    per_name = {}
    file_names = {}
    always = {}
    program_assets = {}
    framework_of = {}
    wrapped = {}
    for slice in slices:
        app_info = ctx.split_attr.application[slice.id][FlutterApplicationInfo]
        program_assets[slice.id] = app_info.program_assets
        frameworks = (app_apple_framework_names if platform == "ios" else app_macos_framework_names)(native_library_files(app_info), app_info.program_assets)
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
            name = frameworks.get(dylib.basename, dylib.basename)
            per_name.setdefault(name, {})[slice.id] = dylib
            file_names[name] = dylib.basename
            if dylib.basename in frameworks:
                wrapped[name] = True
        for dylib in native_library_files(app_info):
            name = frameworks.get(dylib.basename, dylib.basename)
            always.setdefault(name, []).append(slice.id)

    # The libraries a slice bundles, each with its install name there: a
    # library that links another records it by its old install name, which
    # is rewritten, as the app's bundle does.
    install_name_changes = {}
    for slice in slices:
        install_name_changes[slice.id] = rewrite_install_names(
            ctx,
            "%s_slices/%s_install_names" % (ctx.label.name, slice.id),
            [
                (dylibs[slice.id], _code_asset_install_name(name, name in wrapped))
                for name, dylibs in sorted(per_name.items())
                if len(dylibs) == len(slices)
            ],
        )

    # Each binary is stripped, and has its dSYM, as `copyNativeCodeAssetsIOS`
    # and `copyNativeCodeAssetsMacOS` treat it in every non-debug build.
    symbols = {}
    debug_info = {}
    for slice in slices:
        application = ctx.split_attr.application[slice.id]
        symbols[slice.id] = _DEBUG_SYMBOLS if slice.debug or application[FlutterApplicationInfo].is_debug else _CODE_ASSET_SYMBOLS
        debug_info[slice.id] = bundled_library_debug_info(application) if symbols[slice.id].dsym else {}

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
        dsyms = []
        for slice in slices:
            dylib = dylibs[slice.id]

            # A framework, as the app's bundle has it and its native-assets
            # manifest names it: on iOS each library, on macOS each code
            # asset, versioned as `flutter build macos-framework` makes it,
            # under upstream's install name `@rpath/<name>.framework/<name>`.
            # Any other a library, as the app's bundle has it
            # (`Contents/Frameworks/<name>`), its install name its own name
            # there. A host that links either (a Swift package's binary target
            # is linked) finds it through `@rpath`. Its dSYM is
            # `<name>.framework.dSYM` or `<name>.dSYM`, as the app's.
            framework = name in wrapped
            path = "%s/%s" % (framework_root(slice, name), name) if framework else "%s/%s" % (slice.id, name)
            bundle = name + ".framework" if framework else name
            binary = ctx.actions.declare_file("%s_slices/%s/%s" % (ctx.label.name, slice.id, path[len(slice.id) + 1:]))
            dsym = declare_library_dsym(ctx, "%s_slices/%s/dSYMs" % (ctx.label.name, slice.id), bundle, name) if symbols[slice.id].dsym else None
            process_native_library(
                ctx,
                library = dylib,
                output = binary,
                symbols = symbols[slice.id],
                mnemonic = "FlutterCodeAsset" + ("Framework" if framework else "Library"),
                dsym = dsym,
                debug_info = debug_info[slice.id].get(dylib),
                install_name = _code_asset_install_name(name, framework),
                install_name_changes = install_name_changes[slice.id],
            )
            steps.append(("file", path, binary))
            if framework:
                plist = ctx.actions.declare_file("%s_slices/%s/%s.framework/Info.plist" % (ctx.label.name, slice.id, name))
                _framework_info_plist(ctx, plist, name, "io.flutter.flutter.native-assets.", platform)
                steps.append(("file", framework_resources(slice, name) + "/Info.plist", plist))
            if dsym:
                steps.extend(_dsym_steps(dsym, "%s/dSYMs/%s.dSYM" % (slice.id, bundle)))
                dsyms.append(slice.id)
        plist = ctx.actions.declare_file("%s_slices/%s.xcframework.plist" % (ctx.label.name, name))
        base = name[:-len(".dylib")] if name.endswith(".dylib") else name
        if name in wrapped:
            xcframework_info_plist(ctx, plist, name, slices, dsyms = dsyms)
        else:
            _library_xcframework_plist(ctx, plist, name, slices, dsyms = dsyms)
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

def _code_asset_install_name(name, framework):
    """The install name of the library `name` in an add-to-app slice, in a `framework` of its own or not."""
    return "@rpath/%s.framework/%s" % (name, name) if framework else "@rpath/" + name

def _library_xcframework_plist(ctx, output, name, slices, dsyms = []):
    """The `Info.plist` of an xcframework of a dynamic library, not a framework.

    Args:
        ctx: A rule context.
        output: The File to write.
        name: The library's file name.
        slices: The `SLICES` entries it has.
        dsyms: The library identifiers of the slices that have `dSYMs/`.
    """
    ctx.actions.write(output, _LIBRARY_XCFRAMEWORK_PLIST.format(libraries = "".join([
        ("\t\t<dict>\n\t\t\t<key>BinaryPath</key>\n\t\t\t<string>{name}</string>\n" +
         ("\t\t\t<key>DebugSymbolsPath</key>\n\t\t\t<string>dSYMs</string>\n" if slice.id in dsyms else "") +
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
            MODULE_APP_SETTINGS_ATTRS,
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
        fragments = XCODE_TOOL_FRAGMENTS + ["cpp"],
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
