"""Signing the add-to-app xcframeworks, as a layer over their unsigned build.

`flutter build ios-framework` and `macos-framework` sign every xcframework
they make with the developer's identity (and leave Flutter's own engine
xcframework with Flutter's signature). Here the xcframeworks are built
unsigned, as rules_apple's `apple_xcframework` builds them, so the build is
the same on every machine and is cached; `flutter_apple_xcframeworks_codesign`
wraps that build and signs it in an action of its own, as rules_apple signs a
bundle: on this machine (`no-remote`), outside the sandbox (`no-sandbox`) so
`codesign` reaches the keychain, and only after the identity is found in it.
A change of identity re-runs only the signing.
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("//flutter/private:apple_xcframeworks_layout.bzl", "EXPORT_ATTRS", "FlutterXCFrameworksLayoutInfo", "export_providers")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")

visibility("//flutter/...")

def _codesign_impl(ctx):
    layout = ctx.attr.xcframeworks[FlutterXCFrameworksLayoutInfo]
    if not ctx.attr.identity:
        fail("%s: `identity` is empty; name a code-signing identity, or `-` to sign ad hoc" % ctx.label)
    tools = portable_tools(ctx)
    tree = ctx.actions.declare_directory(ctx.label.name)
    args = ctx.actions.args()
    args.add(ctx.file._tool)
    args.add_all("--input", [layout.tree], expand_directories = False)
    args.add_all("--output", [tree], expand_directories = False)
    args.add("--identity", ctx.attr.identity)
    args.add("--mode", layout.mode)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file._tool, layout.tree] + ctx.files._tool_imports,
            transitive = [tools.sdk_files.run],
        ),
        outputs = [tree],
        mnemonic = "FlutterXCFrameworksCodesign",
        exec_group = PORTABLE,
        execution_requirements = {
            # `codesign` and `security` reach the keychain, which a sandbox
            # keeps from them, and only this Mac has it.
            "no-remote": "1",
            "no-sandbox": "1",
            "requires-darwin": "",
        },
        progress_message = "Signing the %s xcframeworks of %%{label}" % layout.mode,
    )
    return export_providers(ctx, tree, layout.platform, layout.mode)

flutter_apple_xcframeworks_codesign = rule(
    implementation = _codesign_impl,
    executable = True,
    attrs = dicts.add(EXPORT_ATTRS, {
        "xcframeworks": attr.label(
            doc = "The unsigned layout to sign: a `flutter_ios_xcframeworks` or `flutter_macos_xcframeworks`.",
            mandatory = True,
            providers = [FlutterXCFrameworksLayoutInfo],
        ),
        "identity": attr.string(
            doc = "The code-signing identity, as `codesign --sign` and `flutter build ios-framework " +
                  "--codesign-identity` take it (a certificate's name, such as " +
                  "`Apple Development: Jane Doe (TEAMID1234)`, or its SHA-1), or `-` to sign ad hoc.",
            mandatory = True,
        ),
        "_tool": attr.label(
            default = "//flutter/private/tools:apple_xcframeworks_codesign.dart",
            allow_single_file = True,
        ),
        "_tool_imports": attr.label_list(
            default = [
                "//flutter/private/tools:apple_frameworks.dart",
                "//flutter/private/tools:assemble_directory.dart",
            ],
            allow_files = True,
        ),
    }),
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = """Signs the xcframeworks of an add-to-app build with `identity`, as `flutter build
ios-framework` and `macos-framework` sign theirs: each xcframework with `codesign --force
--sign`, `--timestamp=none` but in release, and an xcframework already signed (Flutter's
engine, a prebuilt one a plugin links) left with its signature. Built and run as the layout it wraps: `bazel run` writes the signed
xcframeworks to `build/<platform>/framework/`.""",
)
