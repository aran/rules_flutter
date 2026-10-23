"""Repository rule for the hermetic Android headless emulator, platform-tools, system image, and runtime libraries.

Downloads pinned archives from Google's Android SDK repository:
- Android Emulator (`emulator-linux_x64-16428233.zip`, headless QEMU/KVM + SwiftShader)
- Android Platform-Tools (`platform-tools_r37.0.1-linux.zip`, `adb`)
- Android 35 `aosp_atd` `x86_64` system image (`x86_64-35_r01.zip`, Automated Test Device)
along with the transitive closure of Debian 12 (bookworm) amd64 runtime shared
libraries beyond glibc (`libc.so.6`, `libdl.so.2`, `libm.so.6`, `libpthread.so.0`,
`librt.so.1`, `libutil.so.1`) and the C++ runtime (`libgcc_s.so.1`, `libstdc++.so.6`).

Extracted entirely via Bazel's built-in JVM archive extractors (`zip`, `ar`/`.deb` +
`tar.xz`) without relying on any host `sdkmanager`, `avdmanager`, `unzip`, `ar`,
or `xz` binaries.
"""

load(":artifact_urls.bzl", "require_sha256")
load(":download.bzl", "pinned_download_and_extract")

ANDROID_EMULATOR_BUILD_ID = "16428233"

ANDROID_EMULATOR_SHA256 = "b08fc43d8608d2955f607f1b287beb525041e730086bdca3af152accac3af9c1"

ANDROID_PLATFORM_TOOLS_VERSION = "r37.0.1"

ANDROID_PLATFORM_TOOLS_SHA256 = "d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1"

ANDROID_SYSTEM_IMAGE_API_LEVEL = "35"

ANDROID_SYSTEM_IMAGE_TAG = "aosp_atd"

ANDROID_SYSTEM_IMAGE_ABI = "x86_64"

ANDROID_SYSTEM_IMAGE_REVISION = "r01"

ANDROID_SYSTEM_IMAGE_SHA256 = "2dffbc565912b97dd17d935b68002b248872e0c83473139856bb31634db249dc"

_ANDROID_REPOSITORY_BASE_URL = "https://dl.google.com/android/repository/"

_DEBIAN_POOL_BASE_URL = "https://deb.debian.org/debian/"

# Complete transitive closure of Debian 12 (bookworm) amd64 runtime library
# packages required by the headless Android emulator (`emulator`,
# `qemu-system-x86_64-headless`, `lib64/gles_swiftshader/*.so`, and
# `lib64/libgfxstream_backend.so`) beyond glibc, libgcc_s, and libstdc++.
# Each entry is (package_name, debian_pool_path, sha256).
ANDROID_HEADLESS_RUNTIME_DEB_PACKAGES = (
    ("libbsd0", "pool/main/libb/libbsd/libbsd0_0.11.7-2_amd64.deb", "bb31cc8b40f962a85b2cec970f7f79cc704a1ae4bad24257a822055404b2c60b"),
    ("libdrm2", "pool/main/libd/libdrm/libdrm2_2.4.114-1+b1_amd64.deb", "be18fb670797ba32da9628cf3e8acd83160d8db8c8dd842501dd8e401c3b5371"),
    ("libexpat1", "pool/main/e/expat/libexpat1_2.5.0-1+deb12u2_amd64.deb", "2255e62fc22a86d2c544b8a3f516da9aee19383ad5742722ab4ce7f66a30dbc8"),
    ("libffi8", "pool/main/libf/libffi/libffi8_3.4.4-1_amd64.deb", "6d9f6c25c30efccce6d4bceaa48ea86c329a3432abb360a141f76ac223a4c34a"),
    ("libgbm1", "pool/main/m/mesa/libgbm1_22.3.6-1+deb12u2_amd64.deb", "4323840f2b7b3e108990848529125d99c0956ae5a854c1e0568ed08c8faeaa2e"),
    ("libmd0", "pool/main/libm/libmd/libmd0_1.0.4-2_amd64.deb", "03539fd30c509e27101d13a56e52eda9062bdf1aefe337c07ab56def25a13eab"),
    ("libwayland-server0", "pool/main/w/wayland/libwayland-server0_1.21.0-1_amd64.deb", "df0396221d7b794496a687ec61fae82b6465648bc0ab6501ba0a5ed7f56eb8d6"),
    ("libx11-6", "pool/main/libx/libx11/libx11-6_1.8.4-2+deb12u2_amd64.deb", "d88c973e79fd9b65838d77624142952757e47a6eb1a58602acf0911cf35989f4"),
    ("libx11-xcb1", "pool/main/libx/libx11/libx11-xcb1_1.8.4-2+deb12u2_amd64.deb", "f5da45e1d881a793250a96613f28c471a248877f1a0f18a5c90e2a620a76c898"),
    ("libxau6", "pool/main/libx/libxau/libxau6_1.0.9-1_amd64.deb", "679db1c4579ec7c61079adeaae8528adeb2e4bf5465baa6c56233b995d714750"),
    ("libxcb1", "pool/main/libx/libxcb/libxcb1_1.15-1_amd64.deb", "fdc61332a3892168f3cc9cfa1fe9cf11a91dc3e0acacbc47cbc50ebaa234cc71"),
    ("libxdmcp6", "pool/main/libx/libxdmcp/libxdmcp6_1.1.2-3_amd64.deb", "ecb8536f5fb34543b55bb9dc5f5b14c9dbb4150a7bddb3f2287b7cab6e9d25ef"),
    ("libxext6", "pool/main/libx/libxext/libxext6_1.3.4-1+b1_amd64.deb", "504b7be9d7df4f6f4519e8dd4d6f9d03a9fb911a78530fa23a692fba3058cba6"),
    ("zlib1g", "pool/main/z/zlib/zlib1g_1.2.13.dfsg-1_amd64.deb", "d7dd1d1411fedf27f5e27650a6eff20ef294077b568f4c8c5e51466dc7c08ce4"),
)

# Unused GUI / non-x86_64-headless artifacts inside the emulator archive that
# are pruned at extraction time to avoid staging ~650 MB of unused files into
# test runfiles.
_EMULATOR_PRUNE_PATHS = (
    "sdk/emulator/lib64/qt",
    "sdk/emulator/lib64/gles_llvmpipe",
    "sdk/emulator/lib64/vulkan/libLLVM.so",
    "sdk/emulator/lib64/vulkan/libvulkan_lvp.so",
    "sdk/emulator/lib64/vulkan/layers",
    "sdk/emulator/qemu/linux-x86_64/qemu-system-aarch64",
    "sdk/emulator/qemu/linux-x86_64/qemu-system-aarch64-headless",
    "sdk/emulator/qemu/linux-x86_64/qemu-system-armel",
    "sdk/emulator/qemu/linux-x86_64/qemu-system-armel-headless",
    "sdk/emulator/qemu/linux-x86_64/qemu-system-i386",
    "sdk/emulator/qemu/linux-x86_64/qemu-system-i386-headless",
    "sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64",
)

def android_emulator_url(build_id):
    """Returns the Google Android repository download URL for the Linux x64 emulator."""
    if not build_id:
        fail("Android emulator build_id is required.")
    return _ANDROID_REPOSITORY_BASE_URL + "emulator-linux_x64-{}.zip".format(build_id)

def android_platform_tools_url(version):
    """Returns the Google Android repository download URL for Linux platform-tools."""
    if not version:
        fail("Android platform-tools version is required.")
    return _ANDROID_REPOSITORY_BASE_URL + "platform-tools_{}-linux.zip".format(version)

def android_system_image_url(
        tag = ANDROID_SYSTEM_IMAGE_TAG,
        abi = ANDROID_SYSTEM_IMAGE_ABI,
        api_level = ANDROID_SYSTEM_IMAGE_API_LEVEL,
        revision = ANDROID_SYSTEM_IMAGE_REVISION):
    """Returns the Google Android repository download URL for a system image archive."""
    if not tag or not abi or not api_level or not revision:
        fail("Android system image tag, abi, api_level, and revision are all required.")
    return _ANDROID_REPOSITORY_BASE_URL + "sys-img/{tag}/{abi}-{api_level}_{revision}.zip".format(
        tag = tag,
        abi = abi,
        api_level = api_level,
        revision = revision,
    )

def validate_android_headless_runtime_downloads(
        emulator_build_id = ANDROID_EMULATOR_BUILD_ID,
        emulator_sha256 = ANDROID_EMULATOR_SHA256,
        platform_tools_version = ANDROID_PLATFORM_TOOLS_VERSION,
        platform_tools_sha256 = ANDROID_PLATFORM_TOOLS_SHA256,
        system_image_tag = ANDROID_SYSTEM_IMAGE_TAG,
        system_image_abi = ANDROID_SYSTEM_IMAGE_ABI,
        system_image_api_level = ANDROID_SYSTEM_IMAGE_API_LEVEL,
        system_image_revision = ANDROID_SYSTEM_IMAGE_REVISION,
        system_image_sha256 = ANDROID_SYSTEM_IMAGE_SHA256,
        runtime_debs = ANDROID_HEADLESS_RUNTIME_DEB_PACKAGES):
    """Validates and returns the pinned download descriptors for the Android headless runtime.

    Every download goes through `require_sha256` so a missing checksum fails
    immediately rather than performing an unverified fetch.

    Args:
        emulator_build_id: Android emulator build ID (e.g. '16428233').
        emulator_sha256: Expected SHA-256 of the emulator archive.
        platform_tools_version: Platform-tools version (e.g. 'r37.0.1').
        platform_tools_sha256: Expected SHA-256 of the platform-tools archive.
        system_image_tag: System image tag (e.g. 'aosp_atd').
        system_image_abi: System image ABI (e.g. 'x86_64').
        system_image_api_level: System image Android API level (e.g. '35').
        system_image_revision: System image revision (e.g. 'r01').
        system_image_sha256: Expected SHA-256 of the system image archive.
        runtime_debs: Sequence of `(pkg_name, pool_path, sha256)` tuples.

    Returns:
        A struct containing validated URLs, SHA-256 checksums, and `runtime_debs`.
    """
    if not runtime_debs:
        fail("Android headless runtime requires at least one pinned .deb package.")

    emu_url = android_emulator_url(emulator_build_id)
    verified_emu_sha256 = require_sha256(emulator_sha256, emu_url)

    pt_url = android_platform_tools_url(platform_tools_version)
    verified_pt_sha256 = require_sha256(platform_tools_sha256, pt_url)

    sysimg_url = android_system_image_url(
        tag = system_image_tag,
        abi = system_image_abi,
        api_level = system_image_api_level,
        revision = system_image_revision,
    )
    verified_sysimg_sha256 = require_sha256(system_image_sha256, sysimg_url)

    verified_debs = []
    for pkg_name, pool_path, deb_sha256 in runtime_debs:
        if not pkg_name:
            fail("Android headless runtime package name is required.")
        if not pool_path:
            fail("Android headless runtime pool_path is required for package {}.".format(pkg_name))
        deb_url = _DEBIAN_POOL_BASE_URL + pool_path
        verified_debs.append(struct(
            name = pkg_name,
            url = deb_url,
            sha256 = require_sha256(deb_sha256, deb_url),
        ))

    return struct(
        emulator_url = emu_url,
        emulator_sha256 = verified_emu_sha256,
        platform_tools_url = pt_url,
        platform_tools_sha256 = verified_pt_sha256,
        system_image_url = sysimg_url,
        system_image_sha256 = verified_sysimg_sha256,
        runtime_debs = verified_debs,
    )

_BUILD_CONTENT = """# Generated by android_headless_runtime_repo.bzl

exports_files(
    [
        "sdk/emulator/emulator",
        "sdk/platform-tools/adb",
    ],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "emulator",
    srcs = ["sdk/emulator/emulator"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "adb",
    srcs = ["sdk/platform-tools/adb"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "emulator_files",
    srcs = glob(["sdk/emulator/**"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "platform_tools_files",
    srcs = glob(["sdk/platform-tools/**"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "system_image_files",
    srcs = glob([
        "sdk/platforms/**",
        "sdk/system-images/**",
    ]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "runtime_libs",
    srcs = glob([
        "sysroot/lib/x86_64-linux-gnu/**",
        "sysroot/usr/lib/x86_64-linux-gnu/**",
    ]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "all_files",
    srcs = [
        ":emulator_files",
        ":platform_tools_files",
        ":runtime_libs",
        ":system_image_files",
    ],
    visibility = ["//visibility:public"],
)
"""

def _android_headless_runtime_repo_impl(repository_ctx):
    spec = validate_android_headless_runtime_downloads(
        emulator_build_id = repository_ctx.attr.emulator_build_id,
        emulator_sha256 = repository_ctx.attr.emulator_sha256,
        platform_tools_version = repository_ctx.attr.platform_tools_version,
        platform_tools_sha256 = repository_ctx.attr.platform_tools_sha256,
        system_image_tag = repository_ctx.attr.system_image_tag,
        system_image_abi = repository_ctx.attr.system_image_abi,
        system_image_api_level = repository_ctx.attr.system_image_api_level,
        system_image_revision = repository_ctx.attr.system_image_revision,
        system_image_sha256 = repository_ctx.attr.system_image_sha256,
    )

    pinned_download_and_extract(
        repository_ctx,
        url = spec.emulator_url,
        sha256 = spec.emulator_sha256,
        output = "sdk",
    )
    for prune_path in _EMULATOR_PRUNE_PATHS:
        repository_ctx.delete(prune_path)

    pinned_download_and_extract(
        repository_ctx,
        url = spec.platform_tools_url,
        sha256 = spec.platform_tools_sha256,
        output = "sdk",
    )

    sysimg_output = "sdk/system-images/android-{}/{}".format(
        repository_ctx.attr.system_image_api_level,
        repository_ctx.attr.system_image_tag,
    )
    pinned_download_and_extract(
        repository_ctx,
        url = spec.system_image_url,
        sha256 = spec.system_image_sha256,
        output = sysimg_output,
    )

    # The emulator checks for platforms/android-<api>/build.prop under
    # ANDROID_SDK_ROOT when resolving AVD target metadata.
    repository_ctx.file(
        "sdk/platforms/android-{}/build.prop".format(repository_ctx.attr.system_image_api_level),
        "ro.build.version.sdk={}\n".format(repository_ctx.attr.system_image_api_level),
    )

    for deb in spec.runtime_debs:
        tmp_dir = "_deb_" + deb.name
        pinned_download_and_extract(
            repository_ctx,
            url = deb.url,
            sha256 = deb.sha256,
            output = tmp_dir,
        )
        repository_ctx.extract(
            archive = tmp_dir + "/data.tar.xz",
            output = "sysroot",
        )
        repository_ctx.delete(tmp_dir)

    repository_ctx.file("BUILD.bazel", _BUILD_CONTENT)

android_headless_runtime_repo = repository_rule(
    _android_headless_runtime_repo_impl,
    doc = "Downloads the hermetic Android headless emulator, platform-tools (adb), Android 35 x86_64 ATD system image, and pinned Debian runtime shared libraries.",
    attrs = {
        "emulator_build_id": attr.string(
            default = ANDROID_EMULATOR_BUILD_ID,
            doc = "Android emulator Linux x64 build ID.",
        ),
        "emulator_sha256": attr.string(
            default = ANDROID_EMULATOR_SHA256,
            doc = "Expected SHA-256 checksum of emulator-linux_x64-<build_id>.zip.",
        ),
        "platform_tools_version": attr.string(
            default = ANDROID_PLATFORM_TOOLS_VERSION,
            doc = "Android platform-tools version.",
        ),
        "platform_tools_sha256": attr.string(
            default = ANDROID_PLATFORM_TOOLS_SHA256,
            doc = "Expected SHA-256 checksum of platform-tools_<version>-linux.zip.",
        ),
        "system_image_tag": attr.string(
            default = ANDROID_SYSTEM_IMAGE_TAG,
            doc = "Android system image tag (e.g. 'aosp_atd').",
        ),
        "system_image_abi": attr.string(
            default = ANDROID_SYSTEM_IMAGE_ABI,
            doc = "Android system image ABI (e.g. 'x86_64').",
        ),
        "system_image_api_level": attr.string(
            default = ANDROID_SYSTEM_IMAGE_API_LEVEL,
            doc = "Android system image API level (e.g. '35').",
        ),
        "system_image_revision": attr.string(
            default = ANDROID_SYSTEM_IMAGE_REVISION,
            doc = "Android system image revision (e.g. 'r01').",
        ),
        "system_image_sha256": attr.string(
            default = ANDROID_SYSTEM_IMAGE_SHA256,
            doc = "Expected SHA-256 checksum of the system image archive.",
        ),
    },
)
