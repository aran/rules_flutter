"""Modular Flutter kernel compilation for `flutter_test` dependencies and entrypoints.

Compiles each `DartInfo` dependency target in a `flutter_test` closure once into
a `<name>.flutter.kmod` directory against Flutter's patched `platform_strong.dill`
(`--target flutter`), then links the entry module and reachable dependency
modules with `DartKernelLink`.

Uses a distinct provider (`FlutterKernelModuleInfo`) and directory suffix
(`.flutter.kmod`) so the aspect can run over `dart_library` targets alongside
`dart_library`'s own VM `DartKernelInfo` (`<name>.kmod`) without provider or
output-path collisions.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:providers.bzl", "DartCompileInfo", "DartInfo", "DartKernelInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "KERNEL_MODULE_ATTRS",
    "MODULAR_KERNEL_TOOLCHAINS",
    "collect_packages",
    "collect_transitive_srcs",
    "derive_lib_root",
    "duplicated_source",
    "first_per_package",
    "kernel_link_action",
    "kernel_package_config",
    "kernel_packages_consistent",
    "kernel_tools_for",
    "library_source_uri",
    "modular_kernel_eligible",
    "no_kernel_module",
    _DART_MODULAR_KERNEL_ATTRS = "MODULAR_KERNEL_ATTRS",
)
load("//flutter:providers.bzl", "FlutterInfo")
load(
    "//flutter/private:app_entrypoint.bzl",
    "APP_SCHEME",
    "app_main_location",
    "app_scheme_location",
    "package_lib_prefix",
    "stage_generated_inputs",
    "synthesize_app_package",
)
load(
    "//flutter/private:flutter_test_common.bzl",
    "flutter_test_bootstrap_action",
)

FlutterKernelModuleInfo = provider(
    doc = "Modular Flutter kernel info for a DartInfo target.",
    fields = {
        "kernel_info": "DartKernelInfo compiled for the Flutter target and patched SDK.",
        "product_kernel_info": "DartKernelInfo compiled for the Flutter target and product patched SDK (`-Ddart.vm.product=true`).",
    },
)

MODULAR_KERNEL_ATTRS = _DART_MODULAR_KERNEL_ATTRS | {
    "_extra_dart_defines": attr.label(
        default = Label("//flutter:extra_dart_defines"),
        providers = [BuildSettingInfo],
    ),
}

# Build setting read and cleared by `_modular_deps_transition`.
_MODULAR_DEPS_DEFINES_SETTING = str(Label("//flutter:extra_dart_defines"))

def _modular_deps_transition_impl(settings, _attr):
    """Drops the global defines for one custom modular kernel's dependency closure.

    `kernel_worker` parses defines with an ArgParser `splitCommas` converter, so
    any global `--@rules_flutter//flutter:extra_dart_defines` value containing a
    comma (e.g. `FOO=a,b`) aborts every modular action in the closure. The custom
    entry compile below deliberately does not read the flag either, so the whole
    custom closure builds without it; the rule-side `defines` attribute stays the
    only source of `-D` flags. Returning `{}` when the flag is empty keeps the
    configuration identical, so dependency modules built for a custom kernel
    share their action keys with the same modules built for built-in rules.
    """
    if settings[_MODULAR_DEPS_DEFINES_SETTING]:
        return {_MODULAR_DEPS_DEFINES_SETTING: []}
    return {}

_modular_deps_transition = transition(
    implementation = _modular_deps_transition_impl,
    inputs = [_MODULAR_DEPS_DEFINES_SETTING],
    outputs = [_MODULAR_DEPS_DEFINES_SETTING],
)

def _no_flutter_kernel_module():
    empty = no_kernel_module()
    return [
        FlutterKernelModuleInfo(
            kernel_info = empty,
            product_kernel_info = empty,
        ),
    ]

def _global_extra_defines(ctx):
    defines = []
    if hasattr(ctx.attr, "_extra_dart_defines") and ctx.attr._extra_dart_defines != None:
        defines.extend(ctx.attr._extra_dart_defines[BuildSettingInfo].value)
    return defines

def _has_comma_defines(ctx):
    return any(["," in d for d in _global_extra_defines(ctx)])

def _kernel_worker_defines(ctx):
    """Returns global `extra_dart_defines` entries supported by `kernel_worker`.

    `kernel_worker`'s `ArgParser` declares `-D` / `--define` with `package:args`'s
    default `splitCommas: true`, so a define whose value contains `,` (such as
    `e2e/hello_world/.bazelrc`'s `E2E_FLAG=from,flag`) would be split at the
    comma and rejected with `FormatException: no value given to -D option`.
    When any global define contains `,`, `_has_comma_defines(ctx)` disables
    modular kernel compilation so targets fall back to whole-program
    `frontend_server` compilation instead of silently dropping the define.
    """
    return [
        d
        for d in _global_extra_defines(ctx)
        if "," not in d
    ]

def _sdk_root_from_dart(dart_file):
    p = dart_file.path
    for suffix in ("/bin/dart", "/bin/dart.exe"):
        if p.endswith(suffix):
            return p[:-len(suffix)]
    return p

def is_same_sdk(exec_tools, flutter_sdk_info):
    """Returns True when `exec_tools` and `flutter_sdk_info` refer to the same Dart SDK.

    Compares executable file identity (`dartaotruntime`, then `dart`), falling back
    to SDK version string comparison when neither executable pair is present.

    Args:
      exec_tools: The kernel tools struct (e.g. from `kernel_tools_for(ctx)`).
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.

    Returns:
      `True` if both toolchains refer to the same Dart SDK, else `False`.
    """
    if exec_tools == None or flutter_sdk_info == None:
        return False
    exec_aot = getattr(exec_tools, "dartaotruntime", None)
    flutter_aot = getattr(flutter_sdk_info, "dartaotruntime", None)
    if exec_aot != None and flutter_aot != None:
        return exec_aot == flutter_aot
    exec_dart = getattr(exec_tools, "dart", None)
    flutter_dart = getattr(flutter_sdk_info, "dart", None)
    if exec_dart != None and flutter_dart != None:
        return exec_dart == flutter_dart
    exec_version = getattr(exec_tools, "version", None)
    flutter_version = getattr(flutter_sdk_info, "version", None)
    if exec_version != None and flutter_version != None:
        return exec_version == flutter_version
    return False

def find_flutter_kernel_module_tools(flutter_sdk_info, exec_tools = None):
    """Selects kernel module tools matching `flutter_sdk_info`'s bundled Dart SDK.

    When `exec_tools` is already from the same SDK (`is_same_sdk(exec_tools, flutter_sdk_info)`),
    returns `exec_tools` directly. When `@rules_dart`'s standalone toolchain resolved
    ahead of `@flutter_toolchains`, locates `kernel_worker_aot.dart.snapshot` and
    `libraries.json` in `flutter_sdk_info.tool_files` so modular `.flutter.kmod`
    compilation runs the `kernel_worker` and `dartaotruntime` matching
    `flutter_sdk_info.platform_kernel_dill` and `flutter_tester`, while keeping
    `exec_tools`'s outer VM (`dart`, `dartvm`, `runtime_files`, `version`) that
    launches the `@rules_dart//dart/private/tools:kernel_module` tool.

    Args:
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
      exec_tools: Optional struct from `kernel_tools_for(ctx)`.

    Returns:
      A kernel tools struct whose `dartaotruntime`, `kernel_worker`, and
      `libraries_json` match `flutter_sdk_info`, or `None` if `flutter_sdk_info`
      lacks the required files.
    """
    if flutter_sdk_info == None or flutter_sdk_info.dart == None or flutter_sdk_info.dartaotruntime == None:
        return None
    if exec_tools != None and is_same_sdk(exec_tools, flutter_sdk_info):
        return exec_tools

    sdk_root = _sdk_root_from_dart(flutter_sdk_info.dart)
    dartvm_paths = (sdk_root + "/bin/dartvm", sdk_root + "/bin/dartvm.exe")
    wanted = {
        "kernel_worker": sdk_root + "/bin/snapshots/kernel_worker_aot.dart.snapshot",
        "libraries_json": sdk_root + "/lib/libraries.json",
    }
    dartvm = None
    found = {}
    for f in flutter_sdk_info.tool_files.to_list():
        if f.path in dartvm_paths:
            dartvm = f
        for key, path in wanted.items():
            if f.path == path:
                found[key] = f
    if len(found) != len(wanted):
        return None

    return struct(
        dart = exec_tools.dart if exec_tools != None else flutter_sdk_info.dart,
        dartvm = exec_tools.dartvm if exec_tools != None else dartvm,
        runtime_files = exec_tools.runtime_files if exec_tools != None else flutter_sdk_info.dart_vm_files,
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        kernel_worker = found["kernel_worker"],
        platform_dill = flutter_sdk_info.platform_kernel_dill,
        libraries_json = found["libraries_json"],
        version = exec_tools.version if exec_tools != None else flutter_sdk_info.version,
    )

def flutter_kernel_tools_for(ctx, flutter_sdk_info):
    """Returns kernel module tools whose compiler matches `flutter_sdk_info`, or `None`.

    Args:
      ctx: Rule or aspect context declaring `MODULAR_KERNEL_TOOLCHAINS`.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.

    Returns:
      The kernel tools struct matching `flutter_sdk_info`, or `None`.
    """
    exec_tools = kernel_tools_for(ctx)
    if exec_tools == None or flutter_sdk_info == None:
        return None
    return find_flutter_kernel_module_tools(flutter_sdk_info, exec_tools = exec_tools)

def _own_package_record(info):
    """Returns the `DartPackageInfo` for the package a `DartInfo` itself owns."""
    if not info.package_name:
        return None
    for pkg in info.transitive_packages.to_list():
        if pkg.package_name == info.package_name and pkg.lib_root == info.lib_root:
            return pkg
    return None

def _is_manual(ctx):
    if ctx.label.package.startswith("flutter/tests"):
        return True
    tags = getattr(ctx.attr, "tags", None)
    if tags == None and hasattr(ctx, "rule"):
        tags = getattr(ctx.rule.attr, "tags", None)
    return tags != None and "manual" in tags

def _dedup_module_sources(sources):
    """Deduplicates `struct(uri, file)` entries by `uri`, preferring generated files over source files to match `[stage.root, '.']` resolution."""
    by_uri = {}
    order = []
    for s in sources:
        prev = by_uri.get(s.uri)
        if prev == None:
            by_uri[s.uri] = s
            order.append(s.uri)
        elif prev.file.is_source and not s.file.is_source:
            by_uri[s.uri] = s
    return [by_uri[u] for u in order]

def _kernel_module_staged_inputs(ctx, sources, output, extra_inputs, packages, scheme):
    """Dedup sources and stage every generated input; returns `(package_config, stage)`."""
    sources = _dedup_module_sources(sources)
    package_config = ctx.actions.declare_file(output.basename + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = kernel_package_config(packages, scheme = scheme),
    )

    stage_candidates = [s.file for s in sources]
    if extra_inputs != None:
        stage_candidates = stage_candidates + extra_inputs.to_list()

    # Every source is staged and only the staging root is mounted: mounting
    # the exec root (`.`) lets the compile read files the action did not
    # declare, which Bazel then caches without rerunning on their change.
    stage = stage_generated_inputs(ctx, stage_candidates, output.basename, include_sources = True)
    return sources, package_config, stage

def _kernel_module_base_args(ctx, target, platform, package_config, libraries, libraries_platform, extra_libraries, stage, scheme, defines, extra_frontend_flags, exclude_non_sources):
    """The kernel worker flags naming the target, SDK summaries and compile mode."""
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")

    args.add("--target", target)
    args.add("--dart-sdk-summary", platform)
    args.add("--packages-file", package_config)
    args.add("--libraries-json", libraries)
    if libraries_platform:
        args.add("--libraries-platform", libraries_platform)
    args.add_all(extra_libraries, before_each = "--extra-library")
    if stage.root != None:
        args.add("--multi-root", stage.root)
    args.add("--multi-root-scheme", scheme)
    args.add_all([d for d in defines if "," not in d], format_each = "-D%s")
    args.add_all(extra_frontend_flags)
    args.add("--no-summary-only")
    args.add("--reuse-compiler-result")
    args.add("--use-incremental-compiler")
    if exclude_non_sources:
        args.add("--exclude-non-sources")
    return args

def _kernel_module_source_args(args, sources, dep_kmods, output, koutline, excluded, unused_inputs_list, droppable, closure_excluded, extra_inputs):
    """Append the per-source, output and closure flags to the kernel worker args."""
    args.add_all(dep_kmods, before_each = "--input-kmod", expand_directories = False)
    for s in sources:
        args.add("--source", s.uri)
        args.add("--input-source", s.file)
        if unused_inputs_list != None:
            args.add("--own-source-file", s.file)
    args.add("--output", output.path)
    if koutline != None:
        args.add("--output-outline", koutline.path)

    args.add("--excluded-output", excluded)
    if unused_inputs_list != None:
        args.add("--unused-inputs-list", unused_inputs_list)
    if not droppable:
        args.add("--no-drop")
    if closure_excluded:
        args.add_all(closure_excluded, before_each = "--closure-excluded")
    if extra_inputs:
        args.add_all(extra_inputs, before_each = "--input-source")

def _kernel_module_tool_inputs(ctx, tools, args, direct_inputs, action_tools):
    """Pick the kernel worker executable and register its tool inputs.

    Returns the `(executable, arguments)` pair for the compile action.
    """
    dart_exe = getattr(tools, "dart", None)
    dartvm = getattr(tools, "dartvm", None)
    tool_target = getattr(ctx.attr, "_kernel_module", None)
    tool_compile_mode = (
        tool_target[DartCompileInfo].compile_mode if tool_target != None and DartCompileInfo in tool_target else "kernel"
    )
    if tool_compile_mode == "aot-snapshot":
        # The tool is an AOT snapshot: `dart` refuses to run `.aot` files, so
        # `dartaotruntime` executes it directly. This also drops the `dart` and
        # `dartvm` inputs: the snapshot needs only the runtime.
        direct_inputs.append(ctx.executable._kernel_module)
        executable = tools.dartaotruntime
        arguments = [
            ctx.executable._kernel_module.path,
            "--kernel-worker",
            tools.kernel_worker.path,
            "--dartaotruntime",
            tools.dartaotruntime.path,
            args,
        ]
    elif dart_exe != None:
        direct_inputs.extend([ctx.executable._kernel_module, dart_exe])
        action_tools.append(dart_exe)
        if dartvm != None:
            direct_inputs.append(dartvm)
            action_tools.append(dartvm)
        executable = dart_exe
        arguments = [
            ctx.executable._kernel_module.path,
            "--kernel-worker",
            tools.kernel_worker.path,
            "--dartaotruntime",
            tools.dartaotruntime.path,
            args,
        ]
    else:
        executable = ctx.executable._kernel_module
        arguments = [
            "--kernel-worker",
            tools.kernel_worker.path,
            "--dartaotruntime",
            tools.dartaotruntime.path,
            args,
        ]
    return executable, arguments

def flutter_kernel_module_action(
        ctx,
        tools,
        sources,
        packages,
        dep_kmods,
        output,
        defines,
        exclude_non_sources,
        droppable,
        koutline = None,
        extra_inputs = None,
        closure_excluded = None,
        target = "flutter",
        platform_dill = None,
        libraries_json = None,
        libraries_platform = None,
        extra_libraries = [],
        scheme = APP_SCHEME,
        extra_frontend_flags = [],
        unused_inputs = False):
    """Compiles one Flutter kernel module with staged generated inputs instead of mounting `ctx.bin_dir`.

    Args:
      ctx: The rule or aspect context, used to declare outputs and register the action.
      tools: Kernel tool files (compiler, platform dill, libraries specification).
      sources: Structs with `uri` and `file` for the module's own Dart sources.
      packages: Package records rendered into the `--packages-file` package config.
      dep_kmods: Transitive dependency kernels and outlines (`--input-kmod`).
      output: The module output (a `.kmod` directory for libraries, entries otherwise).
      defines: Extra `--define` flags forwarded to the kernel worker.
      exclude_non_sources: Whether the compile writes the VM exclusion report.
      droppable: Whether unreachable libraries may be dropped from the module.
      koutline: Optional outline output receiving `--output-outline`.
      extra_inputs: Optional additional input files (e.g. entry sources).
      closure_excluded: Optional upstream exclusion reports for the closed world.
      target: Kernel worker `--target` (defaults to `"flutter"`).
      platform_dill: SDK summary override; defaults to the toolchain's.
      libraries_json: Libraries specification override; defaults to the toolchain's.
      libraries_platform: Optional platform libraries specification override.
      extra_libraries: Extra SDK libraries available to the compile.
      scheme: Package-config URI scheme for the module's sources.
      extra_frontend_flags: Additional flags forwarded to the frontend.
      unused_inputs: Whether the compile writes its unused-inputs list — the
        declared inputs no compile of this action read — and takes it as the
        action's `unused_inputs_list`, so Bazel skips the action when only an
        unread input changed. True at every call site: each registers its
        action once (the aspect's evaluations of one target compute identical
        actions, which Bazel merges), as `dart_library`'s own module does in
        rules_dart. False registers the historical action with no list.

    Returns:
      The declared VM exclusion report file.
    """
    sources, package_config, stage = _kernel_module_staged_inputs(ctx, sources, output, extra_inputs, packages, scheme)
    platform = platform_dill if platform_dill != None else tools.platform_dill
    libraries = libraries_json if libraries_json != None else tools.libraries_json
    excluded = ctx.actions.declare_file(output.basename + ".vm_excluded.txt")
    if unused_inputs:
        # Written by `kernel_module` alongside the module. Declared here, where
        # the one registering action is, so the declaration and the action
        # that generates the file can never part ways.
        unused_inputs_list = ctx.actions.declare_file(output.basename + ".unused_inputs")
    else:
        unused_inputs_list = None

    args = _kernel_module_base_args(ctx, target, platform, package_config, libraries, libraries_platform, extra_libraries, stage, scheme, defines, extra_frontend_flags, exclude_non_sources)
    _kernel_module_source_args(args, sources, dep_kmods, output, koutline, excluded, unused_inputs_list, droppable, closure_excluded, extra_inputs)

    runtime_files = getattr(tools, "runtime_files", None)
    direct_inputs = [
        package_config,
        tools.dartaotruntime,
        tools.kernel_worker,
        libraries,
        platform,
    ] + [s.file for s in sources] + stage.files
    action_tools = [
        tools.dartaotruntime,
        tools.kernel_worker,
        platform,
        ctx.executable._kernel_module,
    ]
    executable, arguments = _kernel_module_tool_inputs(ctx, tools, args, direct_inputs, action_tools)

    ctx.actions.run(
        executable = executable,
        arguments = arguments,
        inputs = depset(
            direct = direct_inputs,
            transitive = [dep_kmods] + [
                d
                for d in [extra_inputs, closure_excluded]
                if d
            ],
        ),
        tools = depset(
            direct = action_tools,
            transitive = [runtime_files] if runtime_files != None else [],
        ),
        outputs = [output, excluded] + ([unused_inputs_list] if unused_inputs_list != None else []) + ([koutline] if koutline != None else []),
        unused_inputs_list = unused_inputs_list,
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel module %s" % output.short_path,
        execution_requirements = {} if _is_manual(ctx) else {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
    )
    return excluded

def _modular_gate_inputs(ctx, target):
    """The target's Dart metadata and dependency list behind the modular-kernel gate."""
    dart_info = target[DartInfo]
    rule_deps = getattr(ctx.rule.attr, "deps", [])
    if type(rule_deps) != "list":
        rule_deps = [rule_deps]
    return (
        dart_info,
        dart_info.package_name,
        dart_info.lib_root,
        _own_package_record(dart_info),
        getattr(ctx.rule.files, "srcs", []),
        rule_deps,
    )

def _is_opaque_module(ctx, dart_info, package_name, lib_root, own_record, own_srcs, rule_deps):
    """Whether the target hides its sources, opting it out of modular kernel compilation."""
    srcs_dir = getattr(ctx.rule.attr, "srcs_dir", None)
    has_srcs_attr = hasattr(ctx.rule.attr, "srcs")
    opaque = bool(srcs_dir)
    if not has_srcs_attr and dart_info.transitive_srcs.to_list() != [] and len(rule_deps) == 0:
        opaque = True
    prefix = package_lib_prefix(lib_root)
    if own_srcs and (not package_name or own_record == None or any([not f.short_path.startswith(prefix) for f in own_srcs])):
        opaque = True
    return opaque

def _modular_gate_open(ctx, opaque, enabled, tools, same_sdk, flutter_sdk_info):
    """Whether every modular-kernel precondition holds for this evaluation."""
    return not opaque and enabled and not _has_comma_defines(ctx) and tools != None and same_sdk and flutter_sdk_info != None and flutter_sdk_info.platform_kernel_dill != None

def _collect_dep_mod_infos(rule_deps):
    """The dep `FlutterKernelModuleInfo` values, or None when a dep opted out."""
    dep_mod_infos = [
        dep[FlutterKernelModuleInfo]
        for dep in rule_deps
        if type(dep) == "Target" and FlutterKernelModuleInfo in dep
    ]
    if len(dep_mod_infos) != len(rule_deps):
        return None
    return dep_mod_infos

def _modular_consistency(own_record, rule_deps, dep_kernels):
    """The package records and whether deps agree on one modular closure."""
    raw = depset(
        transitive = [
            dep[DartInfo].transitive_packages
            for dep in rule_deps
            if type(dep) == "Target" and DartInfo in dep
        ],
    ).to_list()
    records = ([own_record] if own_record != None else []) + raw
    packages_ok = kernel_packages_consistent(records)
    modular = packages_ok and all([k.modular for k in dep_kernels])
    return records, packages_ok, modular

def _modular_dep_closures(target, dep_kernels, rule_deps, own_srcs):
    """The postorder dep closures and ownership graphs propagated by the aspect."""
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    dep_outline_closure = depset(
        order = "postorder",
        transitive = [k.transitive_koutlines for k in dep_kernels],
    )
    upstream_excluded = depset(transitive = [k.closure_excluded for k in dep_kernels])
    has_cross_pkg_cycle = False
    cross_pkg_srcs = (
        depset(own_srcs, transitive = [collect_transitive_srcs(rule_deps)]) if has_cross_pkg_cycle else depset(transitive = [k.cross_pkg_srcs for k in dep_kernels])
    )
    owned = depset(
        [(str(target.label), f.short_path) for f in own_srcs],
        transitive = [k.owned for k in dep_kernels],
    )
    edges = depset(
        [(str(target.label), str(dep.label)) for dep in rule_deps],
        transitive = [k.edges for k in dep_kernels],
    )
    return dep_closure, dep_outline_closure, upstream_excluded, cross_pkg_srcs, owned, edges

def _find_dep_base_dill(dep_kernels):
    """The first dep-seeded base dill triple, or empty defaults when no dep seeds one."""
    base_dill = None
    base_keys = None
    base_kmods = depset()
    for k in dep_kernels:
        kd = getattr(k, "base_dill", None)
        kk = getattr(k, "base_keys", None)
        if kd != None and kk != None:
            base_dill = kd
            base_keys = kk
            base_kmods = getattr(k, "base_kmods", depset())
            break
    return base_dill, base_keys, base_kmods

def _header_only_module_info(product_modular, dep_product_kernels, dep_closure, dep_outline_closure, upstream_excluded, cross_pkg_srcs, owned, edges, base_dill, base_keys, base_kmods):
    """The provider list for a target with no own sources: dep closures only."""
    product_kernel_info = (
        DartKernelInfo(
            kmod = None,
            koutline = None,
            transitive_kmods = depset(
                order = "postorder",
                transitive = [k.transitive_kmods for k in dep_product_kernels],
            ),
            transitive_koutlines = depset(
                order = "postorder",
                transitive = [k.transitive_koutlines for k in dep_product_kernels],
            ),
            modular = True,
            closure_excluded = depset(transitive = [k.closure_excluded for k in dep_product_kernels]),
            cross_pkg_srcs = cross_pkg_srcs,
            owned = owned,
            edges = edges,
            base_dill = None,
            base_keys = None,
            base_kmods = depset(),
            unseeded_base_kmods = depset(),
        ) if product_modular else no_kernel_module()
    )
    return [
        FlutterKernelModuleInfo(
            kernel_info = DartKernelInfo(
                kmod = None,
                koutline = None,
                transitive_kmods = dep_closure,
                transitive_koutlines = dep_outline_closure,
                modular = True,
                closure_excluded = upstream_excluded,
                cross_pkg_srcs = cross_pkg_srcs,
                owned = owned,
                edges = edges,
                base_dill = base_dill,
                base_keys = base_keys,
                base_kmods = base_kmods,
                unseeded_base_kmods = depset(),
            ),
            product_kernel_info = product_kernel_info,
        ),
    ]

def _compile_main_kmod(ctx, tools, target_name, package_name, lib_root, own_srcs, records, flutter_sdk_info, dep_outline_closure, upstream_excluded):
    """Compile the target's own sources into the debug `.flutter.kmod` directory."""
    kmod = ctx.actions.declare_directory(target_name + ".flutter.kmod")
    koutline = ctx.actions.declare_directory(target_name + ".flutter.koutline")
    sources = [
        struct(uri = library_source_uri(package_name, lib_root, f.short_path), file = f)
        for f in own_srcs
    ]
    deduped_packages = first_per_package(records)
    worker_defines = _kernel_worker_defines(ctx)
    excluded = flutter_kernel_module_action(
        ctx,
        tools,
        sources,
        deduped_packages,
        dep_outline_closure,
        kmod,
        koutline = koutline,
        defines = worker_defines,
        exclude_non_sources = True,
        droppable = True,
        closure_excluded = upstream_excluded,
        target = "flutter",
        platform_dill = flutter_sdk_info.platform_kernel_dill,
        extra_libraries = ["ui", "nativewrappers"],
        scheme = APP_SCHEME,
        unused_inputs = True,
    )
    return kmod, koutline, sources, deduped_packages, worker_defines, excluded

def _link_flutter_test_base(ctx, target_name, package_name, kmod, dep_closure, base_dill, base_keys, base_kmods):
    """Seed the `flutter_test` base dill from the debug modules; returns the base triple."""
    if package_name == "flutter_test" and hasattr(ctx.executable, "_kernel_link"):
        base_dill = ctx.actions.declare_file(target_name + ".flutter_base.dill")
        base_keys = ctx.actions.declare_file(target_name + ".flutter_base.keys")
        seed_modules = [kmod] + dep_closure.to_list()
        kernel_link_action(
            ctx,
            dep_closure,
            entry = None,
            output = base_dill,
            seed_modules = seed_modules,
            write_keys = base_keys,
        )
        base_kmods = depset(direct = [kmod], transitive = [dep_closure])
    return base_dill, base_keys, base_kmods

def _compile_product_kmod(ctx, target_name, tools, sources, deduped_packages, worker_defines, flutter_sdk_info, dep_product_kernels, cross_pkg_srcs, owned, edges):
    """Compile the product (AOT/profile) `.flutter_product.kmod` directory."""
    product_dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_product_kernels],
    )
    product_dep_outline_closure = depset(
        order = "postorder",
        transitive = [k.transitive_koutlines for k in dep_product_kernels],
    )
    product_upstream_excluded = depset(
        transitive = [k.closure_excluded for k in dep_product_kernels],
    )
    product_kmod = ctx.actions.declare_directory(target_name + ".flutter_product.kmod")
    product_koutline = ctx.actions.declare_directory(target_name + ".flutter_product.koutline")
    product_excluded = flutter_kernel_module_action(
        ctx,
        tools,
        sources,
        deduped_packages,
        product_dep_outline_closure,
        product_kmod,
        koutline = product_koutline,
        defines = worker_defines + [
            "dart.vm.product=true",
            "FLUTTER_WEB_USE_SKIA=false",
            "FLUTTER_WEB_USE_SKWASM=true",
        ],
        exclude_non_sources = True,
        droppable = True,
        closure_excluded = product_upstream_excluded,
        target = "flutter",
        platform_dill = flutter_sdk_info.platform_kernel_dill_product,
        extra_libraries = ["ui", "nativewrappers"],
        scheme = APP_SCHEME,
        unused_inputs = True,
    )
    return DartKernelInfo(
        kmod = product_kmod,
        koutline = product_koutline,
        transitive_kmods = depset(order = "postorder", direct = [product_kmod], transitive = [product_dep_closure]),
        transitive_koutlines = depset(order = "postorder", direct = [product_koutline], transitive = [product_dep_outline_closure]),
        modular = True,
        closure_excluded = depset(direct = [product_excluded], transitive = [product_upstream_excluded]),
        cross_pkg_srcs = cross_pkg_srcs,
        owned = owned,
        edges = edges,
        base_dill = None,
        base_keys = None,
        base_kmods = depset(),
        unseeded_base_kmods = depset(),
    )

def _flutter_kernel_module_aspect_impl(target, ctx):
    if DartInfo not in target:
        return _no_flutter_kernel_module()

    enabled = ctx.attr._modular_kernel[BuildSettingInfo].value
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info if flutter_toolchain else None
    tools = flutter_kernel_tools_for(ctx, flutter_sdk_info)
    same_sdk = is_same_sdk(tools, flutter_sdk_info)

    dart_info, package_name, lib_root, own_record, own_srcs, rule_deps = _modular_gate_inputs(ctx, target)
    opaque = _is_opaque_module(ctx, dart_info, package_name, lib_root, own_record, own_srcs, rule_deps)
    if not _modular_gate_open(ctx, opaque, enabled, tools, same_sdk, flutter_sdk_info):
        return _no_flutter_kernel_module()

    dep_mod_infos = _collect_dep_mod_infos(rule_deps)
    if dep_mod_infos == None:
        return _no_flutter_kernel_module()
    dep_kernels = [m.kernel_info for m in dep_mod_infos]
    dep_product_kernels = [m.product_kernel_info for m in dep_mod_infos]

    records, packages_ok, modular = _modular_consistency(own_record, rule_deps, dep_kernels)
    if not modular:
        return _no_flutter_kernel_module()
    product_modular = (
        packages_ok and
        flutter_sdk_info.platform_kernel_dill_product != None and
        all([k.modular for k in dep_product_kernels])
    )

    dep_closure, dep_outline_closure, upstream_excluded, cross_pkg_srcs, owned, edges = _modular_dep_closures(target, dep_kernels, rule_deps, own_srcs)
    base_dill, base_keys, base_kmods = _find_dep_base_dill(dep_kernels)

    if not own_srcs:
        return _header_only_module_info(product_modular, dep_product_kernels, dep_closure, dep_outline_closure, upstream_excluded, cross_pkg_srcs, owned, edges, base_dill, base_keys, base_kmods)

    kmod, koutline, sources, deduped_packages, worker_defines, excluded = _compile_main_kmod(ctx, tools, target.label.name, package_name, lib_root, own_srcs, records, flutter_sdk_info, dep_outline_closure, upstream_excluded)
    base_dill, base_keys, base_kmods = _link_flutter_test_base(ctx, target.label.name, package_name, kmod, dep_closure, base_dill, base_keys, base_kmods)

    if product_modular:
        product_kernel_info = _compile_product_kmod(ctx, target.label.name, tools, sources, deduped_packages, worker_defines, flutter_sdk_info, dep_product_kernels, cross_pkg_srcs, owned, edges)
    else:
        product_kernel_info = no_kernel_module()

    return [
        FlutterKernelModuleInfo(
            kernel_info = DartKernelInfo(
                kmod = kmod,
                koutline = koutline,
                transitive_kmods = depset(order = "postorder", direct = [kmod], transitive = [dep_closure]),
                transitive_koutlines = depset(order = "postorder", direct = [koutline], transitive = [dep_outline_closure]),
                modular = True,
                closure_excluded = depset(direct = [excluded], transitive = [upstream_excluded]),
                cross_pkg_srcs = cross_pkg_srcs,
                owned = owned,
                edges = edges,
                base_dill = base_dill,
                base_keys = base_keys,
                base_kmods = base_kmods,
                unseeded_base_kmods = depset(),
            ),
            product_kernel_info = product_kernel_info,
        ),
    ]

flutter_kernel_module_aspect = aspect(
    implementation = _flutter_kernel_module_aspect_impl,
    attr_aspects = ["deps"],
    attrs = KERNEL_MODULE_ATTRS | {
        "_extra_dart_defines": attr.label(
            default = Label("//flutter:extra_dart_defines"),
            providers = [BuildSettingInfo],
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ] + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles each DartInfo library in a flutter_test closure into a modular .flutter.kmod directory.",
)

def _compile_flutter_entry_module(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        entry_name,
        platform_dill):
    """Compiles one Flutter entry module against dependency outlines.

    Shared by the built-in test/app compiles below and the public custom-kernel
    functions: the entry module sees only the dependency outlines (never their
    sources), so a body-only edit to a library recompiles that library's module
    plus the entry/link actions — never the whole program.
    """
    dep_outline_closure = depset(
        order = "postorder",
        transitive = [k.transitive_koutlines for k in dep_kernels],
    )
    cross_pkg_srcs = depset(
        transitive = [k.cross_pkg_srcs for k in dep_kernels],
    )
    entry = ctx.actions.declare_directory(entry_name)
    flutter_kernel_module_action(
        ctx,
        tools,
        sources,
        first_per_package(packages),
        dep_outline_closure,
        entry,
        defines = _kernel_worker_defines(ctx),
        exclude_non_sources = True,
        droppable = False,
        extra_inputs = cross_pkg_srcs,
        closure_excluded = depset(
            transitive = [k.closure_excluded for k in dep_kernels],
        ),
        target = "flutter",
        platform_dill = platform_dill,
        extra_libraries = ["ui", "nativewrappers"],
        scheme = APP_SCHEME,
        unused_inputs = True,
    )
    return entry

def _link_flutter_test_entry_module(ctx, dep_kernels, entry, output):
    """Links a test entry module, delta-linking against the flutter_test base dill.

    Returns the base dill linked against, or `None` when no base dill applies.
    Shared by the built-in test compile below and the public custom test kernel.
    """
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    base_dill = None
    base_keys = None
    base_kmods = depset()
    for k in dep_kernels:
        kd = getattr(k, "base_dill", None)
        kk = getattr(k, "base_keys", None)
        if kd != None and kk != None:
            base_dill = kd
            base_keys = kk
            base_kmods = getattr(k, "base_kmods", depset())
            break
    link_dep_closure = dep_closure
    if base_dill != None and base_keys != None:
        base_kmod_paths = {f.path: True for f in base_kmods.to_list()}
        if base_kmod_paths:
            link_dep_closure = depset(
                [f for f in dep_closure.to_list() if f.path not in base_kmod_paths],
                order = "postorder",
            )
    kernel_link_action(
        ctx,
        link_dep_closure,
        entry,
        output,
        base_keys = base_keys,
    )
    return base_dill

def flutter_modular_test_tools(ctx, flutter_sdk_info, own_files, packages, native_assets_list, tools = None, product = False):
    """Decides whether a target compiles modularly, and with which tools.

    Args:
      ctx: The rule context.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
      own_files: The target's own `.dart` files (`[ctx.file.main] + ctx.files.srcs`).
      packages: The synthesized `DartPackageInfo` list for the target.
      native_assets_list: Resolved native code assets for the target.
      tools: Optional pre-resolved kernel tools struct; defaults to
        `flutter_kernel_tools_for(ctx, flutter_sdk_info)`.
      product: When `True`, checks eligibility for `product_kernel_info`
        (`-Ddart.vm.product=true` against `platform_kernel_dill_product`).

    Returns:
      The kernel tools struct from `flutter_kernel_tools_for`, or `None` when the target
      must fall back to whole-program `FlutterKernelCompile`.
    """
    enabled = ctx.attr._modular_kernel[BuildSettingInfo].value if hasattr(ctx.attr, "_modular_kernel") else False
    platform_dill = (
        flutter_sdk_info.platform_kernel_dill_product if product and flutter_sdk_info != None else (flutter_sdk_info.platform_kernel_dill if flutter_sdk_info != None else None)
    )
    if not enabled or _has_comma_defines(ctx) or platform_dill == None:
        return None
    if tools == None:
        tools = flutter_kernel_tools_for(ctx, flutter_sdk_info)
    if tools == None:
        return None
    same_sdk = is_same_sdk(tools, flutter_sdk_info)

    dep_kernels = [
        dep[FlutterKernelModuleInfo].product_kernel_info if product else dep[FlutterKernelModuleInfo].kernel_info
        for dep in ctx.attr.deps
        if FlutterKernelModuleInfo in dep
    ]
    dep_modular = len(dep_kernels) == len(ctx.attr.deps) and all([k.modular for k in dep_kernels])

    owned = depset(transitive = [k.owned for k in dep_kernels]).to_list()
    edges = depset(transitive = [k.edges for k in dep_kernels]).to_list()
    duplicate = duplicated_source([f.short_path for f in own_files], owned, edges)

    eligible = modular_kernel_eligible(
        enabled = enabled,
        kernel_mode = True,
        dep_modular = dep_modular,
        packages_consistent = kernel_packages_consistent(packages),
        has_code_assets = len(native_assets_list) > 0,
        has_own_defines = len(ctx.attr.defines) > 0,
        has_compile_flags = False,
        has_duplicate_source = duplicate != None,
        same_sdk = same_sdk,
    )
    return tools if eligible else None

def compile_flutter_modular_test_kernel(
        ctx,
        flutter_sdk_info,
        tools,
        bootstrap,
        staged_comparator,
        lib_root,
        packages,
        output):
    """Compiles a `flutter_test`'s entry module and links it with dependency modules.

    Compiles against the debug `platform_kernel_dill` without product defines so
    `kernel_worker` preserves `AssertStatement` and `AssertInitializer` nodes in
    both `.flutter.kmod` / `.flutter.koutline` and `.flutter_entry.kmod` (matching
    `--enable-asserts` in a whole-program `-c dbg` compile), which fire at runtime
    under `flutter_tester --enable-checked-mode`.

    Args:
      ctx: The `flutter_test` rule context.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
      tools: The kernel tools struct returned by `flutter_modular_test_tools`.
      bootstrap: The generated `<name>_bootstrap.dart` File (entry point).
      staged_comparator: Optional staged `<name>.golden_comparator.dart` File.
      lib_root: The test package's `lib_root` from `derive_lib_root`.
      packages: The synthesized `DartPackageInfo` list for the test.
      output: The linked `.dill` File to produce.

    Returns:
      The `base_dill` File from the transitive SDK packages if present, or `None`.
    """
    sources = [
        struct(uri = app_scheme_location(bootstrap).uri, file = bootstrap),
    ]
    if staged_comparator != None:
        sources.append(struct(uri = app_scheme_location(staged_comparator).uri, file = staged_comparator))
    sources.append(struct(
        uri = app_main_location(ctx.attr.package_name, lib_root, ctx.file.main).uri,
        file = ctx.file.main,
    ))
    for f in ctx.files.srcs:
        if f == ctx.file.main:
            continue
        sources.append(struct(
            uri = app_main_location(ctx.attr.package_name, lib_root, f).uri,
            file = f,
        ))

    dep_kernels = [
        dep[FlutterKernelModuleInfo].kernel_info
        for dep in ctx.attr.deps
        if FlutterKernelModuleInfo in dep
    ]
    entry = _compile_flutter_entry_module(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        ctx.label.name + ".flutter_entry.kmod",
        flutter_sdk_info.platform_kernel_dill,
    )
    return _link_flutter_test_entry_module(ctx, dep_kernels, entry, output)

def compile_flutter_modular_web_kernel(
        ctx,
        flutter_sdk_info,
        tools,
        lib_root,
        packages,
        output,
        entrypoint = None,
        ui_web_stub = None,
        renderer_defines = [
            "FLUTTER_WEB_USE_SKIA=false",
            "FLUTTER_WEB_USE_SKWASM=true",
        ],
        platform_dill = None,
        target = "flutter"):
    """Compiles a `flutter_web_bundle`'s entry module and links it with dependency modules and the product platform dill.

    Args:
      ctx: The `flutter_web_bundle` rule context.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
      tools: The kernel tools struct returned by `flutter_modular_test_tools`.
      lib_root: The web app package's `lib_root` from `derive_lib_root`.
      packages: The synthesized `DartPackageInfo` list for the web app.
      output: The linked `.dill` File to produce (with product platform dill prepended).
      entrypoint: Optional generated `<name>_wrapper_main.dart` File.
      ui_web_stub: Optional generated `<name>_ui_web_stub.dart` File.
      renderer_defines: Renderer `-D` define strings (`KEY=VALUE`).
      platform_dill: Optional platform `.dill` File to compile against.
      target: Frontend/kernel target model.
    """
    sources = []
    if entrypoint != None:
        sources.append(struct(
            uri = app_scheme_location(entrypoint).uri,
            file = entrypoint,
        ))
    if ui_web_stub != None:
        sources.append(struct(
            uri = app_scheme_location(ui_web_stub).uri,
            file = ui_web_stub,
        ))
    sources.append(struct(
        uri = app_main_location(ctx.attr.package_name, lib_root, ctx.file.main).uri,
        file = ctx.file.main,
    ))
    for f in ctx.files.srcs:
        if f == ctx.file.main:
            continue
        sources.append(struct(
            uri = app_main_location(ctx.attr.package_name, lib_root, f).uri,
            file = f,
        ))

    dep_kernels = [
        dep[FlutterKernelModuleInfo].product_kernel_info
        for dep in ctx.attr.deps
        if FlutterKernelModuleInfo in dep
    ]
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    dep_outline_closure = depset(
        order = "postorder",
        transitive = [k.transitive_koutlines for k in dep_kernels],
    )
    cross_pkg_srcs = depset(
        transitive = [k.cross_pkg_srcs for k in dep_kernels],
    )
    entry = ctx.actions.declare_directory(ctx.label.name + "_icon_tree_shaking.flutter_entry.kmod")
    flutter_kernel_module_action(
        ctx,
        tools,
        sources,
        first_per_package(packages),
        dep_outline_closure,
        entry,
        defines = _kernel_worker_defines(ctx) + ["dart.vm.product=true"] + list(renderer_defines),
        exclude_non_sources = True,
        droppable = False,
        extra_inputs = cross_pkg_srcs,
        closure_excluded = depset(transitive = [k.closure_excluded for k in dep_kernels]),
        target = target,
        platform_dill = platform_dill if platform_dill != None else flutter_sdk_info.platform_kernel_dill_product,
        extra_libraries = ["ui", "nativewrappers"],
        scheme = APP_SCHEME,
        unused_inputs = True,
    )
    kernel_link_action(
        ctx,
        dep_closure,
        entry,
        output,
        platform_dill = platform_dill if platform_dill != None else flutter_sdk_info.platform_kernel_dill_product,
    )

def compile_flutter_modular_app_kernel(
        ctx,
        tools,
        lib_root,
        packages,
        output,
        platform_dill):
    """Compiles a Flutter kernel target's entry module and links it with dependency modules and `platform_dill`.

    Args:
      ctx: The rule context (`flutter_kernel_target`, etc.).
      tools: The kernel tools struct returned by `flutter_modular_test_tools`.
      lib_root: The app package's `lib_root` from `derive_lib_root`.
      packages: The synthesized `DartPackageInfo` list for the app.
      output: The linked `.dill` File to produce (with `platform_dill` prepended).
      platform_dill: The platform `.dill` File to compile and link against.
    """
    sources = [
        struct(
            uri = app_main_location(ctx.attr.package_name, lib_root, ctx.file.main).uri,
            file = ctx.file.main,
        ),
    ]
    for f in ctx.files.srcs:
        if f == ctx.file.main:
            continue
        sources.append(struct(
            uri = app_main_location(ctx.attr.package_name, lib_root, f).uri,
            file = f,
        ))

    dep_kernels = [
        dep[FlutterKernelModuleInfo].kernel_info
        for dep in ctx.attr.deps
        if FlutterKernelModuleInfo in dep
    ]
    entry = _compile_flutter_entry_module(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        ctx.label.name + ".flutter_entry.kmod",
        platform_dill,
    )
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    kernel_link_action(
        ctx,
        dep_closure,
        entry,
        output,
        platform_dill = platform_dill,
    )

FLUTTER_MODULAR_KERNEL_ATTRS = {
    "deps": attr.label_list(
        doc = "DartInfo dependencies, compiled once each by `flutter_kernel_module_aspect`.",
        providers = [DartInfo],
        aspects = [flutter_kernel_module_aspect],
        cfg = _modular_deps_transition,
    ),
    "defines": attr.string_list(
        doc = "Extra `-D` defines for the entry compile. Must stay empty: unlike the built-in rules, a custom modular kernel has no whole-program fallback, so a non-empty list fails the build. The global `//flutter:extra_dart_defines` flag is not read either (the `deps` edge above resets it to keep the entry compile consistent with the dependency modules).",
        default = [],
    ),
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
} | KERNEL_MODULE_ATTRS

FLUTTER_MODULAR_KERNEL_TOOLCHAINS = [
    "@rules_flutter//flutter:toolchain_type",
] + MODULAR_KERNEL_TOOLCHAINS

def _flutter_modular_custom_tools(ctx, deps, own_files, packages, what):
    """Resolves the debug SDK and kernel tools for a custom modular kernel, or fails.

    Unlike the built-in rules, a custom kernel has no whole-program fallback, so
    every ineligibility the built-in rules would route to `FlutterKernelCompile`
    fails here with the reason instead.

    Args:
      ctx: The custom rule context. Must provide `defines` (see
        `FLUTTER_MODULAR_KERNEL_ATTRS`).
      deps: The custom rule's dependency Targets.
      own_files: The entry's own `.dart` Files.
      packages: The `DartPackageInfo` list for the entry compile.
      what: The calling function name, for error messages.

    Returns:
      `(flutter_sdk_info, tools)` usable with `_compile_flutter_entry_module`.
    """
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info if flutter_toolchain else None
    if flutter_sdk_info == None or flutter_sdk_info.platform_kernel_dill == None:
        fail("%s: %s needs a Flutter SDK with a debug platform kernel dill" % (ctx.label, what))
    if ctx.attr.defines:
        fail("%s: %s does not accept defines (%s); the built-in rules fall back to a whole-program compile for targets with defines, but a custom modular kernel has no fallback" % (ctx.label, what, ctx.attr.defines))
    native_assets = depset(transitive = [
        dep[FlutterInfo].native_assets
        for dep in deps
        if FlutterInfo in dep
    ]).to_list()
    if native_assets:
        fail("%s: %s does not support native assets (%s); the built-in rules fall back to a whole-program compile for targets with native assets, but a custom modular kernel has no fallback" % (ctx.label, what, native_assets))
    tools = flutter_modular_test_tools(ctx, flutter_sdk_info, own_files, packages, [])
    if tools == None:
        fail("%s: %s is not eligible for modular compilation (duplicate sources or an unresolvable tool); the built-in rules fall back to a whole-program compile here, but a custom modular kernel has no fallback" % (ctx.label, what))
    return flutter_sdk_info, tools

def _custom_dep_kernels(ctx, deps, what):
    """Returns the debug `DartKernelInfo` list for a custom kernel's deps, or fails."""
    dep_kernels = [
        dep[FlutterKernelModuleInfo].kernel_info
        for dep in deps
        if FlutterKernelModuleInfo in dep
    ]
    if len(dep_kernels) != len(deps):
        fail("%s: %s needs every dep to carry FlutterKernelModuleInfo (put them under `deps` with `%s` applied); got %d of %d" % (ctx.label, what, "flutter_kernel_module_aspect", len(dep_kernels), len(deps)))
    return dep_kernels

def flutter_modular_test_kernel(ctx, *, test_uri, deps, output, use_base_dill = False):
    """Compiles a custom modular test kernel runnable by `flutter_prebuilt_test`.

    Writes a `flutter_test`-compatible bootstrap importing `test_uri` (plus the
    golden comparator when one is configured), compiles it as an entry module
    against the dependency outlines, and links it — the same protocol the
    built-in `flutter_test` rule's modular path uses. The test runs under the
    prebuilt `flutter_tester` binary with no SDK source needed at runtime.

    By default (`use_base_dill = False`, as in rules_dart's
    `modular_executable_kernel`) the link is complete: every reachable
    dependency module lands in `output`, which runs under
    `flutter_prebuilt_test(dill = ...)` with no `base_dill`. With
    `use_base_dill = True` the kernel delta-links against the `flutter_test`
    base dill instead — a smaller per-test dill sharing one SDK base across
    many tests — and the returned base dill must reach `flutter_prebuilt_test`'s
    `base_dill`, exactly as a `flutter_test` kernel's `test_base_kernel` must:
    the delta is incomplete without it.

    Args:
      ctx: The custom rule context. Must merge `FLUTTER_MODULAR_KERNEL_ATTRS`
        (and `FLUTTER_TEST_BOOTSTRAP_ATTRS` when the caller wants a configurable
        golden comparator) and resolve `FLUTTER_MODULAR_KERNEL_TOOLCHAINS`.
        Pass `ctx.attr.deps` as `deps` so the eligibility check sees the same
        closure the aspect ran over.
      test_uri: The `package:` URI of the test library the bootstrap imports.
      deps: The custom rule's dependency Targets.
      output: The linked test `.dill` File to produce.
      use_base_dill: When True, delta-link against the shared `flutter_test`
        base dill and return it; otherwise link a complete kernel and return
        None.

    Returns:
      The `base_dill` File linked against when `use_base_dill` is True and a
      dependency provides one (`flutter_prebuilt_test`'s `base_dill`), or
      `None` — always `None` with the default complete link.
    """
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_modular_bootstrap.dart")
    staged_comparator = flutter_test_bootstrap_action(ctx, test_uri, bootstrap)
    sources = [
        struct(uri = app_scheme_location(bootstrap).uri, file = bootstrap),
    ]
    own_files = [bootstrap]
    if staged_comparator != None:
        sources.append(struct(uri = app_scheme_location(staged_comparator).uri, file = staged_comparator))
        own_files.append(staged_comparator)
    packages = collect_packages(deps)
    dep_kernels = _custom_dep_kernels(ctx, deps, "flutter_modular_test_kernel")
    flutter_sdk_info, tools = _flutter_modular_custom_tools(
        ctx,
        deps,
        own_files,
        packages,
        "flutter_modular_test_kernel",
    )
    entry = _compile_flutter_entry_module(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        ctx.label.name + ".flutter_entry.kmod",
        flutter_sdk_info.platform_kernel_dill,
    )
    if use_base_dill:
        return _link_flutter_test_entry_module(ctx, dep_kernels, entry, output)
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    kernel_link_action(ctx, dep_closure, entry, output)
    return None

def flutter_modular_app_kernel(ctx, *, main, package_name, srcs, deps, output, use_base_dill = False):
    """Compiles a custom modular app kernel: the app's own sources plus dependency modules.

    Synthesizes the `package:<package_name>/` mapping for `main`/`srcs` (the same
    mapping the built-in app rules build), compiles them as the entry module
    against the dependency outlines, and links everything with the debug
    `platform_kernel_dill` prepended — the same protocol the built-in
    `flutter_kernel_target` modular path uses.

    By default (`use_base_dill = False`, as in rules_dart's
    `modular_executable_kernel`) the link is complete. With `use_base_dill =
    True` the kernel delta-links against a shared base dill when a dependency
    provides one, and the returned base dill must be kept alongside the kernel
    at run time.

    Args:
      ctx: The custom rule context. Must merge `FLUTTER_MODULAR_KERNEL_ATTRS`
        and resolve `FLUTTER_MODULAR_KERNEL_TOOLCHAINS`. Pass `ctx.attr.deps`
        as `deps` so the eligibility check sees the same closure the aspect ran
        over.
      main: The app's entry-point File.
      package_name: The `package:` name `main`/`srcs` are reachable under.
      srcs: The app's own `.dart` Files (may include `main`).
      deps: The custom rule's dependency Targets.
      output: The linked app `.dill` File to produce.
      use_base_dill: When True, delta-link against the shared base dill and
        return it; otherwise link a complete kernel and return None.

    Returns:
      The shared `base_dill` File if `use_base_dill` is True and a dependency
      provides one, or None.
    """
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    packages = synthesize_app_package(
        ctx.label,
        collect_packages(deps),
        package_name,
        lib_root,
        "",
    )
    sources = [
        struct(
            uri = app_main_location(package_name, lib_root, main).uri,
            file = main,
        ),
    ]
    own_files = [main]
    for f in srcs:
        if f == main:
            continue
        sources.append(struct(
            uri = app_main_location(package_name, lib_root, f).uri,
            file = f,
        ))
        own_files.append(f)
    dep_kernels = _custom_dep_kernels(ctx, deps, "flutter_modular_app_kernel")
    flutter_sdk_info, tools = _flutter_modular_custom_tools(
        ctx,
        deps,
        own_files,
        packages,
        "flutter_modular_app_kernel",
    )
    entry = _compile_flutter_entry_module(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        ctx.label.name + ".flutter_entry.kmod",
        flutter_sdk_info.platform_kernel_dill,
    )
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    base_dill = None
    base_keys = None
    if use_base_dill:
        base_kmods = depset()
        for k in dep_kernels:
            kd = getattr(k, "base_dill", None)
            kk = getattr(k, "base_keys", None)
            if kd != None and kk != None:
                base_dill = kd
                base_keys = kk
                base_kmods = getattr(k, "base_kmods", depset())
                break
        if base_dill != None and base_keys != None:
            base_kmod_paths = {f.path: True for f in base_kmods.to_list()}
            if base_kmod_paths:
                dep_closure = depset(
                    [f for f in dep_closure.to_list() if f.path not in base_kmod_paths],
                    order = "postorder",
                )
    kernel_link_action(
        ctx,
        dep_closure,
        entry,
        output,
        platform_dill = flutter_sdk_info.platform_kernel_dill,
        base_keys = base_keys,
    )
    return base_dill
