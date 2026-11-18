"""Apple plugins whose `Package.swift` decides its defines from the app.

Some plugins' manifests compute their C or Swift defines from what surrounds
the build: `permission_handler_apple` reads the app's Info.plist and compiles
in each permission whose usage description the plist has; `audio_session` and
`geolocator_apple` read an environment variable. Under `flutter build`, Xcode
evaluates the manifest with its working directory in the app and the user's
shell environment, once per app.

rules_flutter does the same per app, in the build. `flutter_pub_package` marks
such a plugin (`find_manifest_computations` and `find_swiftpm_build_settings`
both find something in its manifest), and its Apple repository builds it in
three parts:

* The plugin's library, as the fetch-time `dump-package` describes it, but
  with its defines taken from `flutter_swiftpm_app_settings`, one per target of
  the package. That rule evaluates the manifest with Xcode's `swift package`,
  in an action, for the app the build settings below name: with `PWD` in a
  stand-in of the app's folder holding the app's Info.plist, and with the
  environment the app gives. Its defines become a header, which every C-family
  compile of the target includes, and a response file, which its Swift compile
  reads. Anything else the evaluation finds different from the fetch-time one
  fails the build: only defines may depend on the app.
* `flutter_swiftpm_app_library`, named as the plugin's library is
  (`<package>_apple_<platform>`), which the plugin's `flutter_plugin_platform` names as its `lib`. It is
  a marker that names the library, and builds nothing.
* An entry in `@flutter_pub_apple_app_settings//:libraries`, the build's list
  of such libraries (`flutter_apple_app_settings_repo`).

An Apple app's `flutter_apple_plugins_aggregator` depends on that list through
`swiftpm_app_transition`, which sets the two build settings to the app's
Info.plist and its `swift_package_environment`, and links the library of each
marker in the app's graph from there. Apps with the same Info.plist target and
environment share one build of each such plugin; another app gets its own.

The app's runner is built in that configuration too (`flutter_apple_app_runner`),
and with it every plugin the app links: a Swift compile that imports the
engine's module, or under explicit Clang modules an SDK module, from two
configurations fails. The app macros build the whole bundle there
(`flutter_apple_app`), so that the bundle and the runner reach the app's
`flutter_application` in one configuration; the runner's own transition is
then the configuration it is already in. In a build with no such plugin the
transition changes nothing, and apps share their plugins' builds.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_apple//apple:providers.bzl", "AppleResourceInfo")

# rules_apple has no public aspect that collects a library's resources, so
# this is its internal one, as in flutter_plugin.bzl.
# buildifier: disable=bzl-visibility
load("@rules_apple//apple/internal/aspects:resource_aspect.bzl", "apple_resource_aspect")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("@rules_swift//swift:swift.bzl", "SwiftInfo", "swift_clang_module_aspect")
load(":apple_xcode.bzl", "XCODE_TOOL_ATTRS", "XCODE_TOOL_FRAGMENTS", "XCODE_TOOL_TOOLCHAINS", "run_xcode_tool")
load(":exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")
load(":unbuilt_native_code.bzl", "FlutterUnbuiltNativeCodeInfo")

# The build settings an app sets for the plugins it builds this way.
_INFO_PLIST = Label("//flutter/private:swiftpm_app_info_plist")
_ENVIRONMENT = Label("//flutter/private:swiftpm_app_environment")
_NO_APP_INFO_PLIST = Label("//flutter/private:swiftpm_no_app_Info.plist")

# The build's libraries of such plugins (`flutter_apple_app_settings_repo`).
SWIFTPM_APP_LIBRARIES = Label("@flutter_pub_apple_app_settings//:libraries")

# What `swift_package_environment` may not set: what the evaluation sets itself.
_RESERVED_ENVIRONMENT = ("HOME", "PWD", "TMPDIR")

def swift_package_environment_problems(environment):
    """What is wrong with a `swift_package_environment`, as a list of strings.

    Args:
        environment: The dict.

    Returns:
        One string per problem, empty when there is none.
    """
    problems = []
    for name in sorted(environment.keys()):
        if name in _RESERVED_ENVIRONMENT:
            problems.append("`{}` is set by the evaluation itself".format(name))
        elif not name or name[0].isdigit() or [c for c in name.elems() if not (c.isalnum() or c == "_")]:
            problems.append("`{}` is not an environment variable's name".format(name))
    return problems

# Whether the build has any such library (`flutter_apple_app_settings_repo`).
SWIFTPM_APP_LIBRARIES_ANY = Label("@flutter_pub_apple_app_settings//:any")

def _swiftpm_app_transition_impl(settings, attr):
    # With no plugin that reads them, the settings change nothing: the app's
    # native code stays in the configuration it is in, shared with other apps.
    if not settings[str(SWIFTPM_APP_LIBRARIES_ANY)]:
        return {
            str(_INFO_PLIST): settings[str(_INFO_PLIST)],
            str(_ENVIRONMENT): settings[str(_ENVIRONMENT)],
        }
    return {
        str(_INFO_PLIST): str(attr.info_plist or _NO_APP_INFO_PLIST),
        str(_ENVIRONMENT): sorted(["%s=%s" % (k, v) for k, v in attr.swift_package_environment.items()]),
    }

swiftpm_app_transition = transition(
    implementation = _swiftpm_app_transition_impl,
    inputs = [str(SWIFTPM_APP_LIBRARIES_ANY), str(_INFO_PLIST), str(_ENVIRONMENT)],
    outputs = [str(_INFO_PLIST), str(_ENVIRONMENT)],
)

def _flutter_apple_app_runner_impl(ctx):
    problems = swift_package_environment_problems(ctx.attr.swift_package_environment)
    if problems:
        fail("{}: `swift_package_environment` is the environment of the plugins' Package.swift:\n    {}".format(
            ctx.label,
            "\n    ".join(problems),
        ))
    runner = ctx.attr.deps[0]
    providers = [DefaultInfo(
        files = runner[DefaultInfo].files,
        runfiles = runner[DefaultInfo].default_runfiles,
    )]
    for provider in (CcInfo, SwiftInfo, OutputGroupInfo, InstrumentedFilesInfo):
        if provider in runner:
            providers.append(runner[provider])
    return providers

flutter_apple_app_runner = rule(
    implementation = _flutter_apple_app_runner_impl,
    attrs = {
        "deps": attr.label_list(
            # Named `deps`, as the app's own attribute is, so that rules_apple's
            # aspects (resources, Swift usage) walk through to the runner.
            cfg = swiftpm_app_transition,
            mandatory = True,
            providers = [CcInfo],
            doc = "The runner: one `swift_library`, built in the app's configuration.",
        ),
        "info_plist": attr.label(
            allow_single_file = [".plist"],
            doc = "As the app's `flutter_apple_plugins_aggregator`'s.",
        ),
        "swift_package_environment": attr.string_dict(
            doc = "As the app's `flutter_apple_plugins_aggregator`'s.",
        ),
    },
    doc = """The app's runner, built in the configuration that `swiftpm_app_transition` gives the app.

The plugins whose defines come from the app are built in that
configuration, and so is everything they import: the engine's module and,
under explicit Clang modules, the SDK's. The runner imports the same modules,
and a compile that sees one module from two configurations fails ("signature
mismatch"). So the runner, and with it the aggregator and every plugin the
app links, is built there too, and the app's `deps` name this target in its
place. The aggregator's own transition, with the same settings, is then the
configuration it is already in, and so is this one's under an app macro,
which builds the whole bundle there (`flutter_apple_app`).
""",
)

FlutterSwiftPMAppLibraryInfo = provider(
    doc = "Stands for a plugin library whose defines come from the app (`flutter_swiftpm_app_library`).",
    fields = {
        "library": "Label: the library, which `@flutter_pub_apple_app_settings//:libraries` holds.",
    },
)

def _flutter_swiftpm_app_library_impl(ctx):
    return [FlutterSwiftPMAppLibraryInfo(library = ctx.label.same_package_label(ctx.attr.library))]

flutter_swiftpm_app_library = rule(
    implementation = _flutter_swiftpm_app_library_impl,
    attrs = {
        "library": attr.string(
            mandatory = True,
            doc = "The name of the library in this package. Not a dependency: the library is built for each app, under `swiftpm_app_transition`.",
        ),
    },
    doc = "Names, as the `lib` of a plugin's `flutter_plugin_platform`, a library whose defines its `Package.swift` decides from the app. See the module docstring.",
)

FlutterSwiftPMAppLibrariesInfo = provider(
    doc = "The build's plugin libraries whose defines come from the app, built for one app.",
    fields = {
        "libraries": "dict of `str(Label)` to a struct with `cc_info`, `swift_info`, `resource_info` and `unbuilt_native_code` (each None when absent).",
    },
)

def _flutter_swiftpm_app_libraries_impl(ctx):
    libraries = {}
    for dep in ctx.attr.deps:
        unbuilt = dep[FlutterUnbuiltNativeCodeInfo] if FlutterUnbuiltNativeCodeInfo in dep else None
        libraries[str(dep.label)] = struct(
            cc_info = dep[CcInfo] if CcInfo in dep else None,
            swift_info = dep[SwiftInfo] if SwiftInfo in dep else None,
            resource_info = dep[AppleResourceInfo] if AppleResourceInfo in dep else None,
            unbuilt_native_code = unbuilt.message if unbuilt else None,
        )
    return [FlutterSwiftPMAppLibrariesInfo(libraries = libraries)]

flutter_swiftpm_app_libraries = rule(
    implementation = _flutter_swiftpm_app_libraries_impl,
    attrs = {
        "deps": attr.label_list(
            doc = "The libraries, each `flutter_apple_plugin_library` or the stand-in that fails its build.",
            # And the module of an Objective-C library as Swift sees it.
            aspects = [apple_resource_aspect, swift_clang_module_aspect],
        ),
    },
    doc = "The build's plugin libraries whose defines come from the app: `@flutter_pub_apple_app_settings//:libraries`.",
)

def defines_header_name(name):
    """The header a `flutter_swiftpm_app_settings` named `name` writes, for `-include`."""
    return name + ".h"

# The stand-in of the app's Xcode project: just where its Info.plist is.
_PBXPROJ = """\
// The app's Xcode project, as a plugin's Package.swift reads it: written by
// rules_flutter for this evaluation, naming the Info.plist the app is built
// from.
{
\tobjects = {
\t\tRunnerBuildSettings = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tINFOPLIST_FILE = Runner/Info.plist;
\t\t\t};
\t\t};
\t};
}
"""

_PUBSPEC = """\
# The app a plugin's Package.swift is evaluated for, written by rules_flutter.
name: app
"""

def _flutter_swiftpm_app_settings_impl(ctx):
    platform = ctx.attr.platform
    environment = ctx.attr._environment[BuildSettingInfo].value

    # The stand-in of the app's folder: a pubspec.yaml, and in `ios/` (or
    # `macos/`) the Xcode project and the Info.plist it names, as `flutter
    # create` lays them out.
    root = ctx.label.name + "_app"
    pubspec = ctx.actions.declare_file(root + "/pubspec.yaml")
    ctx.actions.write(pubspec, _PUBSPEC)
    pbxproj = ctx.actions.declare_file("{}/{}/Runner.xcodeproj/project.pbxproj".format(root, platform))
    ctx.actions.write(pbxproj, _PBXPROJ)
    plist = ctx.actions.declare_file("{}/{}/Runner/Info.plist".format(root, platform))
    ctx.actions.symlink(output = plist, target_file = ctx.file._info_plist)

    # The manifest alone, in a directory of its own: SwiftPM reads nothing
    # else to evaluate it.
    manifest = ctx.actions.declare_file(ctx.label.name + "_package/Package.swift")
    ctx.actions.symlink(output = manifest, target_file = ctx.file.manifest)

    dump = ctx.actions.declare_file(ctx.label.name + ".json")
    args = ctx.actions.args()
    args.add(pubspec.dirname)
    args.add(manifest.dirname)
    args.add(dump)

    # SwiftPM sandboxes the manifest's evaluation itself, which cannot nest in
    # Bazel's sandbox: `--disable-sandbox` leaves it to Bazel's. The manifest
    # runs with its working directory in the package and gets `PWD` from
    # here, as under Xcode, started in the app's folder.
    run_xcode_tool(
        ctx,
        command = "\n".join([
            "set -eu",
            # The manifest is a program for this Mac, not for the app's SDK.
            "unset SDKROOT",
            'out="$PWD/$3"',
            'package="$PWD/$2"',
            'tmp="$(mktemp -d)"',
            'cd "$1"',
            'HOME="$tmp" xcrun swift package --disable-sandbox --package-path "$package" ' +
            '--scratch-path "$tmp/scratch" --manifest-cache none dump-package > "$out"',
        ]),
        arguments = [args],
        env = {e.split("=", 1)[0]: e.split("=", 1)[1] for e in environment},
        inputs = [pubspec, pbxproj, plist, manifest],
        outputs = [dump],
        mnemonic = "FlutterSwiftPMAppManifest",
        progress_message = "Evaluating %{label}'s Package.swift for the app",
    )

    header = ctx.actions.declare_file(defines_header_name(ctx.label.name))
    swift_params = ctx.actions.declare_file(ctx.label.name + ".swift.params")
    tools = portable_tools(ctx)
    tool_args = ctx.actions.args()
    tool_args.add(ctx.file._tool)
    tool_args.add("--dump", dump)
    tool_args.add("--reference", ctx.file.reference)
    tool_args.add("--target", ctx.attr.target)
    tool_args.add("--platform", platform)
    tool_args.add("--configuration", ctx.attr.configuration)
    tool_args.add("--package", ctx.attr.package)
    tool_args.add("--manifest", ctx.attr.manifest_path)
    tool_args.add("--header", header)
    tool_args.add("--swift-params", swift_params)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [tool_args],
        inputs = depset(
            direct = [ctx.file._tool, dump, ctx.file.reference],
            transitive = [tools.sdk_files.run],
        ),
        outputs = [header, swift_params],
        mnemonic = "FlutterSwiftPMAppSettings",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Reading the defines of %{label}",
    )

    return [
        DefaultInfo(files = depset([swift_params])),
        CcInfo(compilation_context = cc_common.create_compilation_context(
            headers = depset([header]),
            quote_includes = depset([header.dirname]),
        )),
        OutputGroupInfo(swiftpm_dump = depset([dump]), swiftpm_header = depset([header])),
    ]

flutter_swiftpm_app_settings = rule(
    implementation = _flutter_swiftpm_app_settings_impl,
    attrs = dict(
        XCODE_TOOL_ATTRS,
        manifest = attr.label(
            allow_single_file = ["Package.swift"],
            mandatory = True,
            doc = "The plugin's Package.swift.",
        ),
        manifest_path = attr.string(mandatory = True, doc = "The manifest's path in the plugin, for messages."),
        reference = attr.label(
            allow_single_file = [".json"],
            mandatory = True,
            doc = "The manifest's `dump-package` at fetch time, which the library's structure is built from.",
        ),
        package = attr.string(mandatory = True, doc = "The pub package, for messages."),
        target = attr.string(mandatory = True, doc = "The package target whose defines these are."),
        platform = attr.string(mandatory = True, values = ["ios", "macos"]),
        configuration = attr.string(
            mandatory = True,
            values = ["debug", "release"],
            doc = "The SwiftPM configuration: `release` under `-c opt`, as `swiftpm_release` selects.",
        ),
        _info_plist = attr.label(default = _INFO_PLIST, allow_single_file = True),
        _environment = attr.label(default = _ENVIRONMENT),
        _tool = attr.label(
            default = "//flutter/private/tools:swiftpm_app_settings.dart",
            allow_single_file = True,
        ),
    ),
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = XCODE_TOOL_FRAGMENTS,
    toolchains = XCODE_TOOL_TOOLCHAINS,
    doc = """The defines of one target of a plugin's Package.swift, for the app being built.

Its files are a response file for the target's Swift compile; its `CcInfo` is
a header for its C-family compiles, which they `-include` (`defines_header_name`).
See the module docstring.
""",
)
