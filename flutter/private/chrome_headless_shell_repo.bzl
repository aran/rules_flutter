"""Repository rule for the hermetic Chrome for Testing headless shell and its runtime libraries.

Downloads a pinned `chrome-headless-shell-linux64.zip` from Chrome for Testing
along with the transitive closure of Debian 12 (bookworm) amd64 runtime shared
libraries beyond glibc (`libc.so.6`, `libdl.so.2`, `libm.so.6`, `libpthread.so.0`)
and the C++ runtime (`libgcc_s.so.1`, `libstdc++.so.6`).

Note that Chromium's `debian_bullseye_amd64-sysroot` cannot be used at runtime:
its `.so` files are link-only stubs whose relocation sections are zeroed out,
which causes `ld.so` to abort with an assertion failure during relative relocation.
The `.deb` packages extracted here carry real runtime shared objects, extracted
entirely via Bazel's built-in JVM archive extractors (`ar`/`.deb` + `tar.xz`)
without relying on any host `ar`, `xz`, or `unzip` binaries.
"""

load(":artifact_urls.bzl", "require_sha256")
load(":download.bzl", "pinned_download_and_extract")

CHROME_HEADLESS_SHELL_VERSION = "155.0.8059.84"

CHROME_HEADLESS_SHELL_SHA256 = "a5d71b91aa996fef00517cd212b2dfb816b43055edefbe727e6fd562d4ae1f9c"

_DEBIAN_POOL_BASE_URL = "https://deb.debian.org/debian/"

# Complete transitive closure of Debian 12 (bookworm) amd64 runtime library
# packages required by chrome-headless-shell beyond glibc and libgcc_s.
# Each entry is (package_name, debian_pool_path, sha256).
CHROME_RUNTIME_DEB_PACKAGES = (
    ("libasound2", "pool/main/a/alsa-lib/libasound2_1.2.8-1+b1_amd64.deb", "44c77b076a7b11ae99712439022d822245b1994c435da564ebd320bb676faf4c"),
    ("libatk-bridge2.0-0", "pool/main/a/at-spi2-core/libatk-bridge2.0-0_2.46.0-5_amd64.deb", "fbb07714fdd3fdee7b63fd8595053f4fa8021d8e350a5de6281c6ce7cd4f158f"),
    ("libatk1.0-0", "pool/main/a/at-spi2-core/libatk1.0-0_2.46.0-5_amd64.deb", "909dd661e03760a9ba1529bfc772f259cec8431999ee38b7c5521186237cdd98"),
    ("libatspi2.0-0", "pool/main/a/at-spi2-core/libatspi2.0-0_2.46.0-5_amd64.deb", "1c0332f3b712a8e5ee56800bbcab83a8f92098874094f2b0bdfd6b7fd45e8b83"),
    ("libblkid1", "pool/main/u/util-linux/libblkid1_2.38.1-5+deb12u3_amd64.deb", "5a083377f29191cafcdf0f91ec124349b4a7895b531556633a136e43c6d53943"),
    ("libbrotli1", "pool/main/b/brotli/libbrotli1_1.0.9-2+b6_amd64.deb", "563b4caec1aa5e876bd3355b36e7a38e1484baf5a293b48d1e8bd22db786e4d7"),
    ("libbsd0", "pool/main/libb/libbsd/libbsd0_0.11.7-2_amd64.deb", "bb31cc8b40f962a85b2cec970f7f79cc704a1ae4bad24257a822055404b2c60b"),
    ("libcap2", "pool/main/libc/libcap2/libcap2_2.66-4+deb12u3+b1_amd64.deb", "8d684c673e7483802a5c447834b0df6fce006eb3a7109e1be412f5ad425bb24f"),
    ("libdbus-1-3", "pool/main/d/dbus/libdbus-1-3_1.14.10-1~deb12u1_amd64.deb", "18ee0ce5fab9f7b671e87da1e9fa18660e36e04a3402f24bdb8635e0ba1d35f6"),
    ("libdrm2", "pool/main/libd/libdrm/libdrm2_2.4.114-1+b1_amd64.deb", "be18fb670797ba32da9628cf3e8acd83160d8db8c8dd842501dd8e401c3b5371"),
    ("libexpat1", "pool/main/e/expat/libexpat1_2.5.0-1+deb12u2_amd64.deb", "2255e62fc22a86d2c544b8a3f516da9aee19383ad5742722ab4ce7f66a30dbc8"),
    ("libffi8", "pool/main/libf/libffi/libffi8_3.4.4-1_amd64.deb", "6d9f6c25c30efccce6d4bceaa48ea86c329a3432abb360a141f76ac223a4c34a"),
    ("libfontconfig1", "pool/main/f/fontconfig/libfontconfig1_2.14.1-4_amd64.deb", "16ee38d374e064f534116dc442b086ef26f9831f1c0af7e5fb4fe4512e700649"),
    ("libfreetype6", "pool/main/f/freetype/libfreetype6_2.12.1+dfsg-5+deb12u4_amd64.deb", "8043e479f73f29992d652e3f9dfe8b17f9780c7ea6330afe379ec5f9f188ac44"),
    ("libgbm1", "pool/main/m/mesa/libgbm1_22.3.6-1+deb12u2_amd64.deb", "4323840f2b7b3e108990848529125d99c0956ae5a854c1e0568ed08c8faeaa2e"),
    ("libgcrypt20", "pool/main/libg/libgcrypt20/libgcrypt20_1.10.1-3+deb12u1_amd64.deb", "e7a56552139c693904a6f9712234c05fe918353273a7cbdb5e62f423ad71bb97"),
    ("libglib2.0-0", "pool/main/g/glib2.0/libglib2.0-0_2.74.6-2+deb12u9_amd64.deb", "7ff85197685d89e150e342b29a59aab1beee400050ba7da73de81cd999ffee5a"),
    ("libgpg-error0", "pool/main/libg/libgpg-error/libgpg-error0_1.46-1_amd64.deb", "89944ee11d7370ce6ef46fc52f094c4a6512eff8943ec4c6ebefeae6360ceada"),
    ("liblz4-1", "pool/main/l/lz4/liblz4-1_1.9.4-1_amd64.deb", "64cde86cef1deaf828bd60297839b59710b5cd8dc50efd4f12643caaee9389d3"),
    ("liblzma5", "pool/main/x/xz-utils/liblzma5_5.4.1-1+deb12u1_amd64.deb", "f96d8876b53ec89d76a992bc199679b818cf518225a768954d9451fb556a4eb7"),
    ("libmd0", "pool/main/libm/libmd/libmd0_1.0.4-2_amd64.deb", "03539fd30c509e27101d13a56e52eda9062bdf1aefe337c07ab56def25a13eab"),
    ("libmount1", "pool/main/u/util-linux/libmount1_2.38.1-5+deb12u3_amd64.deb", "f46e2d6b006951825adde9757790b6609d7c66c7700f9b68f3db913eaac323c3"),
    ("libnspr4", "pool/main/n/nspr/libnspr4_4.35-1_amd64.deb", "6cca09767e94e4b5d2888ef31ad797bd3e7cec27fbbe98b49b10d4884746ce77"),
    ("libnss3", "pool/main/n/nss/libnss3_3.87.1-1+deb12u2_amd64.deb", "bb4339de2e76be9862225447c6c24b9d759baba5ee861d86dfb558ebf4474d14"),
    ("libpcre2-8-0", "pool/main/p/pcre2/libpcre2-8-0_10.42-1_amd64.deb", "030db54f4d76cdfe2bf0e8eb5f9efea0233ab3c7aa942d672c7b63b52dbaf935"),
    ("libpng16-16", "pool/main/libp/libpng1.6/libpng16-16_1.6.39-2+deb12u5_amd64.deb", "a56d64bfaa9da12aafb83347909e62e6fd5fd251e6b34c194065911a30359978"),
    ("libselinux1", "pool/main/libs/libselinux/libselinux1_3.4-1+b6_amd64.deb", "2b07f5287b9105f40158b56e4d70cc1652dac56a408f3507b4ab3d061eed425f"),
    ("libsqlite3-0", "pool/main/s/sqlite3/libsqlite3-0_3.40.1-2+deb12u2_amd64.deb", "a8d78b40e9b4e422224aeebfe0e4dfc243f6acf3532490b0c05480d4283d41e2"),
    ("libsystemd0", "pool/main/s/systemd/libsystemd0_252.39-1~deb12u2_amd64.deb", "013c07514a9e4933b2d5c098018695a6aa42d085dbc483ce2c094a954c8a1b0a"),
    ("libudev1", "pool/main/s/systemd/libudev1_252.39-1~deb12u2_amd64.deb", "6f7e08f11c4809d2e5998c775f7b423ab5ec2ce0309494b4a2615037052245e2"),
    ("libwayland-server0", "pool/main/w/wayland/libwayland-server0_1.21.0-1_amd64.deb", "df0396221d7b794496a687ec61fae82b6465648bc0ab6501ba0a5ed7f56eb8d6"),
    ("libx11-6", "pool/main/libx/libx11/libx11-6_1.8.4-2+deb12u2_amd64.deb", "d88c973e79fd9b65838d77624142952757e47a6eb1a58602acf0911cf35989f4"),
    ("libx11-xcb1", "pool/main/libx/libx11/libx11-xcb1_1.8.4-2+deb12u2_amd64.deb", "f5da45e1d881a793250a96613f28c471a248877f1a0f18a5c90e2a620a76c898"),
    ("libxau6", "pool/main/libx/libxau/libxau6_1.0.9-1_amd64.deb", "679db1c4579ec7c61079adeaae8528adeb2e4bf5465baa6c56233b995d714750"),
    ("libxcb1", "pool/main/libx/libxcb/libxcb1_1.15-1_amd64.deb", "fdc61332a3892168f3cc9cfa1fe9cf11a91dc3e0acacbc47cbc50ebaa234cc71"),
    ("libxcomposite1", "pool/main/libx/libxcomposite/libxcomposite1_0.4.5-1_amd64.deb", "4c26ebf519d2ebc22fc1416dee45e12c4c4ef68aa9b2ed890356830df42b652a"),
    ("libxdamage1", "pool/main/libx/libxdamage/libxdamage1_1.1.6-1_amd64.deb", "fcdf7e4c29b307ba8711c864e1e646d76315a8f55121198143653e56592fa8a7"),
    ("libxdmcp6", "pool/main/libx/libxdmcp/libxdmcp6_1.1.2-3_amd64.deb", "ecb8536f5fb34543b55bb9dc5f5b14c9dbb4150a7bddb3f2287b7cab6e9d25ef"),
    ("libxext6", "pool/main/libx/libxext/libxext6_1.3.4-1+b1_amd64.deb", "504b7be9d7df4f6f4519e8dd4d6f9d03a9fb911a78530fa23a692fba3058cba6"),
    ("libxfixes3", "pool/main/libx/libxfixes/libxfixes3_6.0.0-2_amd64.deb", "1cd616396ff2ecae77e6e8b5b7695d414f0146de2d147837a2a02165f99e1a2c"),
    ("libxi6", "pool/main/libx/libxi/libxi6_1.8-1+b1_amd64.deb", "6c2fb5f241b311788990122c6e693915867cd8ed9d6da2e3524aec7ed3cdb4c0"),
    ("libxkbcommon0", "pool/main/libx/libxkbcommon/libxkbcommon0_1.5.0-1_amd64.deb", "e3fe045b9a33a101de1c5a912a4a10928db055c3f68930f47eccbb44d7c7d54e"),
    ("libxrandr2", "pool/main/libx/libxrandr/libxrandr2_1.5.2-2+b1_amd64.deb", "e2e10b672085ddf1d294cd689ed21bde5899325fd13626c2614b7d7b2d49a808"),
    ("libxrender1", "pool/main/libx/libxrender/libxrender1_0.9.10-1.1_amd64.deb", "b2a6d160578f359220101947c8d67059b44704a251e688de1d0b744fefedfd1a"),
    ("libzstd1", "pool/main/libz/libzstd/libzstd1_1.5.4+dfsg2-5_amd64.deb", "6315b5ac38b724a710fb96bf1042019398cb656718b1522279a5185ed39318fa"),
    ("zlib1g", "pool/main/z/zlib/zlib1g_1.2.13.dfsg-1_amd64.deb", "d7dd1d1411fedf27f5e27650a6eff20ef294077b568f4c8c5e51466dc7c08ce4"),
)

def chrome_headless_shell_url(version):
    """Returns the Chrome for Testing download URL for linux64 chrome-headless-shell."""
    if not version:
        fail("chrome-headless-shell version is required.")
    return "https://storage.googleapis.com/chrome-for-testing-public/{version}/linux64/chrome-headless-shell-linux64.zip".format(
        version = version,
    )

def validate_chrome_headless_shell_downloads(version, sha256, runtime_debs = CHROME_RUNTIME_DEB_PACKAGES):
    """Validates and returns the pinned download descriptors for chrome-headless-shell and its runtime libs.

    Every download goes through `require_sha256` so a missing checksum fails
    immediately rather than performing an unverified fetch.

    Args:
      version: The Chrome for Testing version string (e.g. `"155.0.8059.84"`).
      sha256: Expected SHA-256 hex digest of the `chrome-headless-shell-linux64.zip` archive.
      runtime_debs: Sequence of `(package_name, debian_pool_path, sha256)` tuples for runtime `.deb` packages.

    Returns:
      A `struct(browser_url, browser_sha256, runtime_debs)` with validated URLs and SHA-256 digests.
    """
    browser_url = chrome_headless_shell_url(version)
    verified_browser_sha256 = require_sha256(sha256, browser_url)
    verified_debs = []
    for pkg_name, pool_path, deb_sha256 in runtime_debs:
        deb_url = _DEBIAN_POOL_BASE_URL + pool_path
        verified_debs.append(struct(
            name = pkg_name,
            url = deb_url,
            sha256 = require_sha256(deb_sha256, deb_url),
        ))
    return struct(
        browser_url = browser_url,
        browser_sha256 = verified_browser_sha256,
        runtime_debs = verified_debs,
    )

_FONTS_CONF = """<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>/nonexistent</dir>
  <cachedir>/tmp/fontconfig-cache</cachedir>
</fontconfig>
"""

_BUILD_CONTENT = """# Generated by chrome_headless_shell_repo.bzl

exports_files(
    [
        "browser/chrome-headless-shell",
        "fonts/fonts.conf",
    ],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "chrome_headless_shell",
    srcs = ["browser/chrome-headless-shell"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "browser_files",
    srcs = glob(["browser/**"]),
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
        ":browser_files",
        ":runtime_libs",
        "fonts/fonts.conf",
    ],
    visibility = ["//visibility:public"],
)
"""

def _chrome_headless_shell_repo_impl(repository_ctx):
    spec = validate_chrome_headless_shell_downloads(
        version = repository_ctx.attr.version,
        sha256 = repository_ctx.attr.sha256,
    )

    pinned_download_and_extract(
        repository_ctx,
        url = spec.browser_url,
        sha256 = spec.browser_sha256,
        stripPrefix = "chrome-headless-shell-linux64",
        output = "browser",
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

    repository_ctx.file("fonts/fonts.conf", _FONTS_CONF)
    repository_ctx.file("BUILD.bazel", _BUILD_CONTENT)

chrome_headless_shell_repo = repository_rule(
    _chrome_headless_shell_repo_impl,
    doc = "Downloads Chrome for Testing chrome-headless-shell (linux64) and its pinned Debian runtime shared libraries.",
    attrs = {
        "version": attr.string(
            default = CHROME_HEADLESS_SHELL_VERSION,
            doc = "Chrome for Testing version (e.g. '155.0.8059.84').",
        ),
        "sha256": attr.string(
            default = CHROME_HEADLESS_SHELL_SHA256,
            doc = "Expected SHA-256 checksum of chrome-headless-shell-linux64.zip. Required: an empty value fails the fetch.",
        ),
    },
)
