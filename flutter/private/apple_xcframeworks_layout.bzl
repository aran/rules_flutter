"""The layout of `flutter build ios-framework` and `macos-framework`, and its export.

`flutter_apple_xcframeworks_layout` puts the xcframeworks of one build mode,
the configuration's, under `<Mode>/` (`Debug`, `Profile`, `Release`), and the
files upstream writes above the modes beside it. `bazel run` of it writes that
to `build/<platform>/framework/` in the target's package, as the upstream
command does, replacing that mode's directory; a run per mode fills all three.
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:utils.bzl", "runfiles_path")
load("//flutter/private:apple_add_to_app.bzl", "BUNDLE_ATTRS", "assemble_bundle")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//flutter/private:flutter_native_assets.bzl", "CODE_ASSETS_TOOL_ATTRS", "run_code_assets_tool")

visibility("//flutter/...")

FlutterXCFrameworksLayoutInfo = provider(
    doc = "An add-to-app layout of one build mode, as `flutter build <platform>-framework` writes it.",
    fields = {
        "tree": "File: the directory, `<Mode>/` with the xcframeworks and the files above it.",
        "platform": "str: `ios` or `macos`.",
        "mode": "str: `Debug`, `Profile` or `Release`.",
    },
)

# What a rule whose target `bazel run` exports needs.
EXPORT_ATTRS = {
    "_export_tool": attr.label(
        default = "//flutter/private/tools:apple_xcframeworks_export",
        executable = True,
        cfg = "target",
    ),
}

def build_mode_directory(ctx):
    """`Debug`, `Profile` or `Release`: the mode of the configuration, as upstream names it.

    Args:
        ctx: A rule context with a `_profile` attribute (`//flutter:profile`).

    Returns:
        The directory name.
    """
    if ctx.var["COMPILATION_MODE"] == "dbg":
        return "Debug"
    if ctx.attr._profile[BuildSettingInfo].value:
        return "Profile"
    return "Release"

# Upstream's per-mode `FlutterPluginRegistrant` package, its plugins and
# frameworks binary targets.
_PACKAGE_SWIFT = """// swift-tools-version: 5.9
// {mode}
//
//  Generated file. Do not edit.
//
import PackageDescription

let package = Package(
    name: "FlutterPluginRegistrant",
    platforms: [
        {platform}("{minimum_os_version}"),
    ],
    products: [
        .library(name: "FlutterPluginRegistrant", type: .static, targets: ["FlutterPluginRegistrant"]),
    ],
    targets: [
        .target(name: "FlutterPluginRegistrant", dependencies: [@DEPENDENCIES@]),
@BINARY_TARGETS@    ]
)
"""

def _layout_impl(ctx):
    mode = build_mode_directory(ctx)
    steps = []
    seen = {}

    def place(name, step):
        if name in seen:
            fail("%s: two inputs are both %s" % (ctx.label, name))
        seen[name] = True
        steps.append(step)

    # Directories of xcframeworks whose names are known only once built: the
    # code assets that ship (`flutter_*_code_asset_xcframeworks`).
    xcframework_dirs = []
    for target in ctx.attr.xcframeworks:
        for f in target[DefaultInfo].files.to_list():
            if f.basename.endswith(".xcframework"):
                place(f.basename, ("bundle", "%s/%s" % (mode, f.basename), f))
            elif f.is_directory:
                steps.append(("bundle", mode, f))
                xcframework_dirs.append(f)
            elif f.extension in ("h", "m", "swift"):
                # The registrant's sources, above the modes as upstream's.
                place(f.basename, ("file", f.basename, f))
    for target, name in ctx.attr.renamed_files.items():
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("%s: `renamed_files` takes targets of one file, and %s has %d" % (ctx.label, target.label, len(files)))
        place(name, ("file", name, files[0]))
    if mode == "Debug":
        for f in ctx.files.debug_files:
            place(f.basename, ("file", f.basename, f))

    # The Swift package beside the xcframeworks, as `flutter build
    # swift-package` writes one per mode: a library of the Swift registrant
    # over every xcframework as a binary target.
    if ctx.file.swift_package_registrant:
        binaries = sorted([
            name[:-len(".xcframework")]
            for name in seen
            if name.endswith(".xcframework") and name != "FlutterPluginRegistrant.xcframework"
        ])
        template = ctx.actions.declare_file(ctx.label.name + "_package/Package.swift.in")
        ctx.actions.write(template, _PACKAGE_SWIFT.format(
            mode = mode,
            platform = {"ios": ".iOS", "macos": ".macOS"}[ctx.attr.platform],
            minimum_os_version = ctx.attr.minimum_os_version,
        ))
        manifest = ctx.actions.declare_file(ctx.label.name + "_package/Package.swift")
        args = ctx.actions.args()
        args.add("--template", template)
        args.add("--output", manifest)
        args.add_all(binaries, before_each = "--binary")
        args.add_all(xcframework_dirs, expand_directories = False, before_each = "--binaries-in")
        run_code_assets_tool(
            ctx,
            "package-swift",
            [args],
            depset([template] + xcframework_dirs),
            [manifest],
            mnemonic = "FlutterSwiftPackageManifest",
            progress_message = "Writing the Swift package of %{label}",
        )
        place("Package.swift", ("file", mode + "/Package.swift", manifest))
        place("Sources", ("file", mode + "/Sources/FlutterPluginRegistrant/GeneratedPluginRegistrant.swift", ctx.file.swift_package_registrant))

    tree = ctx.actions.declare_directory(ctx.label.name)
    assemble_bundle(
        ctx,
        tree,
        steps,
        mnemonic = "FlutterXCFrameworksLayout",
        progress_message = "Laying out the %s xcframeworks of %%{label}" % mode,
    )

    return export_providers(ctx, tree, ctx.attr.platform, mode)

def export_providers(ctx, tree, platform, mode):
    """The providers of a layout `tree`: its files, and `bazel run` of it.

    Args:
        ctx: A rule context with `EXPORT_ATTRS`.
        tree: The layout, `<Mode>/` and the files above it.
        platform: `ios` or `macos`.
        mode: `Debug`, `Profile` or `Release`.

    Returns:
        A list of providers.
    """
    workspace = ctx.workspace_name
    config = ctx.actions.declare_file(ctx.label.name + ".xcframeworks_export.json")
    ctx.actions.write(config, json.encode_indent({
        "mode": mode,
        "package": ctx.label.package,
        "platform": platform,
        "tree": runfiles_path(tree, workspace),
    }))
    tool = ctx.attr._export_tool
    executable = ctx.actions.declare_file(ctx.label.name + ".export")
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [config, tree, executable]).merge(tool[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(files = depset([tree]), executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(environment = {
            "RULES_FLUTTER_XCFRAMEWORKS_CONFIG": runfiles_path(config, workspace),
        }),
        FlutterXCFrameworksLayoutInfo(tree = tree, platform = platform, mode = mode),
    ]

flutter_apple_xcframeworks_layout = rule(
    implementation = _layout_impl,
    executable = True,
    attrs = dicts.add(BUNDLE_ATTRS, {
        "platform": attr.string(
            doc = "`ios` or `macos`: where `bazel run` writes, `build/<platform>/framework`.",
            mandatory = True,
            values = ["ios", "macos"],
        ),
        "xcframeworks": attr.label_list(
            doc = "Targets whose `.xcframework` directories go under `<Mode>/`, as do the " +
                  "xcframeworks in their other directories, and whose `.h`, `.m` and " +
                  "`.swift` files go above it.",
            allow_files = True,
        ),
        "renamed_files": attr.label_keyed_string_dict(
            doc = "Single files placed above `<Mode>/` under the name given.",
            allow_files = True,
        ),
        "debug_files": attr.label_list(
            doc = "Files placed above `<Mode>/` when the mode is debug.",
            allow_files = True,
        ),
        "swift_package_registrant": attr.label(
            doc = "The Swift registrant of the Swift package `<Mode>/` is too " +
                  "(`flutter_apple_swift_package_registrant`); none, no package.",
            allow_single_file = [".swift"],
        ),
        "minimum_os_version": attr.string(
            doc = "The minimum OS version of the Swift package.",
        ),
        "_profile": attr.label(default = "//flutter:profile"),
    }, EXPORT_ATTRS, CODE_ASSETS_TOOL_ATTRS),
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = """Lays out the xcframeworks of one build mode as `flutter build ios-framework` and
`macos-framework` do: `<Mode>/` (the configuration's), and the files upstream writes
beside the modes. `bazel run` writes it to `build/<platform>/framework/` in the
package (`-- --output=<dir>` elsewhere), replacing that mode's directory.""",
)
