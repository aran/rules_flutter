"""The stock release's engine, as an engine source.

A repository whose slices (the contract of `@rules_flutter//flutter:engine.bzl`) are
rules over the files of the lazily fetched repositories that download the
official artifacts: `<name>_<host>` (host tools), `<name>_desktop_engine_*`
(the desktop engines and, for Linux and Windows, their gen_snapshot),
`<name>_cross_*` (the Android gen_snapshot), the iOS engine repository (iOS
gen_snapshot) and the macOS profile repositories. The slice targets name those
files by label, so fetching this repository fetches only the patched SDK; a
slice's files are fetched when a build uses it.

iOS and Android engines are the lazily fetched `<name>_stock_ios_engine`
(release), `<name>_stock_ios_engine_debug` and
`<name>_stock_android_engine_<arch>` repositories' files, with the profile
engines in repositories of their own.

The patched SDK is the one download here: it is the same for every host, so one
copy serves them all.
"""

load("//flutter/private:artifact_urls.bzl", "engine_artifact_url")
load("//flutter/private:constants.bzl", "ANDROID_ABI_FOR_ARCH")
load("//flutter/private:engine_helpers.bzl", "dart_binary_name", "dartaotruntime_binary_name", "gen_snapshot_binary_name")
load("//flutter/private:engine_labels.bzl", "ENGINE_MODES", "android_arches", "android_engine_cpu", "desktop_engine_dir", "native_target")
load("//flutter/private:out_dir_web.bzl", "WEB_TREE_FILES")
load("//flutter/private:pinned.bzl", "pinned")
load("//flutter/private:toolchains_repo.bzl", "CROSS_COMPILATION_PAIRS", "DESKTOP_ENGINE_PLATFORMS", "HOST_PLATFORMS")
load("//flutter/private:versions.bzl", "FLUTTER_VERSIONS")

visibility("//flutter/...")

_LOAD = 'load("@rules_flutter//flutter:engine.bzl", "flutter_android_engine_slice", "flutter_gen_snapshot", "flutter_host_tools", "flutter_ios_engine_slice", "flutter_linux_engine_slice", "flutter_macos_engine_slice", "flutter_platform_kernel", "flutter_web_sdk", "flutter_windows_engine_slice")\n\n'

_ENGINE_RULES = {
    "macos": "flutter_macos_engine_slice",
    "linux": "flutter_linux_engine_slice",
    "windows": "flutter_windows_engine_slice",
}

def _dict(d):
    return "{" + ", ".join(['"{}": "{}"'.format(k, v) for k, v in sorted(d.items())]) + "}"

def _host_tools(host, repo, provenance):
    meta = HOST_PLATFORMS[host]
    exe = ".exe" if meta.os == "windows" else ""
    return """flutter_host_tools(
    name = "tools",
    host_os = "{os}",
    host_arch = "{arch}",
    dart_sdk = "@{repo}//:dart_sdk",
    dart = "@{repo}//:dart-sdk/bin/{dart}",
    dartaotruntime = "@{repo}//:dart-sdk/bin/{dartaotruntime}",
    frontend_server = "@{repo}//:dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot",
    kernel_worker = "@{repo}//:dart-sdk/bin/snapshots/kernel_worker_aot.dart.snapshot",
    dart_libraries_json = "@{repo}//:dart-sdk/lib/libraries.json",
    dart_platform_dill = "@{repo}//:dart-sdk/lib/_internal/vm_platform_strong.dill",
    flutter_tester = "@{repo}//:host-tools/flutter_tester{exe}",
    icu_data = "@{repo}//:host-tools/icudtl.dat",
    vm_isolate_snapshot = "@{repo}//:host-tools/vm_isolate_snapshot.bin",
    isolate_snapshot = "@{repo}//:host-tools/isolate_snapshot.bin",
    impellerc = "@{repo}//:host-tools/impellerc{exe}",
    shader_lib = "@{repo}//:shader_lib_files",
    shader_include_dir = "host-tools/shader_lib",
    font_subset = "@{repo}//:font-subset-tools/font-subset{exe}",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(
        os = meta.os,
        arch = meta.arch,
        repo = repo,
        dart = dart_binary_name(host),
        dartaotruntime = dartaotruntime_binary_name(host),
        exe = exe,
        provenance = _dict(provenance),
    )

def _kernel(top, provenance):
    return """flutter_platform_kernel(
    name = "platform",
    platform_dill = "{top}/platform_strong.dill",
    outline_dill = "{top}/vm_outline_strong.dill",
    files = ":files",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)

filegroup(
    name = "files",
    srcs = glob(["{top}/**"]),
)
""".format(top = top, provenance = _dict(provenance))

def _engine(platform, mode, repo, provenance):
    os = platform.split("-")[0]
    os = {"darwin": "macos"}.get(os, os)
    binary = {
        "macos": "engine/FlutterMacOS.framework/Versions/A/FlutterMacOS",
        "linux": "engine/libflutter_linux_gtk.so",
        "windows": "engine/flutter_windows.dll",
    }[os]
    cpus = ["arm64", "x86_64"] if os == "macos" else ["arm64" if platform.endswith("arm64") else "x86_64"]
    return """{rule}(
    name = "engine",
    mode = "{mode}",
    cpus = {cpus},
    files = "@{repo}//:engine_{mode}_library",
    binary = "@{repo}//:{binary}",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(
        rule = _ENGINE_RULES[os],
        mode = mode,
        cpus = cpus,
        repo = repo,
        binary = binary,
        provenance = _dict(provenance),
    )

def _macos_xcframework(repo, mode, provenance):
    return """flutter_macos_engine_slice(
    name = "xcframework",
    mode = "{mode}",
    cpus = ["arm64", "x86_64"],
    files = "@{repo}//:xcframework",
    binary = "@{repo}//:FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework/Versions/A/FlutterMacOS",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(mode = mode, repo = repo, provenance = _dict(provenance))

# The platform directories of the iOS release's xcframeworks: the device, and
# the simulator whose arm64 and x86_64 binaries are one universal binary.
_IOS_XCFRAMEWORK_SLICES = ["ios-arm64", "ios-arm64_x86_64-simulator"]

def _ios_engine(name, mode, provenance):
    """The iOS engine of one mode: the simulator's under debug, the device's otherwise."""
    stock = "{}_stock_ios_engine".format(name)
    if mode == "debug":
        files = "@{}_debug//:Flutter_xcframework".format(stock)
        binary = "@{}_debug//:Flutter.xcframework/ios-arm64_x86_64-simulator/Flutter.framework/Flutter".format(stock)
    elif mode == "profile":
        profile = "{}_ios_engine_profile".format(name)
        files = "@{}//:Flutter_xcframework_profile".format(profile)
        binary = "@{}//:Flutter.xcframework/ios-arm64/Flutter.framework/Flutter".format(profile)
    else:
        files = "@{}//:Flutter_xcframework".format(stock)
        binary = "@{}//:Flutter.xcframework/ios-arm64/Flutter.framework/Flutter".format(stock)
    return """flutter_ios_engine_slice(
    name = "engine",
    mode = "{mode}",
    cpus = ["arm64", "x86_64"],
    files = "{files}",
    binary = "{binary}",
    xcframework_slices = {slices},
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(
        mode = mode,
        files = files,
        binary = binary,
        slices = _IOS_XCFRAMEWORK_SLICES,
        provenance = _dict(provenance),
    )

def _android_engine(name, arch, mode, provenance):
    """The Android engine of one ABI and mode: its `flutter.jar`, whose `libflutter.so` is the binary."""
    if mode == "debug":
        jar = "@{}_stock_android_engine_{}//:debug/flutter.jar".format(name, arch)
    elif mode == "profile":
        jar = "@{}_android_engine_{}_profile//:flutter.jar".format(name, arch)
    else:
        jar = "@{}_stock_android_engine_{}//:flutter.jar".format(name, arch)
    return """flutter_android_engine_slice(
    name = "engine",
    mode = "{mode}",
    cpus = ["{cpu}"],
    files = "{jar}",
    binary = "{jar}",
    binary_entry = "lib/{abi}/libflutter.so",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(
        mode = mode,
        cpu = android_engine_cpu(arch),
        jar = jar,
        abi = ANDROID_ABI_FOR_ARCH[arch],
        provenance = _dict(provenance),
    )

def _gen_snapshot(host, mode, cpu, label, provenance):
    return """flutter_gen_snapshot(
    name = "gen_snapshot_{host}",
    binary = "{label}",
    target_cpu = "{cpu}",
    mode = "{mode}",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(host = host, label = label, cpu = cpu, mode = mode, provenance = _dict(provenance))

def _web_sdk(name, provenance):
    """The web SDK slice, over the release's web SDK repository and its Dart SDK for the files `libraries.json` includes."""
    repo = "@{}_stock_web_sdk//:".format(name)
    text = """alias(
    name = "files",
    actual = "{repo}web_sdk",
    visibility = ["//visibility:public"],
)
""".format(repo = repo)
    for target, path in sorted(WEB_TREE_FILES.items()):
        text += """
alias(
    name = "{target}",
    actual = "{repo}{path}",
    visibility = ["//visibility:public"],
)
""".format(target = target, repo = repo, path = path)
    return text + """
flutter_web_sdk(
    name = "sdk",
    files = ":files",
    dart2js_platform_dill = ":dart2js_platform.dill",
    dart2wasm_platform_dill = ":dart2wasm_platform.dill",
    ddc_outline_dill = ":ddc_outline.dill",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(provenance = _dict(provenance))

def _sky_engine(name):
    """The `sky_engine` package: aliases into the release's `sky_engine.zip` repository."""
    return "".join(["""alias(
    name = "{target}",
    actual = "@{name}_stock_sky_engine//sky_engine:{target}",
    visibility = ["//visibility:public"],
)
""".format(name = name, target = target) for target in ["sky_engine", "LICENSE"]])

def stock_engine_packages(name, provenance):
    """The packages of the stock engine source: each BUILD file's slice targets.

    Args:
        name: The stock SDK's repository name prefix (`flutter`).
        provenance: The provenance every slice carries.

    Returns:
        A dict from package path to the BUILD text of its slice targets.
    """
    packages = {}

    def add(path, text):
        packages[path] = packages.get(path, "") + "\n" + text

    for host in HOST_PLATFORMS:
        add("host/" + host, _host_tools(host, "{}_{}".format(name, host), provenance))

    # The engines, and where the platform's own gen_snapshot is.
    for platform in DESKTOP_ENGINE_PLATFORMS:
        directory = desktop_engine_dir(platform)
        for mode in ENGINE_MODES:
            repo = "{}_desktop_engine_{}_{}".format(name, platform, mode)
            add("{}/{}".format(directory, mode), _engine(platform, mode, repo, provenance))
            if mode == "debug" or directory == "macos":
                continue
            exe = ".exe" if platform.startswith("windows") else ""
            host = platform
            cpu = platform.split("-")[1]
            add("{}/{}".format(directory, mode), _gen_snapshot(
                host,
                mode,
                cpu,
                "@{}//:engine/gen_snapshot{}".format(repo, exe),
                provenance,
            ))

    for host in ["darwin-arm64", "darwin-x64"]:
        cpu = host.split("-")[1]
        target = native_target(host)
        add("{}/release".format(target), _gen_snapshot(
            host,
            "release",
            cpu,
            "@{}_{}//:host-tools-release/gen_snapshot".format(name, host),
            provenance,
        ))
        add("{}/profile".format(target), _gen_snapshot(
            host,
            "profile",
            cpu,
            "@{}_{}_profile//:host-tools/gen_snapshot".format(name, host),
            provenance,
        ))

    for host, targets in CROSS_COMPILATION_PAIRS.items():
        for target in targets:
            cpu = target.split("-")[1]
            for mode in ["release", "profile"]:
                if target.startswith("ios"):
                    repo = "{}_ios_engine_profile".format(name) if mode == "profile" else "{}_stock_ios_engine".format(name)
                    label = "@{}//:gen_snapshot_arm64".format(repo)
                else:
                    repo = "{}_cross_{}_{}".format(name, host, target) + ("_profile" if mode == "profile" else "")
                    label = "@{}//:{}".format(repo, gen_snapshot_binary_name(host))
                add("{}/{}".format(target, mode), _gen_snapshot(host, mode, {"arm": "arm", "arm64": "arm64"}.get(cpu, "x86_64"), label, provenance))

    # Flutter's signed FlutterMacOS.xcframework of each mode, which macOS
    # add-to-app copies as `flutter build macos-framework` does.
    for mode in ENGINE_MODES:
        add("macos/" + mode, _macos_xcframework("{}_macos_xcframework_{}".format(name, mode), mode, provenance))

    add("web", _web_sdk(name, provenance))
    add("sky_engine", _sky_engine(name))

    # The mobile engines. Only the iOS engine of the device and the simulator
    # is one repository for all hosts.
    for mode in ENGINE_MODES:
        add("ios/" + mode, _ios_engine(name, mode, provenance))
        for arch in android_arches():
            add("android-{}/{}".format(arch, mode), _android_engine(name, arch, mode, provenance))
    return packages

def _flutter_stock_engine_repo_impl(repository_ctx):
    name = repository_ctx.attr.user_repository_name
    engine_revision = repository_ctx.attr.engine_revision
    checksums = repository_ctx.attr.sha256s
    provenance = {
        "origin": "release",
        "flutter_version": repository_ctx.attr.flutter_version,
        "engine_revision": engine_revision,
        "base_url": engine_artifact_url(engine_revision, "")[:-(len(engine_revision) + 1)],
    }

    # The patched SDK is the same for every host: one copy here.
    for directory, artifact in [("debug", "flutter_patched_sdk.zip"), ("release", "flutter_patched_sdk_product.zip")]:
        repository_ctx.download_and_extract(
            url = engine_artifact_url(engine_revision, artifact),
            sha256 = pinned(artifact, checksums.get(artifact, "")),
            output = "kernel/" + directory,
        )
        top = "flutter_patched_sdk" if directory == "debug" else "flutter_patched_sdk_product"
        repository_ctx.file("kernel/{}/BUILD.bazel".format(directory), _LOAD + _kernel(top, provenance))

    repository_ctx.file("flutter_engine.json", json.encode_indent({
        "origin": "release",
        "description": "Flutter {} release engine {}".format(repository_ctx.attr.flutter_version, engine_revision),
        "engine_revision": engine_revision,
        "dart_version": FLUTTER_VERSIONS[repository_ctx.attr.flutter_version].dart_version,
    }) + "\n")
    repository_ctx.file("BUILD.bazel", 'exports_files(["flutter_engine.json"], visibility = ["//visibility:public"])\n')

    for path, text in stock_engine_packages(name, provenance).items():
        repository_ctx.file(path + "/BUILD.bazel", _LOAD + text)

    # Pinned downloads and files written from the attributes alone, so Bazel
    # keeps one copy in its repository contents cache for every output base.
    return repository_ctx.repo_metadata(reproducible = True)

flutter_stock_engine_repo = repository_rule(
    _flutter_stock_engine_repo_impl,
    doc = "The stock release's engine as an engine source: slices over the lazily fetched artifact repositories.",
    attrs = {
        "user_repository_name": attr.string(doc = "The stock SDK's repository name prefix.", mandatory = True),
        "flutter_version": attr.string(mandatory = True),
        "engine_revision": attr.string(mandatory = True),
        "sha256s": attr.string_dict(doc = "Artifact path to expected SHA-256, for the patched SDK archives."),
    },
)
