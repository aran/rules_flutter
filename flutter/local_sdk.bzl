"""Adapters that hand a Flutter checkout and its engine out dirs to rules_flutter.

The engine is built outside Bazel (`et`, or `tools/gn` and ninja, in the
developer's checkout), and these repository rules point at it, like a precompiled
`protoc`: `flutter_local_engine` is an engine source (the contract of
`@rules_flutter//flutter:engine.bzl`) over the out dirs of an engine source
directory, and `flutter_local_framework` is a framework source over a checkout's
packages.

The paths are machine-local, so they never appear in MODULE.bazel. The
committed MODULE.bazel declares the SDK without a path; the paths and the choice
to use the SDK live in the untracked `.bazelrc.user`. `FLUTTER_CHECKOUT` is the
flutter/flutter checkout, and `FLUTTER_ENGINE` is the engine's source directory,
as flutter_tools reads it (the default of `--local-engine-src-path`), usually
`<checkout>/engine/src`:

```
common --repo_env=FLUTTER_CHECKOUT=/Users/me/src/flutter
common --repo_env=FLUTTER_ENGINE=/Users/me/src/flutter/engine/src
common --@rules_flutter//flutter:sdk=local
```

MODULE.bazel:

```starlark
local_framework = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_local_framework")
local_engine = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_local_engine")
local_framework(name = "flutter_local_framework")
local_engine(name = "flutter_local_engine")

flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(name = "local", framework = "@flutter_local_framework", engine = "@flutter_local_engine")
```

Nothing is read until a build selects the SDK. Where a variable is not set the
repositories still load, with targets that fail when something uses them, so
`bazel query` works on a machine without a checkout.

When the out dirs of a slot are ambiguous (both `host_debug_arm64` and
`host_debug_unopt_arm64`), pin one with `--repo_env=FLUTTER_LOCAL_ENGINES=host_debug_unopt_arm64,host_release_arm64`.
"""

load("@rules_dart//dart:repositories.bzl", "fetch_dart_kernel_source")
load("//flutter/private:engine_labels.bzl", "contract_slices", "native_target")
load("//flutter/private:engine_out_dirs.bzl", "dict_text", "effective_cpu", "first_existing", "link_files_into", "link_into", "machine_of", "out_dir_provenance", "parse_args_gn", "parse_out_dir_name", "select_out_dir")
load("//flutter/private:framework_source.bzl", "FRAMEWORK_JSON")
load("//flutter/private:out_dir_desktop.bzl", "desktop_slices")
load("//flutter/private:out_dir_mobile.bzl", "mobile_slices")
load("//flutter/private:out_dir_web.bzl", "web_slices")

_ENGINE_LOAD = 'load("@rules_flutter//flutter:engine.bzl", "flutter_android_engine_slice", "flutter_gen_snapshot", "flutter_host_tools", "flutter_ios_engine_slice", "flutter_linux_engine_slice", "flutter_macos_engine_slice", "flutter_missing_slice", "flutter_platform_kernel", "flutter_web_sdk", "flutter_windows_engine_slice")\n'

def _unset_message(env, what, example):
    return (
        "{env} is not set. Point it at {what}, and select the SDK, in .bazelrc.user:\n" +
        "    common --repo_env={env}={example}\n" +
        "    common --@rules_flutter//flutter:sdk=<the SDK's name>"
    ).format(env = env, what = what, example = example)

def _source_path(repository_ctx, env, label):
    """A directory's path: the directory of the file `label` names, or the environment variable's value."""
    if label:
        return str(repository_ctx.path(label).dirname)
    return repository_ctx.getenv(env)

def _local_framework_impl(repository_ctx):
    env = repository_ctx.attr.path_env
    repository_ctx.file("BUILD.bazel", 'exports_files(["%s"], visibility = ["//visibility:public"])\n' % FRAMEWORK_JSON)
    checkout = _source_path(repository_ctx, env, repository_ctx.attr.checkout)
    if not checkout:
        unset = _unset_message(env, "a flutter/flutter checkout", "/path/to/flutter")
        repository_ctx.file(FRAMEWORK_JSON, json.encode({"unset": unset}) + "\n")
        return
    root = repository_ctx.path(checkout)
    if not root.get_child("packages").get_child("flutter").get_child("pubspec.yaml").exists:
        fail("{}={} is not a flutter/flutter checkout: it has no packages/flutter/pubspec.yaml.".format(env, checkout))

    # The packages and the files the framework expects of its tree, linked so
    # that an edit to the checkout is seen. The `sky_engine` package is the
    # engine's.
    repository_ctx.symlink(root.get_child("packages"), "packages")
    repository_ctx.watch_tree(root.get_child("packages"))
    internal = root.get_child("bin").get_child("internal")
    if not internal.exists:
        fail("{}={} has no bin/internal.".format(env, checkout))
    repository_ctx.symlink(internal, "bin/internal")
    repository_ctx.watch_tree(internal)

    # Which commit it is, and whether it is clean: the host's git, since only
    # git can say what a developer's own checkout is.
    commit = ""
    dirty = False
    head = repository_ctx.execute(["git", "-C", checkout, "rev-parse", "HEAD"])
    if head.return_code == 0:
        commit = head.stdout.strip()
        status = repository_ctx.execute(["git", "-C", checkout, "status", "--porcelain"])
        dirty = status.return_code == 0 and bool(status.stdout.strip())
        git_dir = root.get_child(".git")
        if git_dir.is_dir:
            repository_ctx.watch(git_dir.get_child("HEAD"))
            ref = repository_ctx.read(git_dir.get_child("HEAD")).strip()
            if ref.startswith("ref: "):
                repository_ctx.watch(git_dir.get_child(ref[len("ref: "):]))
            repository_ctx.watch(git_dir.get_child("packed-refs"))

    version_file = root.get_child("bin").get_child("cache").get_child("flutter.version.json")
    if version_file.exists:
        repository_ctx.watch(version_file)
        version = json.decode(repository_ctx.read(version_file))["flutterVersion"]
    else:
        describe = repository_ctx.execute(["git", "-C", checkout, "describe", "--tags"])
        if describe.return_code != 0:
            fail("Cannot tell which Flutter version {} is: it has no bin/cache/flutter.version.json and `git describe --tags` fails.".format(checkout))
        version = describe.stdout.strip()

    repository_ctx.file(FRAMEWORK_JSON, json.encode_indent({
        "version": version,
        "commit": commit,
        "dirty": dirty,
        "origin": "local",
        "path": checkout,
    }) + "\n")

flutter_local_framework = repository_rule(
    _local_framework_impl,
    doc = "A framework source (`flutter_framework.json`, `packages/`, ...) over a flutter/flutter checkout whose path an environment variable gives.",
    attrs = {
        "path_env": attr.string(
            doc = "The environment variable holding the checkout's path. Set it with `--repo_env`.",
            default = "FLUTTER_CHECKOUT",
        ),
        "checkout": attr.label(
            doc = "A file at the root of a checkout that another repository lays out, in place of the " +
                  "environment variable: for a checkout that Bazel itself produces, such as the stand-in a test builds " +
                  "from the official artifacts.",
            allow_single_file = True,
        ),
    },
    local = True,
)

def _missing(name, message):
    return "\nflutter_missing_slice(\n    name = {name},\n    message = {message},\n    visibility = [\"//visibility:public\"],\n)\n".format(
        name = json.encode(name),
        message = json.encode(message),
    )

def _gen_snapshot_file(out, cpu):
    """flutter_tools' `_genSnapshotPath`: the first of these directories holding the name."""
    names = ["gen_snapshot_" + cpu, "gen_snapshot"]
    for directory in [".", "universal", "clang_x64", "clang_x86", "clang_i386", "clang_arm64", "clang_riscv64"]:
        base = out if directory == "." else out.get_child(directory)
        found = first_existing([base.get_child(name) for name in names])
        if found:
            return found
    return None

def _local_engine_impl(repository_ctx):
    path_env = repository_ctx.attr.path_env
    engine_src = _source_path(repository_ctx, path_env, repository_ctx.attr.src)
    pins = [n.strip() for n in (repository_ctx.getenv(repository_ctx.attr.engines_env) or "").split(",") if n.strip()]

    # What the engine is, for the defines programs get: its commit as gn
    # recorded it, and the Dart its SDK bundles. Filled in below.
    engine_json = {
        "origin": "out_dir",
        "description": "Engine out dirs of a Flutter checkout, built outside Bazel",
    }

    provided = {}  # (package, target) -> BUILD text
    reasons = {}  # (package, target) -> why it is missing
    default_reason = ""
    root_exports = ""
    root_build = ""

    machine = machine_of(repository_ctx)
    if not engine_src:
        default_reason = _unset_message(path_env, "the engine's source directory, `engine/src` of a flutter/flutter checkout, in which the engine is built in `out`", "/path/to/flutter/engine/src")
    elif machine == None:
        default_reason = "The engine out dirs are read on macOS, Linux and Windows machines; this one is {} on {}.".format(repository_ctx.os.name, repository_ctx.os.arch)
    else:
        arch = machine.arch
        cpu = arch
        host = machine.key
        os_label = {"macos": "macOS", "linux": "Linux", "windows": "Windows"}[machine.os]
        src = repository_ctx.path(engine_src)
        out_root = src.get_child("out")
        if not out_root.exists:
            fail("{}={} has no out: build the engine in it first.".format(path_env, engine_src))
        repository_ctx.watch(out_root)

        # Candidates: the directories whose name `tools/gn` could have produced
        # and that hold an args.gn, which says what they are.
        candidates = []
        args_of = {}
        ignored = []
        for entry in out_root.readdir():
            parsed = parse_out_dir_name(entry.basename)
            if parsed == None or not entry.is_dir:
                continue
            args_file = entry.get_child("args.gn")
            if not args_file.exists:
                ignored.append(entry.basename + " (no args.gn)")
                continue
            repository_ctx.watch(args_file)
            args = parse_args_gn(repository_ctx.read(args_file))
            args_of[entry.basename] = args
            candidates.append(struct(
                name = parsed.name,
                os = parsed.os,
                mode = parsed.mode,
                sim = parsed.sim,
                unopt = parsed.unopt,
                cpu = effective_cpu(parsed, args),
            ))
        found = ", ".join([c.name for c in candidates] + ignored) or "nothing"

        def advice(mode):
            return (
                "Found: {found}. Build one in the checkout (engine/src/flutter/tools/gn --runtime-mode {mode}{cpu_flag}, " +
                "then ninja -C out/host_{mode}{suffix}), or build in a mode that exists."
            ).format(
                found = found,
                mode = mode,
                cpu_flag = {"macos": " --mac-cpu ", "windows": " --windows-cpu "}.get(machine.os, " --linux-cpu ") + cpu,
                suffix = "" if cpu == "x64" else "_" + cpu,
            )

        # The host out dirs, which are the machine's own build: where Flutter
        # builds the host tools, the product platform kernel and, on a Mac, the
        # macOS engine.
        chosen = {}
        for mode in ["debug", "profile", "release"]:
            pick = select_out_dir(candidates, ["host", machine.os_prefix], mode, cpu, pins)
            if pick.name:
                chosen[mode] = pick.name
            else:
                message = "The engine out dirs under {out} have no {mode} engine for {os} on {cpu}: {error}. {advice}".format(
                    out = out_root,
                    mode = mode,
                    os = os_label,
                    cpu = cpu,
                    error = pick.error,
                    advice = advice(mode),
                )
                if machine.os == "macos":
                    reasons[("macos/" + mode, "engine")] = message
                    reasons[("macos/" + mode, "xcframework")] = message
                    reasons[(native_target(host) + "/" + mode, "gen_snapshot_" + host)] = message
                if mode == "release":
                    reasons[("kernel/release", "platform")] = message
                if mode == "debug":
                    reasons[("kernel/debug", "platform")] = message
                    reasons[("host/" + host, "tools")] = message

        # The host tools and the debug platform kernel: the host debug out dir,
        # where Flutter builds and archives them.
        if "debug" in chosen:
            tools = src.get_child("out").get_child(chosen["debug"])
            args = args_of[chosen["debug"]]
            prebuilt = args.get("flutter_prebuilt_dart_sdk") == "true"
            prebuilt_host = machine.prebuilt
            dart_sdk = src.get_child("flutter").get_child("prebuilts").get_child(prebuilt_host).get_child("dart-sdk") if prebuilt else tools.get_child("dart-sdk")
            files = {
                "dart-sdk": dart_sdk,
                "host-tools/flutter_tester" + machine.exe: tools.get_child("flutter_tester" + machine.exe),
                "host-tools/icudtl.dat": tools.get_child("icudtl.dat"),
                "host-tools/vm_isolate_snapshot.bin": tools.get_child("gen").get_child("flutter").get_child("lib").get_child("snapshot").get_child("vm_isolate_snapshot.bin"),
                "host-tools/isolate_snapshot.bin": tools.get_child("gen").get_child("flutter").get_child("lib").get_child("snapshot").get_child("isolate_snapshot.bin"),
                "host-tools/impellerc" + machine.exe: tools.get_child("impellerc" + machine.exe),
                "host-tools/shader_lib": tools.get_child("shader_lib"),
                "host-tools/font-subset" + machine.exe: tools.get_child("font-subset" + machine.exe),
            }
            absent = [dest for dest, source in files.items() if not source.exists]
            if absent:
                reasons[("host/" + host, "tools")] = (
                    "The host debug out dir {out} lacks {absent}: the host tools are built into it by " +
                    "ninja -C out/{name}."
                ).format(out = tools, absent = ", ".join(sorted(absent)), name = chosen["debug"])
            else:
                for dest, source in files.items():
                    link_into(repository_ctx, source, dest)
                engine_json["engine_revision"] = args.get("engine_version", "")
                engine_json["dart_version"] = repository_ctx.read(dart_sdk.get_child("version")).strip()
                root_build += """
load("@rules_dart//dart:toolchain.bzl", "dart_sdk_files")

dart_sdk_files(
    name = "dart_sdk",
    prefix = "dart-sdk/",
    visibility = ["//visibility:public"],
)

filegroup(
    name = "shader_lib_files",
    srcs = glob(["host-tools/shader_lib/**"]),
    visibility = ["//visibility:public"],
)
"""
                root_exports = 'exports_files(glob(["**"], exclude = ["BUILD.bazel", "flutter_engine.json"]), visibility = ["//visibility:public"])\n'
                prov = dict_text(out_dir_provenance(chosen["debug"], args))
                provided[("host/" + host, "tools")] = """
flutter_host_tools(
    name = "tools",
    host_os = "{os}",
    host_arch = "{arch}",
    dart_sdk = "//:dart_sdk",
    dart = "//:dart-sdk/bin/dart{exe}",
    dartaotruntime = "//:dart-sdk/bin/dartaotruntime{exe}",
    frontend_server = "//:dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot",
    kernel_worker = "//:dart-sdk/bin/snapshots/kernel_worker_aot.dart.snapshot",
    dart_libraries_json = "//:dart-sdk/lib/libraries.json",
    dart_platform_dill = "//:dart-sdk/lib/_internal/vm_platform_strong.dill",
    flutter_tester = "//:host-tools/flutter_tester{exe}",
    icu_data = "//:host-tools/icudtl.dat",
    vm_isolate_snapshot = "//:host-tools/vm_isolate_snapshot.bin",
    isolate_snapshot = "//:host-tools/isolate_snapshot.bin",
    impellerc = "//:host-tools/impellerc{exe}",
    shader_lib = "//:shader_lib_files",
    shader_include_dir = "host-tools/shader_lib",
    font_subset = "//:host-tools/font-subset{exe}",
    provenance = {prov},
    visibility = ["//visibility:public"],
)
""".format(os = machine.os, arch = arch, prov = prov, exe = machine.exe)

            # The `sky_engine` package, as flutter_tools takes it for a local
            # engine: the host build's `gen/dart-pkg/sky_engine`. The framework
            # source's pub tree reads it from here.
            sky_engine = tools.get_child("gen").get_child("dart-pkg").get_child("sky_engine")
            if sky_engine.exists:
                repository_ctx.watch_tree(sky_engine)
                for entry in sky_engine.readdir():
                    repository_ctx.symlink(entry, "sky_engine/" + entry.basename)
            repository_ctx.file("sky_engine/BUILD.bazel", 'exports_files(["pubspec.yaml"], visibility = ["//visibility:public"])\n')

            patched = tools.get_child("flutter_patched_sdk")
            if patched.exists:
                link_files_into(repository_ctx, patched, "kernel/debug/flutter_patched_sdk")
                provided[("kernel/debug", "platform")] = _kernel_stanza("flutter_patched_sdk", dict_text(out_dir_provenance(chosen["debug"], args)))
            else:
                reasons[("kernel/debug", "platform")] = "The host debug out dir {} has no flutter_patched_sdk.".format(tools)

        # The release (product) platform kernel is the host release out dir's.
        if "release" in chosen:
            release_out = src.get_child("out").get_child(chosen["release"])
            patched = release_out.get_child("flutter_patched_sdk")
            if patched.exists:
                link_files_into(repository_ctx, patched, "kernel/release/flutter_patched_sdk_product")
                provided[("kernel/release", "platform")] = _kernel_stanza("flutter_patched_sdk_product", dict_text(out_dir_provenance(chosen["release"], args_of[chosen["release"]])))
            else:
                reasons[("kernel/release", "platform")] = "The host release out dir {} has no flutter_patched_sdk.".format(release_out)

        # The macOS engine, and the gen_snapshot of the AOT modes, of each mode's out dir.
        for mode, name in (chosen.items() if machine.os == "macos" else []):
            out = src.get_child("out").get_child(name)
            args = args_of[name]
            xcframework = out.get_child("FlutterMacOS.xcframework")
            framework = None
            if xcframework.exists:
                for child in xcframework.readdir():
                    if child.basename.startswith("macos-") and child.get_child("FlutterMacOS.framework").exists:
                        framework = child.get_child("FlutterMacOS.framework")
                        break
            if framework == None:
                missing = "The out dir {} has no FlutterMacOS.xcframework with a macOS slice: build the macOS engine target (ninja -C out/{} flutter/shell/platform/darwin/macos:FlutterMacOS).".format(out, name)
                reasons[("macos/" + mode, "engine")] = missing
                reasons[("macos/" + mode, "xcframework")] = missing
            else:
                # The whole xcframework, for macOS add-to-app.
                link_into(repository_ctx, xcframework, "macos/{}/FlutterMacOS.xcframework".format(mode))
                provided[("macos/" + mode, "xcframework")] = """
filegroup(
    name = "xcframework_files",
    srcs = glob(["FlutterMacOS.xcframework/**"]),
)

flutter_macos_engine_slice(
    name = "xcframework",
    mode = "{mode}",
    cpus = ["{engine_cpu}"],
    files = ":xcframework_files",
    binary = ":FlutterMacOS.xcframework/{slice}/FlutterMacOS.framework/Versions/A/FlutterMacOS",
    provenance = {prov},
    visibility = ["//visibility:public"],
)
""".format(mode = mode, engine_cpu = "arm64" if cpu == "arm64" else "x86_64", slice = framework.dirname.basename, prov = dict_text(out_dir_provenance(name, args)))
                link_into(repository_ctx, framework, "macos/{}/FlutterMacOS.framework".format(mode))
                provided[("macos/" + mode, "engine")] = """
filegroup(
    name = "files",
    srcs = glob(["FlutterMacOS.framework/**"]),
)

flutter_macos_engine_slice(
    name = "engine",
    mode = "{mode}",
    cpus = ["{engine_cpu}"],
    files = ":files",
    binary = ":FlutterMacOS.framework/Versions/A/FlutterMacOS",
    provenance = {prov},
    visibility = ["//visibility:public"],
)
""".format(mode = mode, engine_cpu = "arm64" if cpu == "arm64" else "x86_64", prov = dict_text(out_dir_provenance(name, args)))
            if mode != "debug":
                gen_snapshot = _gen_snapshot_file(out, cpu)
                target = native_target(host)
                if gen_snapshot == None:
                    reasons[(target + "/" + mode, "gen_snapshot_" + host)] = "The out dir {} has no gen_snapshot_{} (or gen_snapshot) in ., universal or a clang_* directory.".format(out, cpu)
                else:
                    link_into(repository_ctx, gen_snapshot, "{}/{}/gen_snapshot".format(target, mode))
                    provided[(target + "/" + mode, "gen_snapshot_" + host)] = """
flutter_gen_snapshot(
    name = "gen_snapshot_{host}",
    binary = ":gen_snapshot",
    target_cpu = "{cpu}",
    mode = "{mode}",
    provenance = {prov},
    visibility = ["//visibility:public"],
)
""".format(host = host, cpu = "arm64" if cpu == "arm64" else "x86_64", mode = mode, prov = dict_text(out_dir_provenance(name, args)))

        # The iOS and Android engines, and their gen_snapshots.
        mobile = mobile_slices(repository_ctx, out_root, candidates, args_of, pins, found, machine)
        provided.update(mobile.provided)
        reasons.update(mobile.reasons)

        # The Linux and Windows engines, of the out dirs built for them.
        desktop = desktop_slices(repository_ctx, out_root, candidates, args_of, pins, found, machine)
        provided.update(desktop.provided)
        reasons.update(desktop.reasons)

        # The web SDK, beside the Dart SDK of the host tools.
        web = web_slices(repository_ctx, out_root, candidates, args_of, pins, found, ("host/" + host, "tools") in provided)
        provided.update(web.provided)
        reasons.update(web.reasons)
        root_build += web.root_build

        # The outline stripper, built from the checkout's own Dart source: only
        # it reads the kernels this engine's compiler writes. Used with
        # `--@rules_dart//dart:outline_kernel`, the default.
        dart_src = src.get_child("flutter").get_child("third_party").get_child("dart")
        kernel_pubspec = dart_src.get_child("pkg").get_child("kernel").get_child("pubspec.yaml")
        repository_ctx.watch(kernel_pubspec)
        if kernel_pubspec.exists:
            kernel = fetch_dart_kernel_source(repository_ctx, str(dart_src), "outline_tool/src")
            provided[("outline_tool", "outline_tool")] = """
alias(
    name = "outline_tool",
    actual = "{}",
    visibility = ["//visibility:public"],
)
""".format(kernel.outline_tool)
        else:
            reasons[("outline_tool", "outline_tool")] = (
                "{}={} has no Dart source at {}, which outline compiles build their stripper from: " +
                "run `gclient sync` in the checkout, or build with --@rules_dart//dart:outline_kernel=false."
            ).format(path_env, engine_src, dart_src)

        # A Mac builds the Apple platforms.
        if machine.os != "macos":
            apple = "The engine out dirs are read on a {} machine; macOS and iOS engines are built on a Mac.".format(os_label)
            for mode in ["debug", "profile", "release"]:
                reasons[("macos/" + mode, "engine")] = apple
                reasons[("macos/" + mode, "xcframework")] = apple
                reasons[("ios/" + mode, "engine")] = apple
            for target in ["macos-arm64", "macos-x64", "ios-arm64"]:
                for mode in ["profile", "release"]:
                    for darwin_host in ["darwin-arm64", "darwin-x64"]:
                        reasons[(target + "/" + mode, "gen_snapshot_" + darwin_host)] = apple

    # Every slice of the contract is a target: the ones the out dirs provide,
    # and for the rest a missing slice that says why.
    repository_ctx.file("flutter_engine.json", json.encode_indent(engine_json) + "\n")
    repository_ctx.file("BUILD.bazel", root_build + root_exports + 'exports_files(["flutter_engine.json"], visibility = ["//visibility:public"])\n')
    for package, targets in contract_slices().items():
        content = _ENGINE_LOAD
        for target in targets:
            key = (package, target)
            if key in provided:
                content += provided[key]
            else:
                content += _missing(target, reasons.get(key) or default_reason or (
                    "The engine out dirs have no out dir that provides {}.".format(package + ":" + target)
                ))
        repository_ctx.file(package + "/BUILD.bazel", content)

def _kernel_stanza(top, prov):
    return """
filegroup(
    name = "files",
    srcs = glob(["{top}/**"]),
)

flutter_platform_kernel(
    name = "platform",
    platform_dill = "{top}/platform_strong.dill",
    outline_dill = "{top}/vm_outline_strong.dill",
    files = ":files",
    provenance = {prov},
    visibility = ["//visibility:public"],
)
""".format(top = top, prov = prov)

flutter_local_engine = repository_rule(
    _local_engine_impl,
    doc = "An engine source (the contract of `@rules_flutter//flutter:engine.bzl`) over the out dirs of an engine source directory (`engine/src`, as flutter_tools reads `FLUTTER_ENGINE`) whose path an environment variable gives: the host tools, the platform kernels, the engines of macOS, iOS, Android, Linux and Windows, their gen_snapshots, and the web SDK. A slice no out dir provides is a missing slice that says why.",
    attrs = {
        "path_env": attr.string(
            doc = "The environment variable holding the engine source directory's path. Set it with `--repo_env`.",
            default = "FLUTTER_ENGINE",
        ),
        "engines_env": attr.string(
            doc = "The environment variable naming the out dirs to use, when a slot has more than one candidate.",
            default = "FLUTTER_LOCAL_ENGINES",
        ),
        "src": attr.label(
            doc = "A file at the root of an engine source directory that another repository lays out, in place of the " +
                  "environment variable: for an engine that Bazel itself produces, such as the stand-in a test builds " +
                  "from the official artifacts.",
            allow_single_file = True,
        ),
    },
    local = True,
)
