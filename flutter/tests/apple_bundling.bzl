"""Shared fixtures and tests for the iOS and macOS bundling rules.

These tests care about how a rule lays its outputs out, not about what a real
Flutter build produces, so their applications are fakes: compiling a real one
per fixture would cost minutes and need a device SDK.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

# buildifier: disable=bzl-visibility
load("@rules_apple//apple/internal:providers.bzl", "AppleBundleInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:providers.bzl", "FlutterApplePluginInfo", "FlutterApplicationInfo", "resolve_exec_dart_vm")

def _write_fake_macho(ctx, dart_exe, dart_vm_files, out_file, install_name):
    if ctx.attr.fat_macho:
        arm_slice = ctx.actions.declare_file(out_file.short_path + ".arm64")
        x86_slice = ctx.actions.declare_file(out_file.short_path + ".x86_64")
        for arch, slice_file in [("arm64", arm_slice), ("x86_64", x86_slice)]:
            ctx.actions.run(
                executable = dart_exe,
                arguments = [
                    ctx.executable._macho_edit.path,
                    "stub",
                    "--output",
                    slice_file.path,
                    "--arch",
                    arch,
                    "--platform",
                    "macos",
                    "--min-os",
                    "11.0",
                    "--install-name",
                    install_name,
                ],
                inputs = depset(
                    direct = [ctx.executable._macho_edit],
                    transitive = [dart_vm_files],
                ),
                outputs = [slice_file],
            )
        ctx.actions.run(
            executable = dart_exe,
            arguments = [
                ctx.executable._macho_edit.path,
                "fat",
                "--output",
                out_file.path,
                x86_slice.path,
                arm_slice.path,
            ],
            inputs = depset(
                direct = [x86_slice, arm_slice, ctx.executable._macho_edit],
                transitive = [dart_vm_files],
            ),
            outputs = [out_file],
        )
    else:
        ctx.actions.run(
            executable = dart_exe,
            arguments = [
                ctx.executable._macho_edit.path,
                "stub",
                "--output",
                out_file.path,
                "--arch",
                "arm64",
                "--platform",
                "macos",
                "--min-os",
                "13.0",
                "--install-name",
                install_name,
            ],
            inputs = depset(
                direct = [ctx.executable._macho_edit],
                transitive = [dart_vm_files],
            ),
            outputs = [out_file],
        )

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
                _write_fake_macho(
                    ctx,
                    dart_exe,
                    dart_vm_files,
                    lib,
                    "@rpath/%s/%s" % (ctx.label.name, path),
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
            _write_fake_macho(
                ctx,
                dart_exe,
                dart_vm_files,
                aot_output,
                "@rpath/%s/App.framework/App" % ctx.label.name,
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
    for plugin_name in sorted(ctx.attr.extra_plugins.keys()):
        plugins.append(struct(
            name = plugin_name,
            platforms = {
                "ios": {"pluginClass": ctx.attr.extra_plugins[plugin_name]},
                "macos": {"pluginClass": ctx.attr.extra_plugins[plugin_name]},
            },
        ))
    for lib in ctx.attr.apple_libs + ctx.attr.apple_plugin_libraries:
        if FlutterApplePluginInfo not in lib:
            fail("fake_application: apple_libs entry %s must provide FlutterApplePluginInfo" % lib.label)
        platform_name = lib[FlutterApplePluginInfo].platform
        apple_plugin_libs.append(struct(
            platform = platform_name,
            label = lib.label,
            cc_info = lib[CcInfo] if CcInfo in lib else None,
            swift_info = lib[SwiftInfo] if SwiftInfo in lib else None,
            files = lib[DefaultInfo].files,
            sdk_frameworks = tuple(lib[FlutterApplePluginInfo].sdk_frameworks),
            sdk_dylibs = tuple(lib[FlutterApplePluginInfo].sdk_dylibs),
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
        "apple_plugin_libraries": attr.label_list(),
        "code_assets": attr.string_list(),
        "debug": attr.bool(default = False),
        "fat_macho": attr.bool(default = False),
        "macho_aot": attr.bool(default = True),
        "native_libs": attr.string_list(),
        "plugin_class": attr.string(default = ""),
        "plugin_name": attr.string(default = ""),
        "extra_plugins": attr.string_dict(
            default = {},
            doc = "Additional native plugins as {module name: plugin class}, exposed on ios and macos like plugin_name/plugin_class.",
        ),
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
    if ctx.attr.platform == "macos":
        binary = ctx.actions.declare_file("%s/Versions/A/%s" % (prefix, fw_name))
        plist = ctx.actions.declare_file("%s/Versions/A/Resources/Info.plist" % prefix)
        header = ctx.actions.declare_file("%s/Versions/A/Headers/%s.h" % (prefix, fw_name))
        install_name = "@rpath/%s.framework/Versions/A/%s" % (fw_name, fw_name)
    else:
        binary = ctx.actions.declare_file("%s/%s" % (prefix, fw_name))
        plist = ctx.actions.declare_file("%s/Info.plist" % prefix)
        header = ctx.actions.declare_file("%s/Headers/%s.h" % (prefix, fw_name))
        install_name = "@rpath/%s.framework/%s" % (fw_name, fw_name)

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
            install_name,
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

def _macho_verify_probe_impl(ctx):
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    files = ctx.attr.target[DefaultInfo].files.to_list()
    if not files:
        fail("%s: target %s produced no files" % (ctx.label, ctx.attr.target.label))

    relpath = ctx.attr.binary_relpath
    input_file = None
    use_relpath = False
    if len(files) == 1 and (files[0].is_directory or files[0].extension in ["ipa", "zip"]):
        input_file = files[0]
        use_relpath = bool(relpath)
    elif relpath:
        for f in files:
            if f.short_path.endswith("/" + relpath) or f.basename == relpath:
                input_file = f
                break
        if not input_file:
            fail("%s: no file matching %r in %s" % (ctx.label, relpath, [f.short_path for f in files]))
    else:
        input_file = files[0]

    stamp = ctx.actions.declare_file(ctx.label.name + ".verified")
    args = [
        ctx.executable._macho_edit.path,
        "verify",
        "--input",
        input_file.path,
        "--objdump",
        ctx.executable._objdump.path,
        "--output",
        stamp.path,
    ]
    if use_relpath:
        args.extend(["--binary-relpath", relpath])
    direct_inputs = [input_file, ctx.executable._macho_edit, ctx.executable._objdump]
    if AppleBundleInfo in ctx.attr.target and ctx.attr.target[AppleBundleInfo].archive:
        fw_zip = ctx.attr.target[AppleBundleInfo].archive
        args.extend(["--framework-zip", fw_zip.path])
        direct_inputs.append(fw_zip)
    for substr in ctx.attr.expected_substrings:
        args.extend(["--expect", substr])
    for entry in ctx.attr.expected_entries:
        args.extend(["--expect-entry", entry])
    for entry in ctx.attr.forbidden_entries:
        args.extend(["--forbid-entry", entry])

    ctx.actions.run(
        executable = dart_exe,
        arguments = args,
        inputs = depset(
            direct = direct_inputs,
            transitive = [dart_vm_files],
        ),
        outputs = [stamp],
        mnemonic = "FlutterMachOVerifyProbe",
        progress_message = "Verifying Mach-O binary for %s with llvm-objdump" % ctx.label,
    )
    return [DefaultInfo(files = depset([stamp]))]

macho_verify_probe = rule(
    implementation = _macho_verify_probe_impl,
    attrs = {
        "binary_relpath": attr.string(default = ""),
        "expected_entries": attr.string_list(default = []),
        "expected_substrings": attr.string_list(default = []),
        "forbidden_entries": attr.string_list(default = []),
        "target": attr.label(mandatory = True),
        "_macho_edit": attr.label(
            default = Label("//flutter/private/tools:macho_edit"),
            executable = True,
            cfg = "exec",
        ),
        "_objdump": attr.label(
            default = Label("@llvm//tools:llvm-objdump"),
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = "Verifies a built Mach-O binary, framework, or archive using @llvm//tools:llvm-objdump.",
)
