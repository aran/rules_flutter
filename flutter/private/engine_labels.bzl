"""The labels of the engine contract's slices.

An engine source is a repository with its slices at these labels
(`contract_slices` below; README.md, "Writing an engine source"). The toolchains of every SDK
are written against them, so the stock release and any other source are used
the same way.
"""

load("//flutter/private:toolchains_repo.bzl", "CROSS_COMPILATION_PAIRS", "DESKTOP_ENGINE_PLATFORMS", "HOST_PLATFORMS")

ENGINE_MODES = ["debug", "profile", "release"]

# The slice directory of a desktop engine, by the platform string of its target.
_DESKTOP_ENGINE_DIR = {
    "darwin-x64": "macos",
    "darwin-arm64": "macos",
    "linux-x64": "linux-x64",
    "linux-arm64": "linux-arm64",
    "windows-x64": "windows-x64",
}

# The target a host's own gen_snapshot compiles for.
_NATIVE_TARGET = {
    "darwin-arm64": "macos-arm64",
    "darwin-x64": "macos-x64",
    "linux-x64": "linux-x64",
    "linux-arm64": "linux-arm64",
    "windows-x64": "windows-x64",
}

# The targets of the web slice's package (`//web`) besides the `flutter_web_sdk`
# slice `sdk`: the files a web application names, each an alias or a link into
# the web SDK's tree. `@flutter_web_sdk` follows the selected SDK with an alias
# to each.
WEB_SLICE_FILES = {
    "files": "The whole web SDK tree: the `flutter_web_sdk` directory and the Dart SDK's `lib` it includes.",
    "dart2wasm_platform.dill": "`kernel/dart2wasm_platform.dill`.",
    "dart2js_platform.dill": "`kernel/dart2js_platform.dill`.",
    "ddc_outline.dill": "`kernel/ddc_outline.dill`.",
    "libraries.json": "The web SDK's `libraries.json`.",
    "ddc_dart_sdk.js": "`kernel/ddc/canary/dart_sdk.js`.",
    "ddc_module_loader.js": "The Dart SDK's `lib/dev_compiler/ddc/ddc_module_loader.js`.",
    "dart_stack_trace_mapper.js": "The Dart SDK's `lib/dev_compiler/web/dart_stack_trace_mapper.js`.",
}

def host_tools_label(engine, host):
    """The label of the host tools slice.

    Args:
        engine: The engine repository, as a label prefix (`@repo`).
        host: A `HOST_PLATFORMS` key.

    Returns:
        The label string.
    """
    return "{}//host/{}:tools".format(engine, host)

def kernel_label(engine, release):
    """The label of a platform kernel slice.

    Args:
        engine: The engine repository, as a label prefix.
        release: Whether the release (product) kernel is wanted, not the debug one.

    Returns:
        The label string.
    """
    return "{}//kernel/{}:platform".format(engine, "release" if release else "debug")

def engine_label(engine, platform, mode):
    """The label of an engine slice.

    Args:
        engine: The engine repository, as a label prefix.
        platform: The target's platform string (`darwin-x64`, `linux-arm64`,
            `ios-arm64`, `android-x64`, ...).
        mode: `debug`, `profile` or `release`.

    Returns:
        The label string.
    """
    return "{}//{}/{}:engine".format(engine, engine_dir(platform), mode)

def engine_dir(platform):
    """The slice directory of a target platform's engine.

    Args:
        platform: The target's platform string.

    Returns:
        `macos`, `linux-<arch>`, `windows-<arch>`, `ios` or `android-<arch>`.
    """
    if platform.startswith("ios-"):
        return "ios"
    if platform.startswith("android-"):
        return platform
    return _DESKTOP_ENGINE_DIR[platform]

# The CPU name the engine contract uses (`FlutterEngineInfo.cpus`) for each Android target architecture.
_ANDROID_ENGINE_CPU = {
    "arm": "arm",
    "arm64": "arm64",
    "x64": "x86_64",
}

def android_engine_cpu(arch):
    """The CPU an Android engine of an architecture contains, as `FlutterEngineInfo.cpus` names it.

    Args:
        arch: The architecture part of the target (`arm64`, `x64`).

    Returns:
        `arm64`, `x86_64`, ...
    """
    if arch not in _ANDROID_ENGINE_CPU:
        fail("No engine CPU is named for the Android architecture \"%s\"." % arch)
    return _ANDROID_ENGINE_CPU[arch]

def android_arches():
    """The CPUs Android engines are published for.

    Returns:
        The architecture parts (`arm64`, `x64`, ...) of the Android targets,
        so that one more ABI is one more entry of `TARGET_PLATFORMS`.
    """
    arches = []
    for targets in CROSS_COMPILATION_PAIRS.values():
        for target in targets:
            if target.startswith("android-") and target.split("-")[1] not in arches:
                arches.append(target.split("-")[1])
    return arches

def desktop_engine_dir(platform):
    """The slice directory of a desktop platform's engine.

    Args:
        platform: The target's platform string.

    Returns:
        `macos`, `linux-<arch>` or `windows-<arch>`.
    """
    return _DESKTOP_ENGINE_DIR[platform]

def native_target(host):
    """The target a host's own gen_snapshot compiles for.

    Args:
        host: A `HOST_PLATFORMS` key.

    Returns:
        `macos-arm64`, `linux-x64`, ...
    """
    return _NATIVE_TARGET[host]

def gen_snapshot_label(engine, target, mode, host):
    """The label of a gen_snapshot slice.

    Args:
        engine: The engine repository, as a label prefix.
        target: `macos-<arch>`, `ios-arm64`, `android-<arch>`, `linux-<arch>` or `windows-x64`.
        mode: `profile` or `release`.
        host: The `HOST_PLATFORMS` key of the host it runs on.

    Returns:
        The label string.
    """
    return "{}//{}/{}:gen_snapshot_{}".format(engine, target, mode, host)

def mode_select(by_mode, debug = None):
    """A `select()` expression choosing a value by build mode.

    Args:
        by_mode: A dict with `profile` and `release` label strings.
        debug: The value under `-c dbg`: a label string, or None for no value.

    Returns:
        The attribute value as BUILD source text.
    """
    return """select({{
        "@rules_flutter//flutter/private:dbg": {debug},
        "@rules_flutter//flutter/private:profile": "{profile}",
        "//conditions:default": "{release}",
    }})""".format(
        debug = '"{}"'.format(debug) if debug else "None",
        profile = by_mode["profile"],
        release = by_mode["release"],
    )

def contract_slices():
    """Every slice of the contract that the toolchains name: package path to its target names.

    A source that serves only some of them defines the rest as missing slices,
    so that a toolchain which is never used never fails.

    Returns:
        A dict from package path (`macos/release`) to the list of its slice targets.
    """
    slices = {}
    for host in HOST_PLATFORMS:
        slices["host/" + host] = ["tools"]
    slices["kernel/debug"] = ["platform"]
    slices["outline_tool"] = ["outline_tool"]
    slices["kernel/release"] = ["platform"]
    for platform in DESKTOP_ENGINE_PLATFORMS:
        directory = desktop_engine_dir(platform)
        for mode in ENGINE_MODES:
            slices.setdefault("{}/{}".format(directory, mode), []).append("engine")
    for mode in ENGINE_MODES:
        slices["macos/" + mode].append("xcframework")
    for targets in CROSS_COMPILATION_PAIRS.values():
        for target in targets:
            for mode in ENGINE_MODES:
                packages = slices.setdefault("{}/{}".format(engine_dir(target), mode), [])
                if "engine" not in packages:
                    packages.append("engine")
    slices["web"] = ["sdk"] + sorted(WEB_SLICE_FILES.keys())
    for host in HOST_PLATFORMS:
        target = native_target(host)
        for mode in ["profile", "release"]:
            slices.setdefault("{}/{}".format(target, mode), []).append("gen_snapshot_" + host)
    for host, targets in CROSS_COMPILATION_PAIRS.items():
        for target in targets:
            for mode in ["profile", "release"]:
                slices.setdefault("{}/{}".format(target, mode), []).append("gen_snapshot_" + host)
    return slices
