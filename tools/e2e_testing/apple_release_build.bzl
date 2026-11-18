"""Builds Apple targets in a chosen compilation mode, as a test's `data`.

A test that reads a built bundle takes it as `data`, in whatever configuration
the test is run with. A property of a *release* bundle has to hold in each
compilation mode that builds Flutter's release mode (`fastbuild` and `opt`), so
it needs the bundle built in a mode it names, not the one the command line has.
"""

load("@rules_apple//apple:providers.bzl", "AppleBundleInfo", "AppleFrameworkImportInfo")

_OBFUSCATE = str(Label("//flutter:obfuscate"))
_SPLIT_DEBUG_INFO = str(Label("@rules_dart//dart:split_debug_info"))

def _transition_impl(settings, attr):
    ios_multi_cpus = settings["//command_line_option:ios_multi_cpus"]
    features = settings["//command_line_option:features"]
    return {
        _OBFUSCATE: attr.obfuscate,
        _SPLIT_DEBUG_INFO: attr.obfuscate,
        "//command_line_option:features": features if attr.sign else features + ["disable_legacy_signing"],
        "//command_line_option:apple_generate_dsym": attr.generate_dsym,
        "//command_line_option:compilation_mode": attr.compilation_mode,
        "//command_line_option:ios_multi_cpus": ["arm64"] if attr.ios_device else ios_multi_cpus,
    }

_transition = transition(
    implementation = _transition_impl,
    inputs = [
        "//command_line_option:features",
        "//command_line_option:ios_multi_cpus",
    ],
    outputs = [
        _OBFUSCATE,
        _SPLIT_DEBUG_INFO,
        "//command_line_option:features",
        "//command_line_option:apple_generate_dsym",
        "//command_line_option:compilation_mode",
        "//command_line_option:ios_multi_cpus",
    ],
)

def _impl(ctx):
    files = []
    for target in ctx.attr.targets:
        if ctx.attr.entitlements:
            # rules_flutter's app forwards the bundle's provider.
            entitlements = target[AppleBundleInfo].entitlements
            if not entitlements:
                fail("%s: %s is signed with no entitlements" % (ctx.label, target.label))
            files.append(depset([entitlements]))
            continue
        files.append(target[DefaultInfo].files)

        # A framework import has no files of its own: its frameworks are here.
        if AppleFrameworkImportInfo in target:
            files.append(target[AppleFrameworkImportInfo].framework_imports)
        if ctx.attr.generate_dsym and OutputGroupInfo in target and hasattr(target[OutputGroupInfo], "dsyms"):
            files.append(target[OutputGroupInfo].dsyms)
    return [DefaultInfo(
        files = depset(transitive = files),
        # A `bazel run` program among them (an export) runs from the test.
        runfiles = ctx.runfiles().merge_all([t[DefaultInfo].default_runfiles for t in ctx.attr.targets]),
    )]

apple_release_build = rule(
    implementation = _impl,
    doc = """Forwards the files and runfiles of `targets`, built in `compilation_mode`, and the
frameworks of the framework imports among them.

With `generate_dsym`, builds them with `--apple_generate_dsym` and forwards
the dSYM bundles the targets' `dsyms` output group holds besides their own
files. With `obfuscate`, builds them obfuscated. With `entitlements`, forwards
the entitlements each is signed with instead of its files.""",
    attrs = {
        "compilation_mode": attr.string(
            mandatory = True,
            values = ["dbg", "fastbuild", "opt"],
        ),
        "entitlements": attr.bool(
            default = False,
            doc = "Forward the entitlements each bundle is signed with, as " +
                  "rules_apple hands them to `codesign`, instead of its files.",
        ),
        "generate_dsym": attr.bool(
            default = False,
            doc = "Build with `--apple_generate_dsym` and forward the `dsyms` output group.",
        ),
        "obfuscate": attr.bool(
            default = False,
            doc = "Build with `--@rules_flutter//flutter:obfuscate` and the " +
                  "`--@rules_dart//dart:split_debug_info` it needs.",
        ),
        "sign": attr.bool(
            default = True,
            doc = "Sign the bundle. False builds it with `--features=disable_legacy_signing`, " +
                  "so no signing identity is needed.",
        ),
        "ios_device": attr.bool(
            default = False,
            doc = "Build for an arm64 iOS device (`--ios_multi_cpus=arm64`).",
        ),
        "targets": attr.label_list(
            cfg = _transition,
            mandatory = True,
        ),
    },
)
