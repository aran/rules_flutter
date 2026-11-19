"""A stand-in for a flutter/flutter checkout with a built engine, made of the official artifacts.

The release's artifacts are laid out the way a checkout and its engine out dirs
hold them (README.md, "Custom engines and frameworks"), with `args.gn`
files written to match, so the adapters read a tree they cannot tell from a
developer's, and the binaries in it are real and run.

The iOS and Android out dirs are laid out the same way: `ios_debug_sim_arm64`
(the simulator, a one-slice `Flutter.xcframework`), `ios_profile` and `ios_release`
(devices), and `android_<mode>_arm64` and `android_<mode>_x64` (a `flutter.jar`,
and the gen_snapshot of the AOT modes in `universal/`, where a Mac build puts the
one that runs on both Mac CPUs).

The Linux and Windows out dirs (`linux_<mode>[_arm64]`, `win_<mode>`) are laid out
the same way, as engines built on their own OS and read here for a cross build,
and `wasm_release` holds the web SDK as `flutter_web_sdk/`.

With `gen_snapshot_mismatch`, the release gen_snapshot is a copy with its VM
snapshot hash changed, as another VM's build would have it: the mismatch the check exists to refuse.
Every platform's AOT gen_snapshot is replaced by it. With
`web_kernel_format_mismatch` the web SDK's dart2js platform dill is of another
kernel format, the web's version of the same mismatch.
"""

# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private:generated_repos.bzl", "FLUTTER_VERSIONS")

_RELEASE = "3.50.0"
_OUT = "checkout/engine/src/out/"

def _args_gn(mode, revision, cpu = "arm64"):
    return "\n".join([
        'target_cpu = "{}"'.format(cpu),
        'flutter_runtime_mode = "{}"'.format(mode),
        "flutter_prebuilt_dart_sdk = false",
        'engine_version = "{}"'.format(revision),
        'content_hash = "stock-artifacts"',
        'dart_version = "stock-artifacts"',
        "",
    ])

def _mobile_args_gn(os, mode, cpu, revision, simulator = False):
    return "\n".join([
        'target_os = "{}"'.format(os),
        'target_cpu = "{}"'.format(cpu),
        'flutter_runtime_mode = "{}"'.format(mode),
        "use_ios_simulator = {}".format("true" if simulator else "false"),
        'engine_version = "{}"'.format(revision),
        'content_hash = "stock-artifacts"',
        'dart_version = "stock-artifacts"',
        "",
    ])

# The xcframework a `ninja flutter_framework` makes of one built Flutter.framework:
# its one platform directory, and the Info.plist that names it.
def _xcframework_info(identifier, architecture, simulator):
    return """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>LibraryIdentifier</key>
			<string>{identifier}</string>
			<key>LibraryPath</key>
			<string>Flutter.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>{architecture}</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>{variant}
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
""".format(
        identifier = identifier,
        architecture = architecture,
        variant = "\n\t\t\t<key>SupportedPlatformVariant</key>\n\t\t\t<string>simulator</string>" if simulator else "",
    )

def _dart_source(path, link):
    """The Dart source a synced checkout has at engine/src/flutter/third_party/dart, as far as outline compiles read it.

    The release Dart's `pkg/kernel` and `pkg/_fe_analyzer_shared`, from the
    release SDK's outline repository: the stand-in's compiler is the release's.
    """
    dart_source = path("@flutter_outline_tool_src//:kernel/pubspec.yaml").dirname.dirname
    for package in ["kernel", "_fe_analyzer_shared"]:
        link(dart_source.get_child(package), "checkout/engine/src/flutter/third_party/dart/pkg/" + package)

def _git_history(rctx):
    """Makes the checkout a git checkout at the release's tag, from which its version is told.

    One commit of the tree, as `git clone` of the tag leaves it: the out dirs
    and `bin/cache` are ignored, as a checkout's are. The commit is made
    without the machine's git configuration, at a fixed date, by a fixed
    name.
    """
    environment = {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_COUNT": "0",
        "GIT_AUTHOR_NAME": "stand-in",
        "GIT_AUTHOR_EMAIL": "stand-in@example.com",
        "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z",
        "GIT_COMMITTER_NAME": "stand-in",
        "GIT_COMMITTER_EMAIL": "stand-in@example.com",
        "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
    }
    rctx.file("checkout/.gitignore", "/bin/cache/\n/engine/src/out/\n")
    checkout = str(rctx.path("checkout"))
    for args in [
        ["init", "--quiet", "--initial-branch=stable"],
        ["add", "--all"],
        ["commit", "--quiet", "--message=A stand-in for a flutter/flutter checkout."],
        ["tag", _RELEASE],
    ]:
        result = rctx.execute(["git", "-C", checkout] + args, environment = environment)
        if result.return_code != 0:
            fail("could not make the stand-in checkout a git checkout: git {}: {}".format(" ".join(args), result.stderr))

def _windows_checkout(rctx, path, link, meta):
    """A checkout built on an x86_64 Windows machine: its host build holds the engine too.

    `tools/gn` names the machine's own build `host_<mode>`, and it holds the
    Windows embedder and the machine's gen_snapshot beside the host tools, so
    there are no `win_<mode>` directories (the machine's own would make every
    Windows slot ambiguous). The Dart SDK is the prebuilt one in
    `engine/src/flutter/prebuilts/windows-x64`, which `flutter_prebuilt_dart_sdk`
    names.
    """
    host = "@flutter_windows-x64//:"
    dart_sdk = path(host + "dart-sdk/bin/dart.exe").dirname.dirname
    host_tools = path(host + "host-tools/icudtl.dat").dirname
    font_tools = path(host + "font-subset-tools/font-subset.exe").dirname
    kernel_debug = path("@flutter_stock_engine//kernel/debug:flutter_patched_sdk/platform_strong.dill").dirname
    kernel_release = path("@flutter_stock_engine//kernel/release:flutter_patched_sdk_product/platform_strong.dill").dirname
    dev_root = path("@flutter_dev_root_src//:bin/cache/flutter.version.json").dirname.dirname.dirname

    link(dev_root.get_child("packages"), "checkout/packages")
    link(dev_root.get_child("bin").get_child("cache").get_child("flutter.version.json"), "checkout/bin/cache/flutter.version.json")
    rctx.file("checkout/bin/internal/material_fonts.version", meta.material_fonts_url + "\n")
    rctx.file("checkout/CHECKOUT", "A stand-in for a flutter/flutter checkout.\n")
    rctx.file("checkout/engine/src/ENGINE_SRC", "A stand-in for a checkout's engine source directory.\n")
    _dart_source(path, link)

    for mode in ["debug", "profile", "release"]:
        engine = path("@flutter_desktop_engine_windows-x64_{}//:engine/flutter_windows.dll".format(mode)).dirname
        out = _OUT + "host_{}/".format(mode)
        rctx.file(out + "args.gn", _args_gn(mode, meta.engine_revision, "x64").replace("flutter_prebuilt_dart_sdk = false", "flutter_prebuilt_dart_sdk = true"))
        for name in [
            "flutter_windows.dll",
            "flutter_windows.dll.lib",
            "flutter_export.h",
            "flutter_windows.h",
            "flutter_messenger.h",
            "flutter_plugin_registrar.h",
            "flutter_texture_registrar.h",
        ]:
            link(engine.get_child(name), out + name)
        link(engine.dirname.get_child("cpp-client-wrapper").get_child("cpp_client_wrapper"), out + "cpp_client_wrapper")
        if mode != "debug":
            link(engine.get_child("gen_snapshot.exe"), out + "gen_snapshot/gen_snapshot.exe")

    debug = _OUT + "host_debug/"
    link(dev_root.get_child("bin").get_child("cache").get_child("pkg").get_child("sky_engine"), debug + "gen/dart-pkg/sky_engine")
    link(dart_sdk, "checkout/engine/src/flutter/prebuilts/windows-x64/dart-sdk")
    for name in ["flutter_tester.exe", "icudtl.dat", "impellerc.exe", "shader_lib"]:
        link(host_tools.get_child(name), debug + name)
    link(font_tools.get_child("font-subset.exe"), debug + "font-subset.exe")
    for name in ["vm_isolate_snapshot.bin", "isolate_snapshot.bin"]:
        link(host_tools.get_child(name), debug + "gen/flutter/lib/snapshot/" + name)
    link(kernel_debug, debug + "flutter_patched_sdk")
    link(kernel_release, _OUT + "host_release/flutter_patched_sdk")
    _web_out_dir(rctx, path, link, meta.engine_revision, False)
    _git_history(rctx)
    rctx.file("BUILD.bazel", 'exports_files(glob(["checkout/CHECKOUT", "checkout/engine/src/ENGINE_SRC"]))\n')

def _fake_checkout_impl(rctx):
    def path(label):
        return rctx.path(Label(label))

    def link(source, destination):
        rctx.symlink(source, destination)

    meta = FLUTTER_VERSIONS[_RELEASE]
    if rctx.os.name.lower().startswith("windows"):
        _windows_checkout(rctx, path, link, meta)
        return

    # The machine's own build is `host_<mode>`: `host_<mode>_arm64` on a Mac,
    # and on an x86_64 Linux machine `host_<mode>`, which also holds the Linux
    # engine. Only these two hosts have a stand-in.
    on_linux = rctx.os.name == "linux"
    if on_linux and rctx.os.arch not in ["amd64", "x86_64"]:
        fail("the stand-in checkout is made on an arm64 Mac or an x86_64 Linux machine, not on {} {}".format(rctx.os.name, rctx.os.arch))
    host = "linux-x64" if on_linux else "darwin-arm64"
    suffix = "" if on_linux else "_arm64"
    dart_sdk = path("@flutter_{}//:dart-sdk/bin/dart".format(host)).dirname.dirname
    host_tools = path("@flutter_{}//:host-tools/icudtl.dat".format(host)).dirname
    font_tools = path("@flutter_{}//:font-subset-tools/font-subset".format(host)).dirname
    kernel_debug = path("@flutter_stock_engine//kernel/debug:flutter_patched_sdk/platform_strong.dill").dirname
    kernel_release = path("@flutter_stock_engine//kernel/release:flutter_patched_sdk_product/platform_strong.dill").dirname
    dev_root = path("@flutter_dev_root_src//:bin/cache/flutter.version.json").dirname.dirname.dirname

    # The framework: packages/, what bin/internal holds and the version file
    # a run of flutter_tools leaves. Its sky_engine is the host build's.
    link(dev_root.get_child("packages"), "checkout/packages")
    link(dev_root.get_child("bin").get_child("cache").get_child("flutter.version.json"), "checkout/bin/cache/flutter.version.json")
    rctx.file("checkout/bin/internal/material_fonts.version", meta.material_fonts_url + "\n")
    rctx.file("checkout/CHECKOUT", "A stand-in for a flutter/flutter checkout.\n")
    rctx.file("checkout/engine/src/ENGINE_SRC", "A stand-in for a checkout's engine source directory.\n")
    _dart_source(path, link)

    # The release gen_snapshot, or one of another VM.
    release_gen = path("@flutter_desktop_engine_linux-x64_release//:engine/gen_snapshot") if on_linux else path("@flutter_darwin-arm64//:host-tools-release/gen_snapshot")
    other = rctx.attr.gen_snapshot_mismatch
    if other:
        # Another VM's build differs in its snapshot hash, a run of 32 hex
        # characters: change the first of each such run in a copy.
        other_gen = rctx.path("other_dart/gen_snapshot")
        rctx.execute(["mkdir", "-p", str(other_gen.dirname)])
        rctx.execute(["cp", release_gen, other_gen])
        rctx.execute(["chmod", "u+w", other_gen])
        rewrite = rctx.execute(["perl", "-pi", "-e", 's/(?<![0-9a-f])([0-9a-f])([0-9a-f]{31})(?![0-9a-f])/($1 eq "f" ? "0" : "f") . $2/ge', other_gen])
        if rewrite.return_code != 0:
            fail("could not rewrite the snapshot hash of {}: {}".format(other_gen, rewrite.stderr))
        release_gen = other_gen
    profile_gen = path("@flutter_desktop_engine_linux-x64_profile//:engine/gen_snapshot") if on_linux else path("@flutter_darwin-arm64_profile//:host-tools/gen_snapshot")

    # host_debug: the host tools, the debug platform kernel and the debug engine.
    cpu = "x64" if on_linux else "arm64"
    debug = _OUT + "host_debug{}/".format(suffix)
    rctx.file(debug + "args.gn", _args_gn("debug", meta.engine_revision, cpu))
    link(dart_sdk, debug + "dart-sdk")
    for name in ["flutter_tester", "icudtl.dat", "impellerc", "shader_lib"]:
        link(host_tools.get_child(name), debug + name)
    link(dev_root.get_child("bin").get_child("cache").get_child("pkg").get_child("sky_engine"), debug + "gen/dart-pkg/sky_engine")
    link(font_tools.get_child("font-subset"), debug + "font-subset")
    for name in ["vm_isolate_snapshot.bin", "isolate_snapshot.bin"]:
        link(host_tools.get_child(name), debug + "gen/flutter/lib/snapshot/" + name)
    link(kernel_debug, debug + "flutter_patched_sdk")

    # An out dir holds the product platform kernel under the same name.
    release = _OUT + "host_release{}/".format(suffix)
    rctx.file(release + "args.gn", _args_gn("release", meta.engine_revision, cpu))
    link(kernel_release, release + "flutter_patched_sdk")
    link(release_gen, release + "gen_snapshot" + suffix)
    profile = _OUT + "host_profile{}/".format(suffix)
    rctx.file(profile + "args.gn", _args_gn("profile", meta.engine_revision, cpu))
    link(profile_gen, profile + "gen_snapshot" + suffix)

    for mode, out in [("debug", debug), ("profile", profile), ("release", release)]:
        if on_linux:
            # The host build holds the Linux engine, as `ninja -C out/host_<mode>` leaves it.
            library = path("@flutter_desktop_engine_linux-x64_{}//:engine/libflutter_linux_gtk.so".format(mode))
            link(library, out + "libflutter_linux_gtk.so")
            link(library.dirname.get_child("flutter_linux"), out + "flutter_linux")
        else:
            framework = path("@flutter_desktop_engine_darwin-x64_{}//:engine/FlutterMacOS.framework/Versions/A/FlutterMacOS".format(mode)).dirname.dirname.dirname
            link(framework, out + "FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework")

    # The iOS and Android out dirs are laid out from Apple-host gen_snapshots.
    if not on_linux:
        _mobile_out_dirs(rctx, path, link, meta.engine_revision, other_gen = rctx.path("other_dart/gen_snapshot") if other else None)
    _desktop_out_dirs(rctx, path, link, meta.engine_revision, on_linux)
    _web_out_dir(rctx, path, link, meta.engine_revision, rctx.attr.web_kernel_format_mismatch)
    _git_history(rctx)

    rctx.file("BUILD.bazel", 'exports_files(glob(["checkout/CHECKOUT", "checkout/engine/src/ENGINE_SRC"]))\n')

def _desktop_out_dirs(rctx, path, link, revision, on_linux):
    """The Linux and Windows out dirs: the official engines, laid out as ninja leaves them.

    A Mac cannot build either, so these stand for engines built on their own
    OS and read here for a cross build: `linux_<mode>[_arm64]` and `win_<mode>`.
    """
    for arch, suffix in [("x64", ""), ("arm64", "_arm64")]:
        # An x86_64 Linux machine's own engine is its host build.
        if on_linux and arch == "x64":
            continue
        for mode in ["debug", "profile", "release"]:
            repo = "@flutter_desktop_engine_linux-{}_{}".format(arch, mode)
            library = path(repo + "//:engine/libflutter_linux_gtk.so")
            out = _OUT + "linux_{}{}/".format(mode, suffix)
            rctx.file(out + "args.gn", _mobile_args_gn("linux", mode, arch, revision))
            link(library, out + "libflutter_linux_gtk.so")
            link(library.dirname.get_child("flutter_linux"), out + "flutter_linux")

    for mode in ["debug", "profile", "release"]:
        repo = "@flutter_desktop_engine_windows-x64_" + mode
        engine = path(repo + "//:engine/flutter_windows.dll").dirname
        out = _OUT + "win_{}/".format(mode)
        rctx.file(out + "args.gn", _mobile_args_gn("win", mode, "x64", revision))
        for name in [
            "flutter_windows.dll",
            "flutter_windows.dll.lib",
            "flutter_export.h",
            "flutter_windows.h",
            "flutter_messenger.h",
            "flutter_plugin_registrar.h",
            "flutter_texture_registrar.h",
        ]:
            link(engine.get_child(name), out + name)
        link(engine.dirname.get_child("cpp-client-wrapper").get_child("cpp_client_wrapper"), out + "cpp_client_wrapper")

def _web_out_dir(rctx, path, link, revision, mismatched):
    """`wasm_release`: the official web SDK as `flutter_web_sdk/`, where `tools/gn --web` builds it."""
    out = _OUT + "wasm_release/"
    rctx.file(out + "args.gn", "\n".join([
        'target_os = "wasm"',
        'target_cpu = "wasm"',
        'flutter_runtime_mode = "release"',
        'engine_version = "{}"'.format(revision),
        'content_hash = "stock-artifacts"',
        'dart_version = "stock-artifacts"',
        "",
    ]))
    web_sdk = path("@flutter_stock_web_sdk//:web-sdk/libraries.json").dirname
    if not mismatched:
        link(web_sdk, out + "flutter_web_sdk")
        return

    # Another kernel format in the dart2js platform dill, as another Dart's
    # build would write: the tree is the official one but for that file.
    tree = out + "flutter_web_sdk/"
    for entry in web_sdk.readdir():
        if entry.basename != "kernel":
            link(entry, tree + entry.basename)
    for entry in web_sdk.get_child("kernel").readdir():
        if entry.basename != "dart2js_platform.dill":
            link(entry, tree + "kernel/" + entry.basename)
    patched = rctx.path(tree + "kernel/dart2js_platform.dill")
    rctx.execute(["cp", web_sdk.get_child("kernel").get_child("dart2js_platform.dill"), patched])
    rctx.execute(["chmod", "u+w", patched])

    # The kernel format is the four bytes after the magic: 139, where Dart 3.14 writes 141.
    rctx.execute(["sh", "-c", "printf '\\000\\000\\000\\213' | dd of=\"$1\" bs=1 seek=4 conv=notrunc 2>/dev/null", "sh", patched])

def _mobile_out_dirs(rctx, path, link, revision, other_gen):
    """The iOS and Android out dirs: the official engines, laid out as ninja leaves them."""

    # iOS. The simulator engine is the debug one, for this Mac's CPU; the devices'
    # are the profile and release ones. Each xcframework holds one platform
    # directory, as one out dir's `flutter_framework` target makes it.
    ios = {
        "debug": ("ios_debug_sim_arm64", "ios-arm64-simulator", "@flutter_stock_ios_engine_debug//:Flutter.xcframework/ios-arm64_x86_64-simulator/Flutter.framework/Flutter"),
        "profile": ("ios_profile", "ios-arm64", "@flutter_ios_engine_profile//:Flutter.xcframework/ios-arm64/Flutter.framework/Flutter"),
        "release": ("ios_release", "ios-arm64", "@flutter_stock_ios_engine//:Flutter.xcframework/ios-arm64/Flutter.framework/Flutter"),
    }
    ios_gen_snapshot = {
        "profile": "@flutter_ios_engine_profile//:gen_snapshot_arm64",
        "release": "@flutter_stock_ios_engine//:gen_snapshot_arm64",
    }
    for mode, (name, identifier, binary) in ios.items():
        out = _OUT + name + "/"
        simulator = mode == "debug"
        rctx.file(out + "args.gn", _mobile_args_gn("ios", mode, "arm64", revision, simulator))
        xcframework = out + "Flutter.xcframework/"
        link(path(binary).dirname, xcframework + identifier + "/Flutter.framework")
        rctx.file(xcframework + "Info.plist", _xcframework_info(identifier, "arm64", simulator))
        if mode != "debug":
            link(other_gen or path(ios_gen_snapshot[mode]), out + "universal/gen_snapshot_arm64")

    # Android. A `flutter.jar` for each ABI and mode, and the gen_snapshot of
    # each AOT mode that runs on this Mac.
    for arch in ["arm", "arm64", "x64"]:
        jars = {
            "debug": "@flutter_stock_android_engine_{}//:debug/flutter.jar",
            "profile": "@flutter_android_engine_{}_profile//:flutter.jar",
            "release": "@flutter_stock_android_engine_{}//:flutter.jar",
        }
        gen_snapshots = {
            "profile": "@flutter_cross_darwin-arm64_android-{}_profile//:gen_snapshot",
            "release": "@flutter_cross_darwin-arm64_android-{}//:gen_snapshot",
        }
        for mode, jar in jars.items():
            # `tools/gn` names an out dir without the CPU that is a platform's default.
            out = _OUT + "android_{}{}/".format(mode, "" if arch == "arm" else "_" + arch)
            rctx.file(out + "args.gn", _mobile_args_gn("android", mode, arch, revision))
            link(path(jar.format(arch)), out + "flutter.jar")
            if mode != "debug":
                link(other_gen or path(gen_snapshots[mode].format(arch)), out + "universal/gen_snapshot")

fake_checkout = repository_rule(
    _fake_checkout_impl,
    doc = "The official artifacts laid out as a flutter/flutter checkout with engine out dirs.",
    attrs = {
        "gen_snapshot_mismatch": attr.bool(
            doc = "Replace the release's gen_snapshot with one of another snapshot hash: another VM.",
        ),
        "web_kernel_format_mismatch": attr.bool(
            doc = "Write another kernel format into the web SDK's dart2js platform dill: a web SDK of another Dart.",
        ),
    },
)
