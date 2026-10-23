"""Repository rule for the hermetic Linux headless virtual display and GTK/Mesa runtime libraries.

Downloads a pinned closure of Debian 12 (bookworm) amd64 `.deb` packages
providing `Xvfb`, `xkbcomp`, `xkb-data`, `fonts-dejavu-core`, GTK3, GLib,
Pango, Cairo, Fontconfig, libepoxy, libglvnd, and Mesa EGL/GLX/GLES software
rasterizer (`swrast_dri.so` / `llvmpipe`) — along with every transitive
`DT_NEEDED` shared library beyond glibc (`libc.so.6`, `libdl.so.2`,
`libm.so.6`, `libpthread.so.0`, `librt.so.1`, `libresolv.so.2`, `libutil.so.1`)
and the C++ runtime (`libgcc_s.so.1`, `libstdc++.so.6`).

Extracted entirely via Bazel's built-in JVM archive extractors (`ar`/`.deb` +
`tar.xz`) without relying on any host `ar`, `dpkg-deb`, or `xz` binaries.
"""

load(":artifact_urls.bzl", "require_sha256")
load(":download.bzl", "pinned_download_and_extract")

_DEBIAN_POOL_BASE_URL = "https://deb.debian.org/debian/"

# Complete transitive closure of Debian 12 (bookworm) amd64 packages required
# at runtime by Xvfb, xkbcomp, libflutter_linux_gtk.so, and the compiled GTK3
# Linux runner + Mesa software OpenGL ES / EGL rasterizer.
# Each entry is (package_name, debian_pool_path, sha256).
LINUX_HEADLESS_RUNTIME_DEB_PACKAGES = (
    ("fonts-dejavu-core", "pool/main/f/fonts-dejavu/fonts-dejavu-core_2.37-6_all.deb", "8892669e51aab4dc56682c8e39d8ddb7d70fad83c369344e1e240bf3ca22bb76"),
    ("libatk-bridge2.0-0", "pool/main/a/at-spi2-core/libatk-bridge2.0-0_2.46.0-5_amd64.deb", "fbb07714fdd3fdee7b63fd8595053f4fa8021d8e350a5de6281c6ce7cd4f158f"),
    ("libatk1.0-0", "pool/main/a/at-spi2-core/libatk1.0-0_2.46.0-5_amd64.deb", "909dd661e03760a9ba1529bfc772f259cec8431999ee38b7c5521186237cdd98"),
    ("libatspi2.0-0", "pool/main/a/at-spi2-core/libatspi2.0-0_2.46.0-5_amd64.deb", "1c0332f3b712a8e5ee56800bbcab83a8f92098874094f2b0bdfd6b7fd45e8b83"),
    ("libaudit1", "pool/main/a/audit/libaudit1_3.0.9-1_amd64.deb", "30954df4b5a7c505661ba8ae5e6ea94f5805e408899fb400783bb166eb5ff306"),
    ("libblkid1", "pool/main/u/util-linux/libblkid1_2.38.1-5+deb12u3_amd64.deb", "5a083377f29191cafcdf0f91ec124349b4a7895b531556633a136e43c6d53943"),
    ("libbrotli1", "pool/main/b/brotli/libbrotli1_1.0.9-2+b6_amd64.deb", "563b4caec1aa5e876bd3355b36e7a38e1484baf5a293b48d1e8bd22db786e4d7"),
    ("libbsd0", "pool/main/libb/libbsd/libbsd0_0.11.7-2_amd64.deb", "bb31cc8b40f962a85b2cec970f7f79cc704a1ae4bad24257a822055404b2c60b"),
    ("libbz2-1.0", "pool/main/b/bzip2/libbz2-1.0_1.0.8-5+b1_amd64.deb", "54149da3f44b22d523b26b692033b84503d822cc5122fed606ea69cc83ca5aeb"),
    ("libcairo-gobject2", "pool/main/c/cairo/libcairo-gobject2_1.16.0-7_amd64.deb", "5898b4c1093ff40bade7acb92affc4a5b5b76a1737cd41cfa2a09cdc2d864d4c"),
    ("libcairo2", "pool/main/c/cairo/libcairo2_1.16.0-7_amd64.deb", "927fa059f8b5791d0cd744d4e3a8c57fa872ef849ce14434dc2222ac8a076a69"),
    ("libcap-ng0", "pool/main/libc/libcap-ng/libcap-ng0_0.8.3-1+b3_amd64.deb", "b4b54769c77e4a71c8b33aee4d600ba28a9994a1c6f60d55d4ebe7fc44882e07"),
    ("libcap2", "pool/main/libc/libcap2/libcap2_2.66-4+deb12u3+b1_amd64.deb", "8d684c673e7483802a5c447834b0df6fce006eb3a7109e1be412f5ad425bb24f"),
    ("libdatrie1", "pool/main/libd/libdatrie/libdatrie1_0.2.13-2+b1_amd64.deb", "f021f193384929989b2dfd19f606a8cebe54b5f209fe387fc40683e810e01ebe"),
    ("libdbus-1-3", "pool/main/d/dbus/libdbus-1-3_1.14.10-1~deb12u1_amd64.deb", "18ee0ce5fab9f7b671e87da1e9fa18660e36e04a3402f24bdb8635e0ba1d35f6"),
    ("libdrm-amdgpu1", "pool/main/libd/libdrm/libdrm-amdgpu1_2.4.114-1+b1_amd64.deb", "b75a71e96f1faac0f131ac657e09efcbe8968eef62cc34b8abfcff2ff9f0cccd"),
    ("libdrm-intel1", "pool/main/libd/libdrm/libdrm-intel1_2.4.114-1+b1_amd64.deb", "b0e39318d14c07f4d85668b6da7f66a1341addf87a47d785c34d5a8b393f544c"),
    ("libdrm-nouveau2", "pool/main/libd/libdrm/libdrm-nouveau2_2.4.114-1+b1_amd64.deb", "ba59bb9ec6e1baf59fc4d4eb095a524e40d045af2413dad9d28df517005388b6"),
    ("libdrm-radeon1", "pool/main/libd/libdrm/libdrm-radeon1_2.4.114-1+b1_amd64.deb", "2da3a9233187f995ad5a3e6db3d37252ea7209f0ca9605484d03478ebcc15feb"),
    ("libdrm2", "pool/main/libd/libdrm/libdrm2_2.4.114-1+b1_amd64.deb", "be18fb670797ba32da9628cf3e8acd83160d8db8c8dd842501dd8e401c3b5371"),
    ("libedit2", "pool/main/libe/libedit/libedit2_3.1-20221030-2_amd64.deb", "1cf14abf2716d3279db12d0657a5737cf70074a1e71d3bdf73206625e3c89ce6"),
    ("libegl-mesa0", "pool/main/m/mesa/libegl-mesa0_22.3.6-1+deb12u2_amd64.deb", "731a406af777d0606dc932da21c2214f189069caa437b8bb4063c328bab840ca"),
    ("libegl1", "pool/main/libg/libglvnd/libegl1_1.6.0-1_amd64.deb", "fe4d8b39f6e6fe1a32ab1efd85893553eaa9cf3866aa668ccf355f585b37d523"),
    ("libelf1", "pool/main/e/elfutils/libelf1_0.188-2.1_amd64.deb", "619add379c606b3ac6c1a175853b918e6939598a83d8ebadf3bdfd50d10b3c8c"),
    ("libepoxy0", "pool/main/libe/libepoxy/libepoxy0_1.5.10-1_amd64.deb", "050cbedc9c2a5cce976151c720a3817f2103a01e6ac255bdd6f2c6a7509b04c3"),
    ("libexpat1", "pool/main/e/expat/libexpat1_2.5.0-1+deb12u2_amd64.deb", "2255e62fc22a86d2c544b8a3f516da9aee19383ad5742722ab4ce7f66a30dbc8"),
    ("libffi8", "pool/main/libf/libffi/libffi8_3.4.4-1_amd64.deb", "6d9f6c25c30efccce6d4bceaa48ea86c329a3432abb360a141f76ac223a4c34a"),
    ("libfontconfig1", "pool/main/f/fontconfig/libfontconfig1_2.14.1-4_amd64.deb", "16ee38d374e064f534116dc442b086ef26f9831f1c0af7e5fb4fe4512e700649"),
    ("libfontenc1", "pool/main/libf/libfontenc/libfontenc1_1.1.4-1_amd64.deb", "1d0aa6ea16a34a8de1ea170360c4cb699f3239aeddb292df2d2c4eb6e835de4b"),
    ("libfreetype6", "pool/main/f/freetype/libfreetype6_2.12.1+dfsg-5+deb12u4_amd64.deb", "8043e479f73f29992d652e3f9dfe8b17f9780c7ea6330afe379ec5f9f188ac44"),
    ("libfribidi0", "pool/main/f/fribidi/libfribidi0_1.0.8-2.1_amd64.deb", "87fce56627aab7b2968501d370aa3ed6d1c792119efa765e71a690bdfe570e62"),
    ("libgbm1", "pool/main/m/mesa/libgbm1_22.3.6-1+deb12u2_amd64.deb", "4323840f2b7b3e108990848529125d99c0956ae5a854c1e0568ed08c8faeaa2e"),
    ("libgcrypt20", "pool/main/libg/libgcrypt20/libgcrypt20_1.10.1-3+deb12u1_amd64.deb", "e7a56552139c693904a6f9712234c05fe918353273a7cbdb5e62f423ad71bb97"),
    ("libgdk-pixbuf-2.0-0", "pool/main/g/gdk-pixbuf/libgdk-pixbuf-2.0-0_2.42.10+dfsg-1+deb12u4_amd64.deb", "19673127f2530deb7cf637c688a4e16384e6887627296e16b8169038928cadc3"),
    ("libgl1", "pool/main/libg/libglvnd/libgl1_1.6.0-1_amd64.deb", "6f89b1702c48e9a2437bb3c1ffac8e1ab2d828fc28b3d14b2eecd4cc19b2c790"),
    ("libgl1-mesa-dri", "pool/main/m/mesa/libgl1-mesa-dri_22.3.6-1+deb12u2_amd64.deb", "350e4263aaacd521f6f757951262b57c003930edaf0419508f2c5675317577fe"),
    ("libglapi-mesa", "pool/main/m/mesa/libglapi-mesa_22.3.6-1+deb12u2_amd64.deb", "2db5b13a6b7f4042f9a417ad7fa4338b6c47528dc64d7f89cfd5e53d07d76bc4"),
    ("libgles2", "pool/main/libg/libglvnd/libgles2_1.6.0-1_amd64.deb", "07b2f51b8aa3c8d6d928133cd46087bd8793d0d67c203f09fc289d45a2cf5f47"),
    ("libglib2.0-0", "pool/main/g/glib2.0/libglib2.0-0_2.74.6-2+deb12u9_amd64.deb", "7ff85197685d89e150e342b29a59aab1beee400050ba7da73de81cd999ffee5a"),
    ("libglvnd0", "pool/main/libg/libglvnd/libglvnd0_1.6.0-1_amd64.deb", "b6da5b153dd62d8b5e5fbe25242db1fc05c068707c365db49abda8c2427c75f8"),
    ("libglx-mesa0", "pool/main/m/mesa/libglx-mesa0_22.3.6-1+deb12u2_amd64.deb", "88e7ffa61f1a0a86c30736ad7657ab4774c9b711bbaff76cef0bd32ffb85ec90"),
    ("libglx0", "pool/main/libg/libglvnd/libglx0_1.6.0-1_amd64.deb", "95f568df73dedf43ae66834a75502112e0d4f3ad7124f3dbfa790b739383b896"),
    ("libgpg-error0", "pool/main/libg/libgpg-error/libgpg-error0_1.46-1_amd64.deb", "89944ee11d7370ce6ef46fc52f094c4a6512eff8943ec4c6ebefeae6360ceada"),
    ("libgraphite2-3", "pool/main/g/graphite2/libgraphite2-3_1.3.14-1+deb12u1_amd64.deb", "c19a7f6ba9298db7eef041ae27b08985f2c02009e418063f8bccdb5bc5e858dc"),
    ("libgtk-3-0", "pool/main/g/gtk+3.0/libgtk-3-0_3.24.38-2~deb12u3_amd64.deb", "0ff7375c98b5a8d6aafc6096b21d9f7bae4ecb581d31fce5d37be18f55b489a2"),
    ("libharfbuzz0b", "pool/main/h/harfbuzz/libharfbuzz0b_6.0.0+dfsg-3_amd64.deb", "bfce132b7ee67b9c2d2166075b1936a25c8cc6866b6a049f99b8e94baa916e71"),
    ("libicu72", "pool/main/i/icu/libicu72_72.1-3+deb12u1_amd64.deb", "f7f6f99c6d7b025914df2447fc93e11d22c44c0c8bdd8b6f36691c9e7ddcef88"),
    ("libjpeg62-turbo", "pool/main/libj/libjpeg-turbo/libjpeg62-turbo_2.1.5-2_amd64.deb", "95ec30140789a342add8f8371ed018924de51b539056522b66f207b25cba9cad"),
    ("libllvm15", "pool/main/l/llvm-toolchain-15/libllvm15_15.0.6-4+b1_amd64.deb", "9f0751109ba89e65b1313a4f3e34a29977a0db6fa30ed475e2c6bd555fa9e866"),
    ("liblz4-1", "pool/main/l/lz4/liblz4-1_1.9.4-1_amd64.deb", "64cde86cef1deaf828bd60297839b59710b5cd8dc50efd4f12643caaee9389d3"),
    ("liblzma5", "pool/main/x/xz-utils/liblzma5_5.4.1-1+deb12u1_amd64.deb", "f96d8876b53ec89d76a992bc199679b818cf518225a768954d9451fb556a4eb7"),
    ("libmd0", "pool/main/libm/libmd/libmd0_1.0.4-2_amd64.deb", "03539fd30c509e27101d13a56e52eda9062bdf1aefe337c07ab56def25a13eab"),
    ("libmount1", "pool/main/u/util-linux/libmount1_2.38.1-5+deb12u3_amd64.deb", "f46e2d6b006951825adde9757790b6609d7c66c7700f9b68f3db913eaac323c3"),
    ("libpango-1.0-0", "pool/main/p/pango1.0/libpango-1.0-0_1.50.12+ds-1_amd64.deb", "851720de07441ae6bb6a7f51fc0f2edb4db7aa6f25b5bf1bf7b72dcab8947b7f"),
    ("libpangocairo-1.0-0", "pool/main/p/pango1.0/libpangocairo-1.0-0_1.50.12+ds-1_amd64.deb", "96695f9cdd3bf346e3555cf0aa158e23a36114d6dec203b00ab4e93f1b77aab9"),
    ("libpangoft2-1.0-0", "pool/main/p/pango1.0/libpangoft2-1.0-0_1.50.12+ds-1_amd64.deb", "78da3f494109f6e7a39c4626aaae7571c600c5854cecda0bc0c902224986a63b"),
    ("libpciaccess0", "pool/main/libp/libpciaccess/libpciaccess0_0.17-2_amd64.deb", "4025f3608cf431c163efb94fdc553e7b93e16b8f0d741ea87762e19025ffc80e"),
    ("libpcre2-8-0", "pool/main/p/pcre2/libpcre2-8-0_10.42-1_amd64.deb", "030db54f4d76cdfe2bf0e8eb5f9efea0233ab3c7aa942d672c7b63b52dbaf935"),
    ("libpixman-1-0", "pool/main/p/pixman/libpixman-1-0_0.42.2-1_amd64.deb", "9ed75ef81b6b1eba9e1357f8b0ce01d31112b0e07b2b685bee2cf627a8932892"),
    ("libpng16-16", "pool/main/libp/libpng1.6/libpng16-16_1.6.39-2+deb12u5_amd64.deb", "a56d64bfaa9da12aafb83347909e62e6fd5fd251e6b34c194065911a30359978"),
    ("libselinux1", "pool/main/libs/libselinux/libselinux1_3.4-1+b6_amd64.deb", "2b07f5287b9105f40158b56e4d70cc1652dac56a408f3507b4ab3d061eed425f"),
    ("libsensors5", "pool/main/l/lm-sensors/libsensors5_3.6.0-7.1_amd64.deb", "b7eb91dce728fbb9203aec8b22637303b29821c3384e5f78a8ff348b4e44efe3"),
    ("libsystemd0", "pool/main/s/systemd/libsystemd0_252.39-1~deb12u2_amd64.deb", "013c07514a9e4933b2d5c098018695a6aa42d085dbc483ce2c094a954c8a1b0a"),
    ("libthai0", "pool/main/libt/libthai/libthai0_0.1.29-1_amd64.deb", "37cd66bef851ea0e4af807797ba3ad14d43226f7c4954c1d0a19478e11815bae"),
    ("libtinfo6", "pool/main/n/ncurses/libtinfo6_6.4-4_amd64.deb", "072d908f38f51090ca28ca5afa3b46b2957dc61fe35094c0b851426859a49a51"),
    ("libunwind8", "pool/main/libu/libunwind/libunwind8_1.6.2-3_amd64.deb", "7b297868682836e4c87be349f17e4a56bc287586e3576503e84a5cb5485ce925"),
    ("libwayland-client0", "pool/main/w/wayland/libwayland-client0_1.21.0-1_amd64.deb", "1f002d028b8b79eec9847c636d8886d10dfe8c884cc2bebe18086b1391c5a28d"),
    ("libwayland-cursor0", "pool/main/w/wayland/libwayland-cursor0_1.21.0-1_amd64.deb", "0b684467ec795024fcaae99ea4384959cc4052b2da5adec38c9b76dfed9bcf41"),
    ("libwayland-egl1", "pool/main/w/wayland/libwayland-egl1_1.21.0-1_amd64.deb", "cb4225f0e15e00a3570d4cbc288c87ff477d73e741c3f1c5a6d47cf350d45378"),
    ("libwayland-server0", "pool/main/w/wayland/libwayland-server0_1.21.0-1_amd64.deb", "df0396221d7b794496a687ec61fae82b6465648bc0ab6501ba0a5ed7f56eb8d6"),
    ("libx11-6", "pool/main/libx/libx11/libx11-6_1.8.4-2+deb12u2_amd64.deb", "d88c973e79fd9b65838d77624142952757e47a6eb1a58602acf0911cf35989f4"),
    ("libx11-xcb1", "pool/main/libx/libx11/libx11-xcb1_1.8.4-2+deb12u2_amd64.deb", "f5da45e1d881a793250a96613f28c471a248877f1a0f18a5c90e2a620a76c898"),
    ("libxau6", "pool/main/libx/libxau/libxau6_1.0.9-1_amd64.deb", "679db1c4579ec7c61079adeaae8528adeb2e4bf5465baa6c56233b995d714750"),
    ("libxcb-dri2-0", "pool/main/libx/libxcb/libxcb-dri2-0_1.15-1_amd64.deb", "ef4959aa9e09a0d38d1de432e747585129d5d2dc1d84c8b6b3d2ffc3708b5805"),
    ("libxcb-dri3-0", "pool/main/libx/libxcb/libxcb-dri3-0_1.15-1_amd64.deb", "02699b144b9467de8636d27a76984b8f4e7b66e2d25d96df2b9677be86ee9a29"),
    ("libxcb-glx0", "pool/main/libx/libxcb/libxcb-glx0_1.15-1_amd64.deb", "1bce55fc292d93fa5f7fa50f84cef99ec29be70d0ffe98e86b8008e59f4a34fa"),
    ("libxcb-present0", "pool/main/libx/libxcb/libxcb-present0_1.15-1_amd64.deb", "89383e627a4d17b9390d609b2459481bfd2029566367b43068586769e418b6e5"),
    ("libxcb-randr0", "pool/main/libx/libxcb/libxcb-randr0_1.15-1_amd64.deb", "f86e3d8ff8622871008833e9d064919b7a6237399c903c59fc330ff00f199ff5"),
    ("libxcb-render0", "pool/main/libx/libxcb/libxcb-render0_1.15-1_amd64.deb", "29c32cc76be9393f409378be79a0f534b9f07dea06ae52fa80a7f27e298de239"),
    ("libxcb-shm0", "pool/main/libx/libxcb/libxcb-shm0_1.15-1_amd64.deb", "c1afcef29dc78b95c475159b181b28b1dedaf1d5aa06efd2fa6d90c73bfbe0e5"),
    ("libxcb-sync1", "pool/main/libx/libxcb/libxcb-sync1_1.15-1_amd64.deb", "3366ce715220d38dd0148b78a8e738137bade25ef7eec0698850c6f66800844f"),
    ("libxcb-xfixes0", "pool/main/libx/libxcb/libxcb-xfixes0_1.15-1_amd64.deb", "d744a7ebad2cbcf301c96cd6a1ab3ee856e436fc7be5cff5b7c28ac2ac181a64"),
    ("libxcb1", "pool/main/libx/libxcb/libxcb1_1.15-1_amd64.deb", "fdc61332a3892168f3cc9cfa1fe9cf11a91dc3e0acacbc47cbc50ebaa234cc71"),
    ("libxcomposite1", "pool/main/libx/libxcomposite/libxcomposite1_0.4.5-1_amd64.deb", "4c26ebf519d2ebc22fc1416dee45e12c4c4ef68aa9b2ed890356830df42b652a"),
    ("libxcursor1", "pool/main/libx/libxcursor/libxcursor1_1.2.1-1_amd64.deb", "49e167048661be4c614fff81429e9eaef38e54ef1d2150a5d2a8c53919217529"),
    ("libxdamage1", "pool/main/libx/libxdamage/libxdamage1_1.1.6-1_amd64.deb", "fcdf7e4c29b307ba8711c864e1e646d76315a8f55121198143653e56592fa8a7"),
    ("libxdmcp6", "pool/main/libx/libxdmcp/libxdmcp6_1.1.2-3_amd64.deb", "ecb8536f5fb34543b55bb9dc5f5b14c9dbb4150a7bddb3f2287b7cab6e9d25ef"),
    ("libxext6", "pool/main/libx/libxext/libxext6_1.3.4-1+b1_amd64.deb", "504b7be9d7df4f6f4519e8dd4d6f9d03a9fb911a78530fa23a692fba3058cba6"),
    ("libxfixes3", "pool/main/libx/libxfixes/libxfixes3_6.0.0-2_amd64.deb", "1cd616396ff2ecae77e6e8b5b7695d414f0146de2d147837a2a02165f99e1a2c"),
    ("libxfont2", "pool/main/libx/libxfont/libxfont2_2.0.6-1_amd64.deb", "79b19a4170c015607096613e726a07dc5e55a516bf79adc770a883d4aec20d87"),
    ("libxi6", "pool/main/libx/libxi/libxi6_1.8-1+b1_amd64.deb", "6c2fb5f241b311788990122c6e693915867cd8ed9d6da2e3524aec7ed3cdb4c0"),
    ("libxinerama1", "pool/main/libx/libxinerama/libxinerama1_1.1.4-3_amd64.deb", "8dde8f74d2fc001f306fb1295a86850145e93191d35c983c7f52eb21b0a7f8cb"),
    ("libxkbcommon0", "pool/main/libx/libxkbcommon/libxkbcommon0_1.5.0-1_amd64.deb", "e3fe045b9a33a101de1c5a912a4a10928db055c3f68930f47eccbb44d7c7d54e"),
    ("libxkbfile1", "pool/main/libx/libxkbfile/libxkbfile1_1.1.0-1_amd64.deb", "7c58d9986f918b71568ad83dbb6f4ab22c185f243461d41acee920cc5e13d347"),
    ("libxml2", "pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3~deb12u6_amd64.deb", "4460e39dda10a815881374217cde08474747cfa018358cd8612c14b390eff53b"),
    ("libxrandr2", "pool/main/libx/libxrandr/libxrandr2_1.5.2-2+b1_amd64.deb", "e2e10b672085ddf1d294cd689ed21bde5899325fd13626c2614b7d7b2d49a808"),
    ("libxrender1", "pool/main/libx/libxrender/libxrender1_0.9.10-1.1_amd64.deb", "b2a6d160578f359220101947c8d67059b44704a251e688de1d0b744fefedfd1a"),
    ("libxshmfence1", "pool/main/libx/libxshmfence/libxshmfence1_1.3-1_amd64.deb", "1a38142e40e3d32dc4f9a326bf5617363b7d9b4bb762fdcdd262f2192092024d"),
    ("libxxf86vm1", "pool/main/libx/libxxf86vm/libxxf86vm1_1.1.4-1+b2_amd64.deb", "6f4ca916aaec26d7000fa7f58de3f71119309ab7590ce1f517abfe1825a676c7"),
    ("libz3-4", "pool/main/z/z3/libz3-4_4.8.12-3.1_amd64.deb", "6221ca25ad5abcfbe1965801029d85a88b4775320384b4b716de8fab7a4d2f7a"),
    ("libzstd1", "pool/main/libz/libzstd/libzstd1_1.5.4+dfsg2-5_amd64.deb", "6315b5ac38b724a710fb96bf1042019398cb656718b1522279a5185ed39318fa"),
    ("x11-xkb-utils", "pool/main/x/x11-xkb-utils/x11-xkb-utils_7.7+7_amd64.deb", "b25970e444fadf4717e5624bc2a2eecef785d09d731b571da8d43f5297b43b12"),
    ("xkb-data", "pool/main/x/xkeyboard-config/xkb-data_2.35.1-1_all.deb", "28a79c61b785f403da93af58c39aed13c022032935e3e54362c6707169cfe982"),
    ("xvfb", "pool/main/x/xorg-server/xvfb_21.1.7-3+deb12u12_amd64.deb", "7f98f5ddc39593249330fa2612949b6298618b945becb2d9d7b598e7ca789ea0"),
    ("zlib1g", "pool/main/z/zlib/zlib1g_1.2.13.dfsg-1_amd64.deb", "d7dd1d1411fedf27f5e27650a6eff20ef294077b568f4c8c5e51466dc7c08ce4"),
)

def validate_linux_headless_runtime_downloads(runtime_debs = LINUX_HEADLESS_RUNTIME_DEB_PACKAGES):
    """Validates and returns the pinned download descriptors for the Linux headless runtime.

    Every download goes through `require_sha256` so a missing checksum fails
    immediately rather than performing an unverified fetch.

    Args:
        runtime_debs: Sequence of `(pkg_name, pool_path, sha256)` tuples.

    Returns:
        A struct with `runtime_debs` containing validated download descriptors.
    """
    if not runtime_debs:
        fail("Linux headless runtime requires at least one pinned .deb package.")
    verified_debs = []
    for pkg_name, pool_path, deb_sha256 in runtime_debs:
        if not pkg_name:
            fail("Linux headless runtime package name is required.")
        if not pool_path:
            fail("Linux headless runtime pool_path is required for package {}.".format(pkg_name))
        deb_url = _DEBIAN_POOL_BASE_URL + pool_path
        verified_debs.append(struct(
            name = pkg_name,
            url = deb_url,
            sha256 = require_sha256(deb_sha256, deb_url),
        ))
    return struct(
        runtime_debs = verified_debs,
    )

_FONTS_CONF = """<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>/nonexistent</dir>
  <cachedir>/tmp/fontconfig-cache</cachedir>
</fontconfig>
"""

_BUILD_CONTENT = """# Generated by linux_headless_runtime_repo.bzl

exports_files(
    [
        "sysroot/usr/bin/Xvfb",
        "sysroot/usr/bin/xkbcomp",
        "fonts/fonts.conf",
    ],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "xvfb",
    srcs = ["sysroot/usr/bin/Xvfb"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "xkbcomp",
    srcs = ["sysroot/usr/bin/xkbcomp"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "xkb_data",
    srcs = glob(["sysroot/usr/share/X11/xkb/**"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "egl_vendor_files",
    srcs = glob(["sysroot/usr/share/glvnd/egl_vendor.d/**"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "font_files",
    srcs = glob(["sysroot/usr/share/fonts/**"]),
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
        ":egl_vendor_files",
        ":font_files",
        ":runtime_libs",
        ":xkb_data",
        ":xkbcomp",
        ":xvfb",
        "fonts/fonts.conf",
    ],
    visibility = ["//visibility:public"],
)
"""

def _linux_headless_runtime_repo_impl(repository_ctx):
    spec = validate_linux_headless_runtime_downloads()

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

linux_headless_runtime_repo = repository_rule(
    _linux_headless_runtime_repo_impl,
    doc = "Downloads Xvfb, xkbcomp, xkb-data, GTK3, and Mesa software OpenGL ES / EGL runtime libraries from pinned Debian 12 (bookworm) amd64 packages.",
)
