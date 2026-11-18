"""What a program ships, through its packages' link hooks or not.

Native and web applications choose it the same way, as `flutter build`
does for every target: in a release or profile build every package with a
`hook/link.dart` has it run over the uses the compiler recorded, and a hook
receives its own package's declared assets and decides which ship; a debug
build runs no hook and ships every package's declared assets. What differs
between targets is only which compile records the uses. rules_dart's
`dart_program_assets_actions` is the operation; this module decides when it
links and hands it the program.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo", "DartRecordedUsesInfo")
load("@rules_dart//dart:utils.bzl", "dart_program_assets_actions", "program_kernel_code_assets", "program_packages")
load("//flutter/private:common.bzl", "program_package", "program_package_files")
load("//flutter/private:constants.bzl", "ANDROID_MIN_SDK_VERSION", "IOS_MINIMUM_OS_VERSION", "MACOS_MINIMUM_OS_VERSION")

visibility("//flutter/...")

def link_hooks_plan(program, deps, links):
    """Whether a program is linked, decided before its compile.

    The compile that records the uses has to be told to, so this is asked
    first, and `program_assets` takes the answer after.

    Every package of the program counts, its own among them: a link hook
    of the app's package runs whether or not a library of that package is
    in `deps`, as upstream's hooks runner plans the root package with the
    rest. A package that links native code into each program keeps what
    the uses need, so it counts too.

    Args:
        program: The program, from `flutter_program_inputs`.
        deps: The `deps` whose closure is linked (a web branch's, on web).
        links: Whether the build mode links: not a debug build.

    Returns:
        A struct: `runs` (bool: the compile records uses and the program is
        linked over them).
    """
    return struct(
        runs = links and any([
            getattr(pkg, "link_hook", None) != None or bool(getattr(pkg, "linked_code_assets", ()))
            for pkg in program_packages(program_package(program), _dart_deps(deps))
        ]),
    )

def program_assets(ctx, program, deps, plan, recorded_uses, name, code_config = None, code_assets = []):
    """What a program ships.

    Linked, the data assets are what the package link hooks emit over
    `recorded_uses` and the declared assets of packages without a hook;
    unlinked, every package's declared assets. The program's own package is
    one of its packages either way.

    Args:
        ctx: Rule context carrying `program_assets_attrs()`, the
            `PROGRAM_ASSETS_TOOLCHAINS`, `PORTABLE_EXEC_GROUPS` and the `cpp`
            fragment.
        program: The program, from `flutter_program_inputs`.
        deps: The `deps` whose closure is linked, as given to `link_hooks_plan`.
        plan: What `link_hooks_plan` returned.
        recorded_uses: The recorded-uses JSON File, which the hooks read when
            `plan.runs`; None when nothing reads it.
        name: Prefix for the outputs, unique within the package.
        code_config: What every link hook is told of the target's code
            assets (`native_code_config(...)` for a native one), or None for the
            web, which loads none.
        code_assets: `DartCodeAssetInfo` the target names itself, which
            replace any of its packages' under the same id.

    Returns:
        A struct: `info` (the program's `DartProgramAssetsInfo`),
        `validation_outputs` (Files for an `_validation` output group, so
        every hook runs whenever the target builds, even one that emits
        nothing) and `code_assets` (every `DartCodeAssetInfo` the program
        can load, known at analysis time as the kernel compile's
        `--native-assets` needs them: those that ship and those a link hook
        chooses among).
    """
    package = program_package(program)
    uses = None
    if plan.runs:
        uses = DartRecordedUsesInfo(
            file = recorded_uses,
            kind = "aot",
            package = package.metadata if package != None else None,
            package_files = program_package_files(program),
        )
    result = dart_program_assets_actions(
        ctx,
        package,
        _dart_deps(deps),
        name,
        recorded_uses = uses,
        code_config = code_config,
        code_assets = code_assets,
    )
    return struct(
        info = result.info,
        validation_outputs = result.validation_outputs,
        code_assets = program_kernel_code_assets(result.info),
    )

def native_code_config(target_os, target_arch, is_simulator, minimum_os_version):
    """Upstream's code-asset configuration of a native Flutter target.

    What `flutter build` tells every hook at `config.extensions.code_assets`:
    the target, a dynamic link-mode preference, and the iOS, macOS or
    Android facts its `CodeConfig` exposes for those targets.

    Args:
        target_os: "android", "ios", "linux", "macos" or "windows".
        target_arch: "arm64", "x64" or "arm".
        is_simulator: Whether an iOS build is for the simulator.
        minimum_os_version: The app's Apple deployment target, or "" for
            the default.

    Returns:
        The `code_config` to give `program_assets`.
    """
    if not target_arch:
        fail("The target architecture of this %s build is unknown, and a link hook is told it." % target_os)
    config = {
        "link_mode_preference": "dynamic",
        "target_architecture": target_arch,
        "target_os": target_os,
    }
    if target_os == "ios":
        config["ios"] = {
            "target_sdk": "iphonesimulator" if is_simulator else "iphoneos",
            "target_version": int(_major(minimum_os_version or IOS_MINIMUM_OS_VERSION)),
        }
    elif target_os == "macos":
        config["macos"] = {"target_version": int(_major(minimum_os_version or MACOS_MINIMUM_OS_VERSION))}
    elif target_os == "android":
        config["android"] = {"target_ndk_api": int(ANDROID_MIN_SDK_VERSION)}
    return config

def _major(version):
    return version.partition(".")[0]

def _dart_deps(deps):
    return [dep for dep in deps if DartInfo in dep]
