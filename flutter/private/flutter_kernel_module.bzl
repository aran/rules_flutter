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
load("@rules_dart//dart:providers.bzl", "DartInfo", "DartKernelInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "KERNEL_MODULE_ATTRS",
    "MODULAR_KERNEL_TOOLCHAINS",
    _DART_MODULAR_KERNEL_ATTRS = "MODULAR_KERNEL_ATTRS",
    "collect_transitive_srcs",
    "duplicated_source",
    "first_per_package",
    "kernel_link_action",
    "kernel_module_action",
    "kernel_packages_consistent",
    "kernel_tools_for",
    "library_source_uri",
    "modular_kernel_eligible",
    "no_kernel_module",
)
load(
    "//flutter/private:app_entrypoint.bzl",
    "APP_SCHEME",
    "app_main_location",
    "app_scheme_location",
    "package_lib_prefix",
)

FlutterKernelModuleInfo = provider(
    doc = "Modular Flutter kernel info for a DartInfo target.",
    fields = {
        "kernel_info": "DartKernelInfo compiled for the Flutter target and patched SDK.",
    },
)

MODULAR_KERNEL_ATTRS = _DART_MODULAR_KERNEL_ATTRS | {
    "_extra_dart_defines": attr.label(
        default = Label("//flutter:extra_dart_defines"),
        providers = [BuildSettingInfo],
    ),
    "_extra_dart_defines_from_dart": attr.label(
        default = Label("@rules_dart//dart:extra_dart_defines"),
        providers = [BuildSettingInfo],
    ),
}

def _global_extra_defines(ctx):
    defines = []
    if hasattr(ctx.attr, "_extra_dart_defines") and ctx.attr._extra_dart_defines != None:
        defines.extend(ctx.attr._extra_dart_defines[BuildSettingInfo].value)
    if hasattr(ctx.attr, "_extra_dart_defines_from_dart") and ctx.attr._extra_dart_defines_from_dart != None:
        defines.extend(ctx.attr._extra_dart_defines_from_dart[BuildSettingInfo].value)
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

def _own_package_record(info):
    """Returns the `DartPackageInfo` for the package a `DartInfo` itself owns."""
    if not info.package_name:
        return None
    for pkg in info.transitive_packages.to_list():
        if pkg.package_name == info.package_name and pkg.lib_root == info.lib_root:
            return pkg
    return None

def _flutter_kernel_module_aspect_impl(target, ctx):
    if DartInfo not in target:
        return [FlutterKernelModuleInfo(kernel_info = no_kernel_module())]

    enabled = ctx.attr._modular_kernel[BuildSettingInfo].value
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info if flutter_toolchain else None
    tools = kernel_tools_for(ctx)

    dart_info = target[DartInfo]
    package_name = dart_info.package_name
    lib_root = dart_info.lib_root
    own_record = _own_package_record(dart_info)
    srcs_dir = getattr(ctx.rule.attr, "srcs_dir", None)
    has_srcs_attr = hasattr(ctx.rule.attr, "srcs")
    own_srcs = getattr(ctx.rule.files, "srcs", [])
    rule_deps = getattr(ctx.rule.attr, "deps", [])
    if type(rule_deps) != "list":
        rule_deps = [rule_deps]

    opaque = bool(srcs_dir)
    if not has_srcs_attr and dart_info.transitive_srcs.to_list() != [] and len(rule_deps) == 0:
        opaque = True
    prefix = package_lib_prefix(lib_root)
    if own_srcs and (not package_name or own_record == None or any([not f.short_path.startswith(prefix) for f in own_srcs])):
        opaque = True

    if opaque or not enabled or _has_comma_defines(ctx) or tools == None or flutter_sdk_info == None or flutter_sdk_info.platform_kernel_dill == None:
        return [FlutterKernelModuleInfo(kernel_info = no_kernel_module())]

    dep_kernels = [
        dep[FlutterKernelModuleInfo].kernel_info
        for dep in rule_deps
        if type(dep) == "Target" and FlutterKernelModuleInfo in dep
    ]
    if len(dep_kernels) != len(rule_deps):
        return [FlutterKernelModuleInfo(kernel_info = no_kernel_module())]

    raw = depset(
        transitive = [
            dep[DartInfo].transitive_packages
            for dep in rule_deps
            if type(dep) == "Target" and DartInfo in dep
        ],
    ).to_list()
    records = ([own_record] if own_record != None else []) + raw
    modular = kernel_packages_consistent(records) and all([k.modular for k in dep_kernels])
    if not modular:
        return [FlutterKernelModuleInfo(kernel_info = no_kernel_module())]

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
        depset(own_srcs, transitive = [collect_transitive_srcs(rule_deps)])
        if has_cross_pkg_cycle
        else depset(transitive = [k.cross_pkg_srcs for k in dep_kernels])
    )
    owned = depset(
        [(str(target.label), f.short_path) for f in own_srcs],
        transitive = [k.owned for k in dep_kernels],
    )
    edges = depset(
        [(str(target.label), str(dep.label)) for dep in rule_deps],
        transitive = [k.edges for k in dep_kernels],
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
    if not own_srcs:
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
            ),
        ]

    kmod = ctx.actions.declare_directory(target.label.name + ".flutter.kmod")
    koutline = ctx.actions.declare_directory(target.label.name + ".flutter.koutline")
    sources = [
        struct(uri = library_source_uri(package_name, lib_root, f.short_path), file = f)
        for f in own_srcs
    ]
    excluded = kernel_module_action(
        ctx,
        tools,
        sources,
        first_per_package(records),
        dep_outline_closure,
        kmod,
        koutline = koutline,
        defines = _kernel_worker_defines(ctx),
        exclude_non_sources = True,
        droppable = True,
        closure_excluded = upstream_excluded,
        target = "flutter",
        platform_dill = flutter_sdk_info.platform_kernel_dill,
        extra_libraries = ["ui", "nativewrappers"],
        scheme = APP_SCHEME,
    )
    if package_name == "flutter_test" and hasattr(ctx.executable, "_kernel_link"):
        base_dill = ctx.actions.declare_file(target.label.name + ".flutter_base.dill")
        base_keys = ctx.actions.declare_file(target.label.name + ".flutter_base.keys")
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
        "_extra_dart_defines_from_dart": attr.label(
            default = Label("@rules_dart//dart:extra_dart_defines"),
            providers = [BuildSettingInfo],
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ] + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles each DartInfo library in a flutter_test closure into a modular .flutter.kmod directory.",
)

def flutter_modular_test_tools(ctx, flutter_sdk_info, own_files, packages, native_assets_list):
    """Decides whether a `flutter_test` compiles modularly, and with which tools.

    Args:
      ctx: The `flutter_test` rule context.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
      own_files: The test's own `.dart` files (`[ctx.file.main] + ctx.files.srcs`).
      packages: The synthesized `DartPackageInfo` list for the test.
      native_assets_list: Resolved native code assets for the test.

    Returns:
      The kernel tools struct from `kernel_tools_for`, or `None` when the test
      must fall back to whole-program `FlutterKernelCompile`.
    """
    enabled = ctx.attr._modular_kernel[BuildSettingInfo].value if hasattr(ctx.attr, "_modular_kernel") else False
    if not enabled or _has_comma_defines(ctx) or flutter_sdk_info == None or flutter_sdk_info.platform_kernel_dill == None:
        return None
    tools = kernel_tools_for(ctx)
    if tools == None:
        return None

    dep_kernels = [
        dep[FlutterKernelModuleInfo].kernel_info
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
        same_sdk = True,
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

    Args:
      ctx: The `flutter_test` rule context.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
      tools: The kernel tools struct returned by `flutter_modular_test_tools`.
      bootstrap: The generated `<name>_bootstrap.dart` File (entry point).
      staged_comparator: Optional staged `<name>.golden_comparator.dart` File.
      lib_root: The test package's `lib_root` from `derive_lib_root`.
      packages: The synthesized `DartPackageInfo` list for the test.
      output: The linked `.dill` File to produce.
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
    entry = ctx.actions.declare_directory(ctx.label.name + ".flutter_entry.kmod")
    kernel_module_action(
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
        closure_excluded = depset(transitive = [k.closure_excluded for k in dep_kernels]),
        target = "flutter",
        platform_dill = flutter_sdk_info.platform_kernel_dill,
        extra_libraries = ["ui", "nativewrappers"],
        scheme = APP_SCHEME,
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
    kernel_link_action(ctx, link_dep_closure, entry, output, base_keys = base_keys)
    return base_dill

def compile_flutter_modular_web_kernel(
        ctx,
        flutter_sdk_info,
        tools,
        lib_root,
        packages,
        output):
    """Compiles a `flutter_web_bundle`'s entry module and links it with dependency modules and the product platform dill.

    Args:
      ctx: The `flutter_web_bundle` rule context.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
      tools: The kernel tools struct returned by `flutter_modular_test_tools`.
      lib_root: The web app package's `lib_root` from `derive_lib_root`.
      packages: The synthesized `DartPackageInfo` list for the web app.
      output: The linked `.dill` File to produce (with product platform dill prepended).
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
    kernel_module_action(
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
        closure_excluded = depset(transitive = [k.closure_excluded for k in dep_kernels]),
        target = "flutter",
        platform_dill = flutter_sdk_info.platform_kernel_dill,
        extra_libraries = ["ui", "nativewrappers"],
        scheme = APP_SCHEME,
    )
    kernel_link_action(
        ctx,
        dep_closure,
        entry,
        output,
        platform_dill = flutter_sdk_info.platform_kernel_dill_product,
    )

def compile_flutter_modular_app_kernel(
        ctx,
        flutter_sdk_info,
        tools,
        lib_root,
        packages,
        output,
        platform_dill):
    """Compiles a Flutter kernel target's entry module and links it with dependency modules and `platform_dill`.

    Args:
      ctx: The rule context (`flutter_kernel_target`, etc.).
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
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
    entry = ctx.actions.declare_directory(ctx.label.name + ".flutter_entry.kmod")
    kernel_module_action(
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
        closure_excluded = depset(transitive = [k.closure_excluded for k in dep_kernels]),
        target = "flutter",
        platform_dill = platform_dill,
        extra_libraries = ["ui", "nativewrappers"],
        scheme = APP_SCHEME,
    )
    kernel_link_action(
        ctx,
        dep_closure,
        entry,
        output,
        platform_dill = platform_dill,
    )
