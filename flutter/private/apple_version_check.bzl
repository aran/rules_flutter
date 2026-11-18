"""Fails the build of an Apple app whose bundle version is not its program's.

rules_apple replaces `CFBundleShortVersionString` and `CFBundleVersion` with
the values of the app's `version` target, so a literal in the plist that
differs from them would be dropped without a word. And the program reports the
`flutter_application`'s version as `appBuildName` and `appBuildNumber`, so a
`version` target that gives the bundle other values would ship two versions.
The values of a rules_apple `apple_bundle_version` may come from
`--embed_label`, known only when it runs, so both are checked then.

This rule runs `check_apple_version_keys.dart` over the plist and the version
file as a validation action, so building the app fails with the key, the
values and what to set instead. The macros put it in the bundle's `deps`, where
the application it reads is in the configuration the bundle builds it in: a
check outside the bundle's transition would analyse and build the application,
native code and all, a second time.
"""

load("@rules_apple//apple:providers.bzl", "AppleBundleVersionInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter:providers.bzl", "FlutterApplicationInputsInfo")
load("//flutter/private:app_version.bzl", "apple_version")
load("//flutter/private:application_version.bzl", "shown_label", "version_names")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")

def _impl(ctx):
    tools = portable_tools(ctx)
    stamp = ctx.actions.declare_file(ctx.label.name + ".checked")

    args = ctx.actions.args()
    args.add(ctx.file._tool)
    args.add("--plist", ctx.file.plist)
    args.add("--name", ctx.attr.plist_name or ctx.file.plist.short_path)
    version_file = ctx.attr.version[AppleBundleVersionInfo].version_file
    args.add("--version-file", version_file)
    args.add("--app", shown_label(ctx.attr.app_label))

    # What the program reports, as the bundle's keys would carry it.
    program = ctx.attr.application[FlutterApplicationInputsInfo].inputs
    expected = apple_version(program.build_name, program.build_number, version_names(program.version_settings))
    if expected.error:
        fail("%s: the application %s: %s" % (ctx.label, shown_label(ctx.attr.application.label), expected.error))
    args.add("--application", shown_label(ctx.attr.application.label))
    args.add("--short-version-string", expected.short_version_string)
    args.add("--build-version", expected.build_version)
    for attribute, option in [("build_name", "--short-version-string-setting"), ("build_number", "--build-version-setting")]:
        if attribute in program.version_settings:
            args.add(option, program.version_settings[attribute])
    args.add("--version-target", shown_label(ctx.attr.version.label))
    args.add("--rule", ctx.attr.rule_name)
    args.add("--stamp", stamp)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file._tool, ctx.file._merge_plists, ctx.file._plist_binary, ctx.file.plist, version_file],
            transitive = [tools.sdk_files.run],
        ),
        outputs = [stamp],
        mnemonic = "FlutterCheckAppleVersion",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Checking the version keys of %s" % ctx.label,
    )
    return [
        DefaultInfo(files = depset([stamp])),
        OutputGroupInfo(_validation = depset([stamp])),
    ]

flutter_apple_version_check = rule(
    implementation = _impl,
    attrs = {
        "plist": attr.label(
            doc = "The Info.plist, XML or binary.",
            allow_single_file = True,
            mandatory = True,
        ),
        "plist_name": attr.string(
            doc = "The plist as the user knows it, for the message. " +
                  "Defaults to the file's path.",
        ),
        "version": attr.label(
            doc = "The app's version, whose values rules_apple puts in the " +
                  "plist's version keys.",
            providers = [AppleBundleVersionInfo],
            mandatory = True,
        ),
        "application": attr.label(
            doc = "The `flutter_application` the app is built over, whose " +
                  "version the bundle's must be.",
            providers = [FlutterApplicationInputsInfo],
            mandatory = True,
        ),
        "app_label": attr.string(
            doc = "The label of the app, for the message.",
            mandatory = True,
        ),
        "rule_name": attr.string(
            doc = "The macro that declares the app, for the message.",
            mandatory = True,
        ),
        "_tool": attr.label(
            default = "//flutter/private/tools:check_apple_version_keys.dart",
            allow_single_file = True,
        ),
        "_merge_plists": attr.label(
            default = "//flutter/private/tools:merge_plists.dart",
            allow_single_file = True,
        ),
        "_plist_binary": attr.label(
            default = "//flutter/private/tools:plist_binary.dart",
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Validates that an Apple app's bundle version is its application's, and that its Info.plist leaves the version keys to it.",
)
