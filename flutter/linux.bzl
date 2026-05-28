"""Flutter rules for Linux desktop builds.

Two tiers of API:

    Tier 1 — flutter_linux_app (self-contained, recommended):

        load("@rules_flutter//flutter:linux.bzl", "flutter_linux_app")
        load("@rules_flutter//flutter:defs.bzl", "flutter_application")

        flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

        flutter_linux_app(
            name = "my_linux_app",
            application = ":my_app",
            gtk_app_id = "com.example.myapp",
        )

    Prerequisites: run `flutter create --platforms=linux .` to generate
    the conventional `linux/runner/` directory with C++ runner files.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:linux.bzl",
            "flutter_linux_bundle",
            "flutter_linux_engine",
            "flutter_linux_registrant_gen",
            "flutter_linux_runner_lib_gen")

        flutter_linux_engine(name = "flutter_engine")
        flutter_linux_registrant_gen(name = "app_registrant", application = ":my_app")

        flutter_linux_runner_lib_gen(
            name = "my_runner",
            engine = ":flutter_engine",
            registrant = ":app_registrant",
            gtk_app_id = "com.example.myapp",
        )

        flutter_linux_bundle(
            name = "my_linux_app",
            application = ":my_app",
            runner = ":my_runner",
        )

Output directory structure:
    my_app/
      my_app                     (GTK runner executable)
      lib/
        libapp.so                (AOT-compiled Dart code)
        libflutter_linux_gtk.so  (Flutter engine)
        *.so                     (native plugin libraries, if any)
      data/
        flutter_assets/          (fonts, images, shaders, asset manifest)
        icudtl.dat               (ICU internationalization data)

Cross-compilation: build from macOS/Windows for Linux with:
    bazel build //target --platforms=@rules_flutter//flutter/platforms:linux_x64
"""

load("//flutter/private:flutter_linux_application.bzl", _flutter_linux_bundle_rule = "flutter_linux_bundle_rule", _flutter_linux_runner_lib = "flutter_linux_runner_lib")
load("//flutter/private:flutter_linux_engine_rule.bzl", _flutter_linux_engine_rule = "flutter_linux_engine_rule")
load("//flutter/private:flutter_linux_plugin_library.bzl", _flutter_linux_plugin_library = "flutter_linux_plugin_library")
load("//flutter/private:flutter_linux_registrant.bzl", _flutter_linux_registrant = "flutter_linux_registrant")

# -- Composable rules (Tier 2) ------------------------------------------------

flutter_linux_engine = _flutter_linux_engine_rule
flutter_linux_registrant_gen = _flutter_linux_registrant

# Public wrapper that bundles a Flutter plugin's Linux C++ sources for the
# runner to compile + link. For pub.dev plugins, flutter_pub_package emits
# this automatically; expose it here so users can wire a monorepo plugin's
# BUILD.bazel without going through the ext/ overlay system.
flutter_linux_plugin_library = _flutter_linux_plugin_library

def flutter_linux_runner_lib_gen(name, engine, registrant, application = None, gtk_app_id = "com.example.flutter", srcs = [], hdrs = [], **kwargs):
    """Compiles a GTK Linux runner binary from template or custom sources.

    Uses the Chromium sysroot for hermetic GTK3 compilation, enabling
    cross-compilation from any host. When srcs is empty, uses the built-in
    runner template from rules_flutter.

    When `application` is set, every transitive plugin's Linux C++ sources
    (collected from `FlutterInfo.linux_plugin_libraries`) are compiled
    alongside the runner so the registrant's
    `<plugin>_register_with_registrar` symbols resolve at link time.

    Args:
        name: Target name (produces an executable).
        engine: A flutter_linux_engine target.
        registrant: A flutter_linux_registrant_gen target.
        application: A flutter_application target. Required to wire pub
            plugins' Linux C++ sources into the runner; optional only for
            legacy Tier-2 setups with no native plugins.
        gtk_app_id: GTK application identifier (default "com.example.flutter").
        srcs: Custom C++ sources (empty = use built-in template).
        hdrs: Custom C++ headers.
        **kwargs: Additional arguments (e.g. tags, visibility).
    """
    _flutter_linux_runner_lib(
        name = name,
        engine = engine,
        registrant = registrant,
        application = application,
        gtk_app_id = gtk_app_id,
        srcs = srcs if srcs else [],
        hdrs = hdrs if hdrs else [],
        **kwargs
    )

def flutter_linux_bundle(name, application, runner, **kwargs):
    """Assembles a Linux application directory from a runner and application.

    This is the public assembler rule — equivalent to macos_application
    (rules_apple) or android_binary (rules_android). Takes a pre-compiled
    runner executable and FlutterApplicationInfo, produces the bundle directory.

    Args:
        name: Target name.
        application: A flutter_application target (FlutterApplicationInfo).
        runner: A pre-compiled runner executable (from flutter_linux_runner_lib_gen or cc_binary).
        **kwargs: Additional arguments (e.g. app_name, tags, visibility).
    """
    _flutter_linux_bundle_rule(
        name = name,
        application = application,
        runner = runner,
        **kwargs
    )

# -- Convenience macro (Tier 1) -----------------------------------------------

def flutter_linux_app(
        name,
        application,
        app_name = None,
        gtk_app_id = "com.example.flutter",
        **kwargs):
    """Builds a Flutter Linux application directory from a flutter_application target.

    Discovers runner files from the conventional `linux/runner/` directory
    (as generated by `flutter create --platforms=linux .`) and wires up all
    internal targets automatically.

    If no `linux/runner/` directory exists, falls back to the built-in
    runner template from rules_flutter.

    Args:
        name: Target name (Bazel identifier).
        application: A flutter_application target (required).
        app_name: Bundle/binary name (defaults to target name).
        gtk_app_id: GTK application identifier (default "com.example.flutter").
        **kwargs: Passed through to flutter_linux_bundle.
    """
    tags = kwargs.pop("tags", [])
    target_compatible_with = kwargs.pop("target_compatible_with", None)

    # Attributes propagated to all intermediate targets so that
    # `target_compatible_with` (and tags) cause Bazel to skip analysis on
    # incompatible platforms (e.g. building Linux targets on macOS).
    common = {"tags": tags}
    if target_compatible_with:
        common["target_compatible_with"] = target_compatible_with

    # 1. Engine target.
    _flutter_linux_engine_rule(
        name = "__%s_engine" % name,
        **common
    )

    # 2. Registrant target.
    #    If flutter create registrant files exist, use them directly (they match
    #    the #include "flutter/generated_plugin_registrant.h" path expected by
    #    flutter create runner code). Otherwise, generate from FlutterInfo.
    flutter_create_registrant = native.glob(
        [
            "linux/flutter/generated_plugin_registrant.cc",
            "linux/flutter/generated_plugin_registrant.h",
        ],
        allow_empty = True,
    )
    if flutter_create_registrant:
        native.filegroup(
            name = "__%s_registrant" % name,
            srcs = flutter_create_registrant,
            **common
        )
    else:
        _flutter_linux_registrant(
            name = "__%s_registrant" % name,
            application = application,
            **common
        )

    # 3. Runner target — discover flutter create output or use template.
    runner_srcs = native.glob(["linux/runner/*.cc", "linux/runner/*.cpp"], allow_empty = True)
    runner_hdrs = native.glob(["linux/runner/*.h"], allow_empty = True)

    _flutter_linux_runner_lib(
        name = "__%s_runner" % name,
        engine = "__%s_engine" % name,
        registrant = "__%s_registrant" % name,
        application = application,
        gtk_app_id = gtk_app_id,
        srcs = runner_srcs if runner_srcs else [],
        hdrs = runner_hdrs if runner_hdrs else [],
        **common
    )

    # 4. Bundle assembly.
    _flutter_linux_bundle_rule(
        name = name,
        application = application,
        runner = "__%s_runner" % name,
        app_name = app_name or None,
        **dict(common, **kwargs)
    )
