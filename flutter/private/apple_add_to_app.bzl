"""What the Apple add-to-app rules share: slices, transitions, xcframework assembly.

Add-to-app hands a native team who build with Xcode a Flutter module as
xcframeworks, as `flutter build ios-framework` and `flutter build
macos-framework` do. Each rule here builds one xcframework set in the build
mode of its configuration, for each slice of the platform:

- iOS: `ios-arm64`, a device build in the configuration's mode, and
  `ios-arm64-simulator`, always a debug build, as upstream builds the
  simulator whatever the mode (its engine runs nothing else).
- macOS: `macos-arm64`.

Intel slices (`x86_64` simulator and Mac) are not built.
"""

load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "portable_tools")

visibility("//flutter/...")

_PROFILE = str(Label("//flutter:profile"))

# One entry per xcframework slice: its library identifier, the CPU of its
# platform, the apple_support platform it is built for and the target triple
# a Swift module interface of it is named after.
SLICES = {
    "ios": [
        struct(
            id = "ios-arm64",
            platform_type = "ios",
            arch = "arm64",
            split_cpu = "arm64",
            cpu = "ios_arm64",
            apple_platform = "ios_arm64",
            device = True,
            debug = False,
            triple = "arm64-apple-ios",
            variant = None,
        ),
        struct(
            id = "ios-arm64-simulator",
            platform_type = "ios",
            arch = "arm64",
            split_cpu = "sim_arm64",
            cpu = "ios_sim_arm64",
            apple_platform = "ios_sim_arm64",
            device = False,
            debug = True,
            triple = "arm64-apple-ios-simulator",
            variant = "simulator",
        ),
    ],
    "macos": [
        struct(
            id = "macos-arm64",
            platform_type = "macos",
            arch = "arm64",
            split_cpu = "arm64",
            cpu = "darwin_arm64",
            apple_platform = "macos_arm64",
            device = True,
            debug = False,
            triple = "arm64-apple-macos",
            variant = None,
        ),
    ],
}

# Swift modules are compiled with library evolution and a module interface,
# as Xcode compiles them with `BUILD_LIBRARY_FOR_DISTRIBUTION=YES`: a host
# compiled with another Swift compiler can import them.
_LIBRARY_EVOLUTION = ["swift.enable_library_evolution", "swift.emit_swiftinterface"]

_OUTPUTS = [
    "//command_line_option:apple_platform_type",
    "//command_line_option:apple_split_cpu",
    "//command_line_option:compiler",
    "//command_line_option:cpu",
    "//command_line_option:fission",
    "//command_line_option:grte_top",
    "//command_line_option:platforms",
    "//command_line_option:ios_minimum_os",
    "//command_line_option:macos_minimum_os",
    "//command_line_option:minimum_os_version",
    "//command_line_option:compilation_mode",
    "//command_line_option:features",
    _PROFILE,
]

def _slice_settings(slice, minimum_os_version, settings):
    """The configuration of one slice, as rules_apple's xcframework transition makes it."""
    features = list(settings["//command_line_option:features"])
    for feature in _LIBRARY_EVOLUTION:
        if feature not in features:
            features.append(feature)
    return {
        "//command_line_option:apple_platform_type": slice.platform_type,
        "//command_line_option:apple_split_cpu": slice.split_cpu,
        "//command_line_option:compiler": None,
        "//command_line_option:cpu": slice.cpu,
        "//command_line_option:fission": [],
        "//command_line_option:grte_top": None,
        "//command_line_option:platforms": [str(Label("@apple_support//platforms:" + slice.apple_platform))],
        "//command_line_option:ios_minimum_os": minimum_os_version if slice.platform_type == "ios" else None,
        "//command_line_option:macos_minimum_os": minimum_os_version if slice.platform_type == "macos" else None,
        "//command_line_option:minimum_os_version": minimum_os_version,
        "//command_line_option:compilation_mode": "dbg" if slice.debug else settings["//command_line_option:compilation_mode"],
        "//command_line_option:features": features,
        _PROFILE: False if slice.debug else settings[_PROFILE],
    }

def _slices_transition(platform):
    def impl(settings, attr):
        return {
            slice.id: _slice_settings(slice, attr.minimum_os_version, settings)
            for slice in SLICES[platform]
        }

    return transition(
        implementation = impl,
        inputs = [
            "//command_line_option:compilation_mode",
            "//command_line_option:features",
            _PROFILE,
        ],
        outputs = _OUTPUTS,
    )

# A split over the slices of each platform, keyed by library identifier. The
# rule that uses it has a `minimum_os_version` attribute.
SLICES_TRANSITION = {
    "ios": _slices_transition("ios"),
    "macos": _slices_transition("macos"),
}

BUNDLE_ATTRS = {
    "_apple_frameworks_tool": attr.label(
        default = "//flutter/private/tools:apple_frameworks.dart",
        allow_single_file = True,
    ),
    # What the tool imports.
    "_apple_frameworks_imports": attr.label_list(
        default = ["//flutter/private/tools:assemble_directory.dart"],
        allow_files = True,
    ),
}

def assemble_bundle(ctx, output, steps, mnemonic, progress_message):
    """Declares the action that fills the directory artifact `output`.

    Args:
        ctx: A rule context with `BUNDLE_ATTRS` and the `PORTABLE` exec group.
        output: The directory to fill.
        steps: Its contents, in order: `("file", name, file)`, `("tree", name,
            directory)` (its contents) or `("bundle", name, directory)` (a
            framework or xcframework).
        mnemonic: The action's mnemonic.
        progress_message: The action's progress message.
    """
    tools = portable_tools(ctx)
    tool = ctx.file._apple_frameworks_tool
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add_all("--output", [output], expand_directories = False)
    inputs = [tool] + ctx.files._apple_frameworks_imports
    for step in steps:
        kind = step[0]
        flag = {"file": "--add", "tree": "--add-tree", "bundle": "--add-bundle"}.get(kind)
        if not flag:
            fail("assemble_bundle: unknown step %r" % kind)
        args.add(flag, step[1])
        args.add_all([step[2]], expand_directories = False)
        inputs.append(step[2])
    ctx.actions.run(
        executable = tools.dart,
        arguments = [ctx.actions.args().add(tool), args],
        inputs = depset(direct = inputs, transitive = [tools.sdk_files.run]),
        outputs = [output],
        mnemonic = mnemonic,
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = progress_message,
    )

_XCFRAMEWORK_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
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

_XCFRAMEWORK_LIBRARY = """		<dict>
			<key>BinaryPath</key>
			<string>{binary}</string>
{debug_symbols}			<key>LibraryIdentifier</key>
			<string>{id}</string>
			<key>LibraryPath</key>
			<string>{path}</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>{arch}</string>
			</array>
			<key>SupportedPlatform</key>
			<string>{platform}</string>
{variant}		</dict>
"""

def xcframework_info_plist(ctx, output, name, slices, dsyms = [], static = False):
    """Writes the `Info.plist` of an xcframework of frameworks named `name`.

    The same file `xcodebuild -create-xcframework` writes.

    Args:
        ctx: A rule context.
        output: The File to write.
        name: The framework's name (`App` for `App.framework`).
        slices: The `SLICES` entries it has.
        dsyms: The library identifiers of the slices that have `dSYMs/`.
        static: Whether the frameworks are static (no `Versions/` on macOS
            then either; a static framework's binary is an archive).
    """
    libraries = []
    for slice in slices:
        versioned = slice.platform_type == "macos" and not static
        libraries.append(_XCFRAMEWORK_LIBRARY.format(
            binary = "%s.framework/%s%s" % (name, "Versions/A/" if versioned else "", name),
            debug_symbols = "\t\t\t<key>DebugSymbolsPath</key>\n\t\t\t<string>dSYMs</string>\n" if slice.id in dsyms else "",
            id = slice.id,
            path = name + ".framework",
            arch = slice.arch,
            platform = slice.platform_type,
            variant = "\t\t\t<key>SupportedPlatformVariant</key>\n\t\t\t<string>%s</string>\n" % slice.variant if slice.variant else "",
        ))
    ctx.actions.write(output, _XCFRAMEWORK_PLIST.format(libraries = "".join(libraries)))

def framework_root(slice, name, static = False):
    """Where a framework's contents go: `Versions/A` of a versioned (macOS) one.

    Bazel keeps no link to a directory in a directory artifact, so a versioned
    framework is its `Versions/A` alone until it leaves Bazel, when
    `apple_xcframeworks_export.dart` makes its links (`apple_frameworks.dart`).

    Args:
        slice: The `SLICES` entry.
        name: The framework's name.
        static: Whether it is a static framework, which is never versioned.

    Returns:
        The path under the xcframework, `<id>/<name>.framework[/Versions/A]`.
    """
    framework = "%s/%s.framework" % (slice.id, name)
    if slice.platform_type == "macos" and not static:
        return framework + "/Versions/A"
    return framework

def framework_resources(slice, name, static = False):
    """Where a framework's resources (`Info.plist` included) go.

    Args:
        slice: The `SLICES` entry.
        name: The framework's name.
        static: Whether it is a static framework.

    Returns:
        `<root>/Resources` on macOS, the framework's root on iOS.
    """
    root = framework_root(slice, name, static)
    return root + "/Resources" if slice.platform_type == "macos" else root

def dsym_steps(slice, framework, dsym_files):
    """The steps that place a framework's dSYM bundle in its slice's `dSYMs/`.

    Args:
        slice: The `SLICES` entry.
        framework: The framework's file name (`App.framework`).
        dsym_files: The bundle's files, each under `<something>.dSYM/`.

    Returns:
        A list of `assemble_bundle` steps.
    """
    steps = []
    for f in dsym_files:
        rest = f.path[f.path.index(".dSYM/") + len(".dSYM/"):]
        steps.append(("file", "%s/dSYMs/%s.dSYM/%s" % (slice.id, framework, rest), f))
    return steps

def relative_to(file, directory_name):
    """The path of `file` under the last directory of its path named `directory_name`.

    Args:
        file: A File.
        directory_name: A directory name in its path, such as `Flutter.xcframework`.

    Returns:
        The rest of the path after `<directory_name>/`.
    """
    marker = "/" + directory_name + "/"
    path = "/" + file.path
    index = path.rfind(marker)
    if index < 0:
        fail("%s is not in a directory named %s" % (file.path, directory_name))
    return path[index + len(marker):]
