"""Declare runtime dependencies.

These are needed for local dev, and users must install them as well.
See https://docs.bazel.build/versions/main/skylark/deploying.html#dependencies
"""

load("//flutter/private:artifact_urls.bzl", "android_engine_artifact_path", "dart_sdk_artifact_path", "desktop_engine_artifact_path", "engine_artifact_url", "gen_snapshot_cross_artifact_path", "host_artifacts_path", "ios_engine_artifact_path")
load("//flutter/private:engine_helpers.bzl", "PLATFORM_PREFIX_TO_OS", "dart_binary_name", "dartaotruntime_binary_name", "engine_arch_for_os", "engine_debug_filegroup_for_os", "engine_filegroup_for_os", "extract_macos_inner_framework", "gen_snapshot_host_platform")
load("//flutter/private:flutter_android_engine_repo.bzl", "flutter_android_engine_repo")
load("//flutter/private:flutter_cross_repo.bzl", "flutter_cross_compilation_repo")
load("//flutter/private:flutter_desktop_cross_repo.bzl", "flutter_desktop_cross_repo")
load("//flutter/private:flutter_desktop_engine_repo.bzl", "flutter_desktop_engine_repo")
load("//flutter/private:flutter_ios_engine_repo.bzl", "flutter_ios_engine_repo")
load("//flutter/private:flutter_linux_sysroot_repo.bzl", "flutter_linux_sysroot_repo")
load("//flutter/private:flutter_macos_engine_repo.bzl", "flutter_macos_engine_repo")
load("//flutter/private:flutter_web_sdk_repo.bzl", "flutter_web_sdk_repo")
load("//flutter/private:toolchains_repo.bzl", "CROSS_COMPILATION_PAIRS", "DESKTOP_CROSS_PAIRS", "HOST_PLATFORMS", "flutter_toolchains_repo")
load("//flutter/private:versions.bzl", "ARTIFACT_CHECKSUMS", "FLUTTER_VERSIONS", "LINUX_SYSROOT_CHECKSUMS")

def _flutter_engine_artifacts_impl(repository_ctx):
    """Downloads the Flutter engine host artifacts and patched SDK for a given platform."""
    flutter_version = repository_ctx.attr.flutter_version
    platform = repository_ctx.attr.platform
    meta = FLUTTER_VERSIONS[flutter_version]
    engine_revision = meta.engine_revision
    checksums = ARTIFACT_CHECKSUMS.get(flutter_version, {})

    # 1. Download the Flutter-bundled Dart SDK for this host.
    dart_sdk_path = dart_sdk_artifact_path(platform)
    repository_ctx.download_and_extract(
        url = engine_artifact_url(engine_revision, dart_sdk_path),
        sha256 = checksums.get(dart_sdk_path, ""),
        stripPrefix = "dart-sdk",
        output = "dart-sdk",
    )

    # 2. Download host tools (frontend_server, icudtl.dat, gen_snapshot for debug).
    host_tools_path = host_artifacts_path(platform)
    repository_ctx.download_and_extract(
        url = engine_artifact_url(engine_revision, host_tools_path),
        sha256 = checksums.get(host_tools_path, ""),
        output = "host-tools",
    )

    # 3. Download the release gen_snapshot (product mode, matches the release engine).
    # Only macOS publishes a separate release host tools archive.  On Linux and
    # Windows the release gen_snapshot is bundled inside the desktop engine
    # archive (step 6) — matching how the Flutter CLI resolves it.
    os_part = platform.split("-")[0]  # "darwin", "linux", "windows"
    has_release_host_tools = os_part == "darwin"
    if has_release_host_tools:
        release_tools_path = host_artifacts_path(platform, mode = "release")
        repository_ctx.download_and_extract(
            url = engine_artifact_url(engine_revision, release_tools_path),
            sha256 = checksums.get(release_tools_path, ""),
            output = "host-tools-release",
        )

    # 4. Download the patched SDK (debug platform kernel dills).
    repository_ctx.download_and_extract(
        url = engine_artifact_url(engine_revision, "flutter_patched_sdk.zip"),
        sha256 = checksums.get("flutter_patched_sdk.zip", ""),
        output = "patched-sdk",
    )

    # 5. Download the product patched SDK (release platform kernel dills).
    repository_ctx.download_and_extract(
        url = engine_artifact_url(engine_revision, "flutter_patched_sdk_product.zip"),
        sha256 = checksums.get("flutter_patched_sdk_product.zip", ""),
        output = "patched-sdk-product",
    )

    # 6. Download desktop Flutter engine runtime library (release mode).
    # Desktop apps need the engine shared library to run (FlutterMacOS.framework,
    # libflutter_linux_gtk.so, or flutter_windows.dll).
    # On Linux and Windows, this archive also contains the release gen_snapshot.
    arch_part = platform.split("-")[1]  # "x64", "arm64"
    os_name = PLATFORM_PREFIX_TO_OS.get(os_part)
    engine_arch = engine_arch_for_os(os_name, arch_part)

    has_engine_library = False
    has_engine_debug = False
    engine_release_path = desktop_engine_artifact_path(os_name, engine_arch, "release") if os_name else None
    if engine_release_path:
        repository_ctx.download_and_extract(
            url = engine_artifact_url(engine_revision, engine_release_path),
            sha256 = checksums.get(engine_release_path, ""),
            output = "engine",
        )

        if os_name == "macos":
            extract_macos_inner_framework(repository_ctx)

        has_engine_library = True

        # Also download the debug engine for JIT mode (-c dbg).
        # macOS debug engine is at the no-suffix path (different from Linux/Windows
        # which use -debug suffix). All three platforms need both engines.
        engine_debug_path = desktop_engine_artifact_path(os_name, engine_arch, "debug")
        if engine_debug_path:
            repository_ctx.download_and_extract(
                url = engine_artifact_url(engine_revision, engine_debug_path),
                sha256 = checksums.get(engine_debug_path, ""),
                output = "engine-debug",
            )

            if os_name == "macos":
                extract_macos_inner_framework(repository_ctx, "engine-debug")

            has_engine_debug = True

    # 6b. Download the C++ client wrapper (Windows only).
    # The wrapper provides flutter/plugin_registry.h and its implementation
    # sources, needed to compile native plugin registrants on Windows.
    if os_name == "windows" and has_engine_library:
        cpp_wrapper_path = "{platform}/flutter-cpp-client-wrapper.zip".format(platform = platform)
        repository_ctx.download_and_extract(
            url = engine_artifact_url(engine_revision, cpp_wrapper_path),
            sha256 = checksums.get(cpp_wrapper_path, ""),
            output = "cpp-client-wrapper",
        )

    # 7. Download font-subset tools (const_finder + font-subset binary).
    font_subset_path = "{platform}/font-subset.zip".format(platform = platform)
    repository_ctx.download_and_extract(
        url = engine_artifact_url(engine_revision, font_subset_path),
        sha256 = checksums.get(font_subset_path, ""),
        output = "font-subset-tools",
    )

    # 8. Download material design fonts (MaterialIcons, Roboto family).
    material_fonts_url = meta.material_fonts_url
    repository_ctx.download_and_extract(
        url = "https://storage.googleapis.com/" + material_fonts_url,
        sha256 = checksums.get("material_fonts.zip", ""),
        output = "material-fonts",
    )

    dart_bin = dart_binary_name(platform)
    dartaotruntime_bin = dartaotruntime_binary_name(platform)
    exe_suffix = ".exe" if os_part == "windows" else ""

    # Generate BUILD.bazel with flutter_toolchain target.
    engine_library_attr = ""
    engine_filegroup = ""
    engine_debug_filegroup = ""
    if has_engine_library:
        engine_filegroup = engine_filegroup_for_os(os_name)
        if has_engine_debug:
            engine_debug_filegroup = engine_debug_filegroup_for_os(os_name)
            engine_library_attr = """    engine_library = select({
        "@rules_flutter//flutter/private:dbg": ":engine_debug_library",
        "//conditions:default": ":engine_library",
    }),"""
        else:
            engine_library_attr = '    engine_library = ":engine_library",'

    # Release gen_snapshot path varies by platform:
    # - macOS: separate release host tools archive → host-tools-release/gen_snapshot
    # - Linux/Windows: bundled in the desktop engine archive → engine/gen_snapshot[.exe]
    if has_release_host_tools:
        gen_snapshot_path = "host-tools-release/gen_snapshot"
    elif has_engine_library:
        gen_snapshot_bin = "gen_snapshot.exe" if os_name == "windows" else "gen_snapshot"
        gen_snapshot_path = "engine/" + gen_snapshot_bin
    else:
        # Fallback: use the debug gen_snapshot from host tools.
        gen_snapshot_path = "host-tools/gen_snapshot"

    # Linux sysroot: point to the sysroot repo for hermetic GTK3 builds.
    linux_sysroot_attr = ""
    sysroot_repo_name = repository_ctx.attr.sysroot_repo_name
    if sysroot_repo_name:
        linux_sysroot_attr = '    linux_sysroot = "@{}//:sysroot_files",'.format(sysroot_repo_name)

    build_content = _BUILD_TEMPLATE.format(
        flutter_version = flutter_version,
        engine_revision = engine_revision,
        dart_bin = dart_bin,
        dartaotruntime_bin = dartaotruntime_bin,
        engine_library_attr = engine_library_attr,
        engine_filegroup = engine_filegroup,
        engine_debug_filegroup = engine_debug_filegroup,
        gen_snapshot = gen_snapshot_path,
        exe_suffix = exe_suffix,
        linux_sysroot_attr = linux_sysroot_attr,
    )
    repository_ctx.file("BUILD.bazel", build_content)

_BUILD_TEMPLATE = """# Generated by flutter/repositories.bzl
load("@rules_flutter//flutter:toolchain.bzl", "flutter_toolchain")

filegroup(
    name = "dart_sdk_files",
    srcs = glob(["dart-sdk/**"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "patched_sdk",
    srcs = glob(["patched-sdk/flutter_patched_sdk/**"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "patched_sdk_product",
    srcs = glob(["patched-sdk-product/flutter_patched_sdk_product/**"]),
    visibility = ["//visibility:public"],
)

exports_files(glob(["**"]), visibility = ["//visibility:public"])

filegroup(
    name = "shader_lib_files",
    srcs = glob(["host-tools/shader_lib/**"]),
    visibility = ["//visibility:public"],
)
{engine_filegroup}
{engine_debug_filegroup}
flutter_toolchain(
    name = "flutter_toolchain",
    dart = "dart-sdk/bin/{dart_bin}",
    dart_sdk = ":dart_sdk_files",
    dartaotruntime = "dart-sdk/bin/{dartaotruntime_bin}",
    engine_revision = "{engine_revision}",
{engine_library_attr}
    flutter_tester = "host-tools/flutter_tester{exe_suffix}",
    frontend_server = "host-tools/frontend_server_aot.dart.snapshot",
    gen_snapshot = "{gen_snapshot}",
    icu_data = "host-tools/icudtl.dat",
    const_finder = "font-subset-tools/const_finder.dart.snapshot",
    font_subset = "font-subset-tools/font-subset{exe_suffix}",
    impellerc = "host-tools/impellerc{exe_suffix}",
    material_icons_font = "material-fonts/MaterialIcons-Regular.otf",
    vm_isolate_snapshot = "host-tools/vm_isolate_snapshot.bin",
    isolate_snapshot = "host-tools/isolate_snapshot.bin",
    shader_lib = ":shader_lib_files",
    patched_sdk = ":patched_sdk",
    platform_kernel_dill = "patched-sdk/flutter_patched_sdk/platform_strong.dill",
    platform_kernel_dill_product = "patched-sdk-product/flutter_patched_sdk_product/platform_strong.dill",
{linux_sysroot_attr}
    version = "{flutter_version}",
)
"""

flutter_engine_artifacts = repository_rule(
    _flutter_engine_artifacts_impl,
    doc = "Downloads Flutter engine artifacts (Dart SDK, host tools, patched SDK) for a given host platform.",
    attrs = {
        "flutter_version": attr.string(
            doc = "The Flutter SDK version (e.g. `3.41.2`). Must be listed in versions.bzl.",
            mandatory = True,
            values = FLUTTER_VERSIONS.keys(),
        ),
        "platform": attr.string(
            doc = "The host platform (e.g. `darwin-arm64`). Must match a key in HOST_PLATFORMS.",
            mandatory = True,
            values = HOST_PLATFORMS.keys(),
        ),
        "sysroot_repo_name": attr.string(
            doc = "Name of the Linux sysroot repo for hermetic GTK3 builds. Required for Linux platforms.",
        ),
    },
)

def flutter_register_toolchains(name, **kwargs):
    """Convenience macro for setting up Flutter SDK repositories.

    Creates a repository for each host platform, cross-compilation repos,
    and a toolchains alias repository.

    Args:
        name: base name for all created repos, like "flutter"
        **kwargs: passed to each flutter_engine_artifacts call (must include flutter_version)
    """
    flutter_version = kwargs["flutter_version"]
    meta = FLUTTER_VERSIONS[flutter_version]
    checksums = ARTIFACT_CHECKSUMS.get(flutter_version, {})

    # Host platform repos.
    for platform, host_meta in HOST_PLATFORMS.items():
        sysroot_repo_name = ""
        if host_meta.os == "linux":
            sysroot_repo_name = name + "_linux_sysroot_" + host_meta.arch
        flutter_engine_artifacts(
            name = name + "_" + platform,
            platform = platform,
            sysroot_repo_name = sysroot_repo_name,
            **kwargs
        )

    # Cross-compilation repos.
    for host_platform, targets in CROSS_COMPILATION_PAIRS.items():
        for target_platform in targets:
            gen_snapshot_sha256 = ""
            gen_snapshot_label = ""

            if target_platform.startswith("ios"):
                # iOS gen_snapshot is bundled in the iOS engine artifact.
                gen_snapshot_label = "@{ios_engine}//:gen_snapshot_arm64".format(
                    ios_engine = name + "_ios_engine",
                )
            else:
                artifact_host = gen_snapshot_host_platform(host_platform)
                gen_snapshot_path = gen_snapshot_cross_artifact_path(target_platform, "release", artifact_host)
                gen_snapshot_sha256 = checksums.get(gen_snapshot_path, "")

            flutter_cross_compilation_repo(
                name = name + "_cross_" + host_platform + "_" + target_platform,
                flutter_version = flutter_version,
                engine_revision = meta.engine_revision,
                host_platform = host_platform,
                target_platform = target_platform,
                host_repo_name = name + "_" + host_platform,
                gen_snapshot_sha256 = gen_snapshot_sha256,
                gen_snapshot_label = gen_snapshot_label,
            )

    # Linux sysroot repos (one per architecture, shared across hosts).
    # These are lazy — only fetched when a Linux desktop build is attempted.
    # Collect all Linux architectures from both host platforms and desktop cross targets.
    _ARCH_TO_DEB = {"x64": "amd64", "arm64": "arm64"}
    linux_sysroot_arches = {}
    for platform, host_meta in HOST_PLATFORMS.items():
        if host_meta.os == "linux":
            linux_sysroot_arches[host_meta.arch] = True
    for _hp, desktop_targets in DESKTOP_CROSS_PAIRS.items():
        for target_platform in desktop_targets:
            if target_platform.startswith("linux-"):
                linux_sysroot_arches[target_platform.split("-")[1]] = True
    for arch in linux_sysroot_arches.keys():
        deb_arch = _ARCH_TO_DEB.get(arch)
        if not deb_arch:
            continue
        flutter_linux_sysroot_repo(
            name = name + "_linux_sysroot_" + arch,
            target_arch = arch,
            sha256 = LINUX_SYSROOT_CHECKSUMS[deb_arch],
        )

    # Desktop engine repos (one per unique target platform, shared across hosts).
    # These are lazy — only downloaded when a cross-platform desktop build is used.
    # Both release (AOT) and debug (JIT) engines are downloaded, matching the
    # iOS/Android pattern. The toolchain uses select() to pick the right one.
    desktop_engine_repos_created = {}
    for _host_platform, desktop_targets in DESKTOP_CROSS_PAIRS.items():
        for target_platform in desktop_targets:
            if target_platform in desktop_engine_repos_created:
                continue
            desktop_engine_repos_created[target_platform] = True

            target_os = PLATFORM_PREFIX_TO_OS[target_platform.split("-")[0]]
            engine_arch = engine_arch_for_os(target_os, target_platform.split("-")[1])

            # Release engine (AOT — used with -c opt).
            engine_path = desktop_engine_artifact_path(target_os, engine_arch, "release")
            flutter_desktop_engine_repo(
                name = name + "_desktop_engine_" + target_platform,
                engine_revision = meta.engine_revision,
                target_os = target_os,
                target_arch = engine_arch,
                sha256 = checksums.get(engine_path, ""),
            )

            # Debug engine (JIT — used with -c dbg).
            # macOS debug engine is in the host artifacts repo, not a separate download.
            if target_os != "macos":
                engine_debug_path = desktop_engine_artifact_path(target_os, engine_arch, "debug")
                flutter_desktop_engine_repo(
                    name = name + "_desktop_engine_" + target_platform + "_debug",
                    engine_revision = meta.engine_revision,
                    target_os = target_os,
                    target_arch = engine_arch,
                    mode = "debug",
                    sha256 = checksums.get(engine_debug_path, ""),
                )

    # Desktop cross-platform toolchain repos.
    for host_platform, desktop_targets in DESKTOP_CROSS_PAIRS.items():
        for target_platform in desktop_targets:
            target_os = PLATFORM_PREFIX_TO_OS[target_platform.split("-")[0]]
            sysroot_repo_name = ""
            if target_platform.startswith("linux-"):
                sysroot_repo_name = name + "_linux_sysroot_" + target_platform.split("-")[1]

            # Debug engine repo for select() — macOS doesn't have a separate debug repo.
            engine_debug_repo_name = ""
            if target_os != "macos":
                engine_debug_repo_name = name + "_desktop_engine_" + target_platform + "_debug"

            flutter_desktop_cross_repo(
                name = name + "_desktop_cross_" + host_platform + "_" + target_platform,
                flutter_version = flutter_version,
                engine_revision = meta.engine_revision,
                host_platform = host_platform,
                target_platform = target_platform,
                host_repo_name = name + "_" + host_platform,
                engine_repo_name = name + "_desktop_engine_" + target_platform,
                engine_debug_repo_name = engine_debug_repo_name,
                sysroot_repo_name = sysroot_repo_name,
            )

    # Web SDK repo (lazy — only downloaded when web targets are built).
    flutter_web_sdk_repo(
        name = name + "_web_sdk",
        engine_revision = meta.engine_revision,
        sha256 = checksums.get("flutter-web-sdk.zip", ""),
    )

    # Android engine repos (lazy — one per ABI, only downloaded when Android targets are built).
    # Each repo carries both the release engine (AOT) and the debug engine (JIT);
    # the flutter_android_engine macro select()s between its two jar targets, so
    # consumers only need a single `flutter_android_engine_<abi>` use_repo entry —
    # matching the macOS and iOS engine repos.
    android_engine_repos_created = {}
    for _host_platform, targets in CROSS_COMPILATION_PAIRS.items():
        for target_platform in targets:
            if not target_platform.startswith("android-"):
                continue
            android_arch = target_platform.split("-")[1]
            if android_arch in android_engine_repos_created:
                continue
            android_engine_repos_created[android_arch] = True

            flutter_android_engine_repo(
                name = name + "_android_engine_" + android_arch,
                engine_revision = meta.engine_revision,
                android_arch = android_arch,
                release_sha256 = checksums.get(android_engine_artifact_path(android_arch, "release"), ""),
                debug_sha256 = checksums.get(android_engine_artifact_path(android_arch, "debug"), ""),
            )

    # iOS engine repo (lazy — only downloaded when iOS targets are built).
    # One repo carries both the release engine (device, AOT) and the debug
    # engine (simulator, JIT); the iOS macros select() between its two targets,
    # so consumers only need a single `flutter_ios_engine` use_repo entry —
    # matching the macOS engine alias repo.
    flutter_ios_engine_repo(
        name = name + "_ios_engine",
        engine_revision = meta.engine_revision,
        release_sha256 = checksums.get(ios_engine_artifact_path("release"), ""),
        debug_sha256 = checksums.get(ios_engine_artifact_path("debug"), ""),
    )

    # macOS engine alias repo — stable name that delegates to the host
    # platform's engine_library (FlutterMacOS.framework).
    flutter_macos_engine_repo(
        name = name + "_macos_engine",
        user_repository_name = name,
    )

    flutter_toolchains_repo(
        name = name + "_toolchains",
        user_repository_name = name,
    )
