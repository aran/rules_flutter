"""Shared fixtures and tests for the iOS and macOS bundling rules.

These tests care about how a rule lays its outputs out, not about what a real
Flutter build produces, so their applications are fakes: compiling a real one
per fixture would cost minutes and need a device SDK.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:providers.bzl", "FlutterApplePluginInfo", "FlutterApplicationInfo", "resolve_exec_dart_vm")

def _fake_application_impl(ctx):
    """Placeholder outputs, every one declared under this target's name.

    So fakes in one package never share an output — which is the very defect
    the tests over them are checking the real rules for.

    A path named in both `native_libs` and `code_assets` is one File: the shape
    of one library arriving by both routes.
    """
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)

    libs = {}
    for path in ctx.attr.native_libs + ctx.attr.code_assets:
        if path not in libs:
            lib = ctx.actions.declare_file("%s/%s" % (ctx.label.name, path))
            if ctx.attr.macho_aot:
                ctx.actions.run(
                    executable = dart_exe,
                    arguments = [
                        ctx.executable._macho_edit.path,
                        "stub",
                        "--output",
                        lib.path,
                        "--arch",
                        "arm64",
                        "--platform",
                        "ios",
                        "--min-os",
                        "13.0",
                        "--install-name",
                        "@rpath/libplaceholder.dylib",
                    ],
                    inputs = depset(
                        direct = [ctx.executable._macho_edit],
                        transitive = [dart_vm_files],
                    ),
                    outputs = [lib],
                )
            else:
                ctx.actions.write(lib, "%s %s" % (ctx.label, path))
            libs[path] = lib

    # Debug carries a kernel and no AOT dylib; release the reverse. When
    # `macho_aot = True`, the release fixture synthesizes a valid 64-bit Mach-O
    # dylib via `macho_edit.dart stub` so `FlutterIOSRetagDylib` can parse and
    # re-tag it in a real `build_test`.
    if ctx.attr.debug:
        aot_output = None
        kernel_dill = ctx.actions.declare_file(ctx.label.name + "/app.dill")
        ctx.actions.write(kernel_dill, str(ctx.label))
    else:
        kernel_dill = None
        aot_output = ctx.actions.declare_file(ctx.label.name + "/app.so")
        if ctx.attr.macho_aot:
            ctx.actions.run(
                executable = dart_exe,
                arguments = [
                    ctx.executable._macho_edit.path,
                    "stub",
                    "--output",
                    aot_output.path,
                    "--arch",
                    "arm64",
                    "--platform",
                    "macos",
                    "--min-os",
                    "13.0",
                    "--install-name",
                    "@rpath/App.framework/App",
                ],
                inputs = depset(
                    direct = [ctx.executable._macho_edit],
                    transitive = [dart_vm_files],
                ),
                outputs = [aot_output],
            )
        else:
            ctx.actions.write(aot_output, str(ctx.label))

    asset_manifest = ctx.actions.declare_file(ctx.label.name + "/_staging/AssetManifest.bin")
    ctx.actions.write(asset_manifest, "")
    flutter_assets = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")
    ctx.actions.run(
        executable = dart_exe,
        arguments = [
            ctx.executable._macho_edit.path,
            "copy-files",
            "--output-dir",
            flutter_assets.path,
            asset_manifest.path,
        ],
        inputs = depset(
            direct = [asset_manifest, ctx.executable._macho_edit],
            transitive = [dart_vm_files],
        ),
        outputs = [flutter_assets],
    )

    plugins = []
    apple_plugin_libs = []
    if ctx.attr.plugin_name and ctx.attr.plugin_class:
        plugins.append(struct(
            name = ctx.attr.plugin_name,
            platforms = {
                "ios": {"pluginClass": ctx.attr.plugin_class},
                "macos": {"pluginClass": ctx.attr.plugin_class},
            },
        ))
    for lib in ctx.attr.apple_libs:
        if FlutterApplePluginInfo not in lib:
            fail("fake_application: apple_libs entry %s must provide FlutterApplePluginInfo" % lib.label)
        platform_name = lib[FlutterApplePluginInfo].platform
        apple_plugin_libs.append(struct(
            platform = platform_name,
            label = lib.label,
            cc_info = lib[CcInfo] if CcInfo in lib else None,
            swift_info = lib[SwiftInfo] if SwiftInfo in lib else None,
            files = lib[DefaultInfo].files,
            package = ctx.attr.plugin_name or lib.label.name,
        ))

    return [FlutterApplicationInfo(
        aot_output = aot_output,
        kernel_dill = kernel_dill,
        is_debug = ctx.attr.debug,
        flutter_assets = flutter_assets,
        native_libs = [libs[path] for path in ctx.attr.native_libs],
        bundled_code_assets = depset([libs[path] for path in ctx.attr.code_assets]),
        apple_privacy_manifests = depset(),
        plugins = plugins,
        apple_plugin_libraries = depset(apple_plugin_libs),
    )]

fake_application = rule(
    implementation = _fake_application_impl,
    attrs = {
        "apple_libs": attr.label_list(),
        "code_assets": attr.string_list(),
        "debug": attr.bool(default = False),
        "macho_aot": attr.bool(default = False),
        "native_libs": attr.string_list(),
        "plugin_class": attr.string(default = ""),
        "plugin_name": attr.string(default = ""),
        "_macho_edit": attr.label(
            default = Label("//flutter/private/tools:macho_edit"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = "A fake FlutterApplicationInfo for tests over Apple bundling rules.",
)

def _outputs_under_target_dir_test_impl(ctx):
    """Every output this rule declares sits under a directory named after it.

    The invariant both Apple framework rules exist under: two apps in one
    package are two targets, and Bazel gives a declared file the package's path
    plus whatever name the rule asks for, with nothing of the target's own in
    between. A rule that hardcodes its layout therefore has both targets
    writing one path, which fails the build with conflicting actions as soon as
    the two apps differ enough for their actions to differ. A pair built from
    the *same* application hides it, because Bazel shares identical actions.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    own = "/".join([p for p in [target.label.package, target.label.name] if p])

    outputs = target[DefaultInfo].files.to_list()
    asserts.true(env, len(outputs) > 0, "the rule declared no outputs to check")
    for f in outputs:
        asserts.true(
            env,
            f.short_path == own or f.short_path.startswith(own + "/"),
            "%s is not the directory %s nor under it, so a second app in the " % (f.short_path, own) +
            "package would declare it too",
        )
    return analysistest.end(env)

outputs_under_target_dir_test = analysistest.make(
    _outputs_under_target_dir_test_impl,
)

def _fake_macho_binary_impl(ctx):
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.run(
        executable = dart_exe,
        arguments = [
            ctx.executable._macho_edit.path,
            "stub",
            "--type",
            "execute",
            "--output",
            out.path,
            "--arch",
            ctx.attr.arch,
            "--platform",
            ctx.attr.platform,
            "--min-os",
            "14.0",
        ],
        inputs = depset(
            direct = [ctx.executable._macho_edit],
            transitive = [dart_vm_files],
        ),
        outputs = [out],
    )
    return [DefaultInfo(files = depset([out]), executable = out)]

fake_macho_binary = rule(
    implementation = _fake_macho_binary_impl,
    attrs = {
        "arch": attr.string(default = "arm64"),
        "platform": attr.string(default = "ios"),
        "_macho_edit": attr.label(
            default = Label("//flutter/private/tools:macho_edit"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    executable = True,
)

_FAKE_FRAMEWORK_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>{name}</string>
    <key>CFBundleIdentifier</key>
    <string>io.flutter.{name}</string>
    <key>CFBundleName</key>
    <string>{name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
</dict>
</plist>
"""

def _fake_xcframework_impl(ctx):
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    fw_name = ctx.attr.framework_name
    slice_name = "macos-arm64_x86_64" if ctx.attr.platform == "macos" else "ios-arm64"
    prefix = "%s/%s.xcframework/%s/%s.framework" % (ctx.label.name, fw_name, slice_name, fw_name)
    binary = ctx.actions.declare_file("%s/%s" % (prefix, fw_name))
    plist = ctx.actions.declare_file("%s/Info.plist" % prefix)
    header = ctx.actions.declare_file("%s/Headers/%s.h" % (prefix, fw_name))

    ctx.actions.run(
        executable = dart_exe,
        arguments = [
            ctx.executable._macho_edit.path,
            "stub",
            "--output",
            binary.path,
            "--arch",
            ctx.attr.arch,
            "--platform",
            ctx.attr.platform,
            "--min-os",
            "14.0",
            "--install-name",
            "@rpath/%s.framework/%s" % (fw_name, fw_name),
        ],
        inputs = depset(
            direct = [ctx.executable._macho_edit],
            transitive = [dart_vm_files],
        ),
        outputs = [binary],
    )
    ctx.actions.write(plist, _FAKE_FRAMEWORK_PLIST.format(name = fw_name))
    ctx.actions.write(header, "// Synthetic %s framework header\n" % fw_name)
    return [DefaultInfo(files = depset([binary, plist, header]))]

fake_xcframework = rule(
    implementation = _fake_xcframework_impl,
    attrs = {
        "arch": attr.string(default = "arm64"),
        "framework_name": attr.string(default = "Flutter"),
        "platform": attr.string(default = "ios"),
        "_macho_edit": attr.label(
            default = Label("//flutter/private/tools:macho_edit"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
)
