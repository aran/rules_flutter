"""Rule that compiles a standalone Dart tool to a `.dill` kernel using the Flutter SDK toolchain.

Used for build tools (such as `web_template`) whose compiled `.dill` is executed
by `flutter_sdk_info.dart` (from `@rules_flutter//flutter:toolchain_type`) so the
compiled kernel's SDK hash always matches the Flutter-bundled Dart VM that loads
it, regardless of whether `@rules_dart`'s standalone SDK toolchain was registered
ahead of `@flutter_toolchains`.
"""

load(
    "@rules_dart//dart:utils.bzl",
    "STABLE_SCHEME",
    "dart_analyzable_info",
    "gen_kernel_args",
    "stable_entry_path",
)

def _sdk_root_from_dart(dart_file):
    p = dart_file.path
    for suffix in ("/bin/dart", "/bin/dart.exe"):
        if p.endswith(suffix):
            return p[:-len(suffix)]
    return p

def _find_flutter_sdk_gen_kernel_tools(flutter_sdk_info):
    sdk_root = _sdk_root_from_dart(flutter_sdk_info.dart)
    wanted = {
        "gen_kernel_snapshot": sdk_root + "/bin/snapshots/gen_kernel_aot.dart.snapshot",
        "platform_dill": sdk_root + "/lib/_internal/vm_platform_strong.dill",
    }
    found = {}
    compile_inputs = []
    for f in flutter_sdk_info.tool_files.to_list():
        if f.path.startswith(sdk_root + "/"):
            compile_inputs.append(f)
        for key, path in wanted.items():
            if f.path == path:
                found[key] = f
    if len(found) != len(wanted):
        fail(
            "Flutter toolchain is missing Dart SDK kernel compilation files under %s (expected %s, found %s)" %
            (sdk_root, sorted(wanted.values()), sorted([f.path for f in found.values()])),
        )
    return struct(
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        gen_kernel_snapshot = found["gen_kernel_snapshot"],
        platform_dill = found["platform_dill"],
        compile_inputs = compile_inputs,
    )

def _writable_home_env(dart, beside):
    if dart.basename.endswith(".exe"):
        return {"USERPROFILE": beside.dirname, "LOCALAPPDATA": beside.dirname}
    return {"HOME": "/tmp"}

def _flutter_sdk_kernel_binary_impl(ctx):
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    tools = _find_flutter_sdk_gen_kernel_tools(flutter_sdk_info)

    output = ctx.actions.declare_file(ctx.label.name + ".dill")
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = '{"configVersion": 2, "packages": []}\n',
    )

    args = gen_kernel_args(ctx, tools, tools.platform_dill, package_config)
    args.add("-Ddart.vm.product=false")
    args.add_all(["-Ddart.vm.asan=false", "-Ddart.vm.msan=false", "-Ddart.vm.tsan=false"])
    args.add("-o", output)
    args.add(STABLE_SCHEME + ":///" + stable_entry_path(ctx, ctx.file.main.path))

    ctx.actions.run(
        executable = tools.dartaotruntime,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file.main, package_config, tools.dartaotruntime, tools.gen_kernel_snapshot, tools.platform_dill] + tools.compile_inputs,
        ),
        outputs = [output],
        mnemonic = "FlutterToolKernel",
        progress_message = "Compiling Flutter tool kernel %s" % ctx.label,
        env = _writable_home_env(flutter_sdk_info.dart, output),
    )

    return [
        DefaultInfo(
            files = depset([output]),
            executable = output,
        ),
        dart_analyzable_info(
            deps = [],
            srcs = [ctx.file.main],
        ),
    ]

flutter_sdk_kernel_binary = rule(
    implementation = _flutter_sdk_kernel_binary_impl,
    attrs = {
        "main": attr.label(
            doc = "The standalone Dart entrypoint file.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
    },
    executable = True,
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
    doc = "Compiles a standalone Dart tool to a `.dill` kernel using `@rules_flutter//flutter:toolchain_type`.",
)
