"""Native code a pub plugin's own build makes and rules_flutter does not.

`flutter build` builds a plugin for each platform with that platform's build
system: Gradle for Android, CocoaPods for iOS and macOS, CMake for Linux and
Windows. rules_flutter runs none of them. It compiles the plugin's Kotlin,
Java, Swift, Objective-C and C++ sources and reads what it can of the build
files (Maven dependencies, link libraries), but a library the build makes by
some other means is not made at all:

* Gradle's `externalNativeBuild` (CMake or ndk-build), as in package:jni.
* cargokit, which flutter_rust_bridge plugins use to build a Rust crate with
  cargo: an `apply from: ".../cargokit/gradle/plugin.gradle"` in the Gradle
  script, a podspec script phase running `cargokit/build_pod.sh`, and
  `apply_cargokit()` in a CMakeLists.txt.
* Any other CocoaPods script phase, which runs a shell step in the build.
* A CMakeLists.txt that sets `<plugin>_bundled_libraries`, Flutter's way of
  shipping a library the plugin's CMake build makes or downloads.
* `ffiPlugin: true` for the platform in the pubspec: Flutter builds the
  plugin's native sources into a library that Dart opens by name.

Each yields an app missing the library, which builds and fails at run time
when the plugin loads it. The functions here say which mechanism a build file
uses; `flutter_pub_package` records it per platform, and the platform's build
fails naming it: Android when it loads the plugin's `android/` package, iOS and
macOS in `flutter_apple_plugins_aggregator`, Linux and Windows in the runner
(`plugin_link_flags`). Other platforms are unaffected. A package an overlay
builds is not checked: the overlay is how the library is supplied.
"""

load("//flutter/private:cmake_link_libraries.bzl", "scan_cmake_commands")
load("//flutter/private:gradle_script.bzl", "gradle_statements")

visibility("//flutter/...")

_CARGOKIT = "which builds a Rust crate with cargo"

PLATFORM_NAMES = {
    "android": "Android",
    "ios": "iOS",
    "linux": "Linux",
    "macos": "macOS",
    "windows": "Windows",
}

def gradle_native_build(content, path):
    """The native build a plugin's Gradle script runs, or "".

    Args:
        content: The text of `android/build.gradle` or `android/build.gradle.kts`.
        path: The script's path in the package, for the description.

    Returns:
        A description of the mechanism, or "" when the script builds no native code.
    """
    statements = gradle_statements(content)
    for s in statements:
        if "cargokit/gradle/plugin.gradle" in s:
            return "cargokit (`{}` in {}), {}".format(s, path, _CARGOKIT)
    for s in statements:
        if "externalNativeBuild" in s:
            return "Gradle's `externalNativeBuild` (CMake or ndk-build, in {})".format(path)
    return ""

def podspec_native_build(content, path):
    """The build step a plugin's podspec runs besides compiling its sources, or "".

    Args:
        content: The text of the podspec.
        path: The podspec's path in the package, for the description.

    Returns:
        A description of the mechanism, or "" when the podspec only compiles sources.
    """
    lines = [
        line
        for line in content.split("\n")
        if not line.strip().startswith("#")
    ]
    for line in lines:
        if "cargokit/build_pod.sh" in line:
            return "cargokit (`build_pod.sh`, run by a CocoaPods script phase in {}), {}".format(path, _CARGOKIT)
    for line in lines:
        if ".script_phase" in line:
            return "a CocoaPods script phase (`{}` in {})".format(line.strip(), path)
    return ""

def cmake_native_build(content, path):
    """The library a plugin's CMakeLists.txt builds or ships beside its sources, or "".

    Args:
        content: The text of `linux/CMakeLists.txt` or `windows/CMakeLists.txt`.
        path: Its path in the package, for the description.

    Returns:
        A description of the mechanism, or "" when the file only builds the plugin's sources.
    """
    commands = scan_cmake_commands(content)
    for cmd in commands:
        if cmd.name == "apply_cargokit":
            return "cargokit (`apply_cargokit()` in {}, line {}), {}".format(path, cmd.line, _CARGOKIT)
    for cmd in commands:
        if cmd.name != "set" or not cmd.args or not cmd.args[0].text.endswith("_bundled_libraries"):
            continue
        values = [a.text for a in cmd.args[1:] if a.text and a.text != "PARENT_SCOPE"]
        if values:
            return "`{}` in {}, line {}, which bundles {} with the app".format(
                cmd.args[0].text,
                path,
                cmd.line,
                " ".join(values),
            )
    return ""

def ffi_plugin_native_build(build):
    """The description of an `ffiPlugin: true` platform whose build file says nothing more.

    Args:
        build: What builds the plugin's native sources on the platform (`its
            podspec, macos/foo.podspec`).

    Returns:
        The description.
    """
    return "`ffiPlugin: true` in its pubspec, for which Flutter builds the plugin's native sources with {}".format(build)

def unbuilt_native_code_message(package, version, platform, mechanism):
    """Why an app for `platform` cannot be built with `package`, and what to do.

    Args:
        package: The pub package's name.
        version: Its version.
        platform: A key of `PLATFORM_NAMES`.
        mechanism: What its build uses, as the functions above describe it.

    Returns:
        The message.
    """
    return (
        "package:{pkg} {version} builds native code for {platform} with {mechanism}. " +
        "rules_flutter does not run that build, and an app built without the library " +
        "would fail when the plugin loads it, so the {platform} build stops here. " +
        "Build the library with Bazel (a `rust_shared_library` of rules_rust for a Rust crate, " +
        "a `cc_shared_library` for C or C++) and give {pkg} a target that lists it in `native_deps`: " +
        "a plugin overlay for {pkg} (`flutter_pub.plugin_overlays` in MODULE.bazel; " +
        "@rules_flutter//flutter/ext/jni is one), or a `flutter_plugin` of your own that " +
        "`flutter_pub.from_lock(resolve = ...)` maps the package to."
    ).format(
        pkg = package,
        version = version,
        platform = PLATFORM_NAMES[platform],
        mechanism = mechanism,
    )

FlutterUnbuiltNativeCodeInfo = provider(
    doc = "A plugin's library for one platform that its own build makes and rules_flutter does not.",
    fields = {
        "message": "str: What the build of that platform fails with (`unbuilt_native_code_message`).",
    },
)

def _flutter_unbuilt_plugin_library_impl(ctx):
    return [FlutterUnbuiltNativeCodeInfo(message = ctx.attr.message)]

flutter_unbuilt_plugin_library = rule(
    implementation = _flutter_unbuilt_plugin_library_impl,
    attrs = {
        "message": attr.string(
            mandatory = True,
            doc = "What the build of the platform fails with.",
        ),
    },
    doc = "Stands in for a pub plugin's library on a platform where its native code " +
          "is built by something rules_flutter does not run. Written by " +
          "`flutter_pub_package` as the `lib` of that platform's `flutter_plugin_platform`; " +
          "the build of that platform fails with `message`, and only that build.",
)

def fail_on_unbuilt_native_code(entries):
    """Fail, with each message, when a plugin library entry stands for unbuilt native code.

    Args:
        entries: Plugin library structs of one platform (`apple_plugin_libraries`
            filtered to it, `linux_plugin_libraries`, `windows_plugin_libraries`).
    """
    messages = sorted({
        entry.unbuilt_native_code: True
        for entry in entries
        if entry.unbuilt_native_code
    }.keys())
    if messages:
        fail("\n\n".join(messages))
