"""Plugin registrant generation (Dart and native).

Generates the Dart source that imports and registers all dartPluginClass plugins
at application startup, and native registrant source files for method channel
plugins (pluginClass) on desktop platforms.
"""

def make_registrant_content(plugins, target_platform = None):
    """Generate Dart source content for plugin registration.

    Two output shapes depending on `target_platform`:

    - **`web`**: imports `package:flutter_web_plugins/flutter_web_plugins.dart`
      to get `webPluginRegistrar`, then for each plugin whose web entry has
      a `pluginClass` (the convention Flutter uses for web plugins —
      web plugins are pure Dart and `pluginClass` is the Dart class), emits
      `<PluginClass>.registerWith(webPluginRegistrar);`. The `fileName`
      override (from `flutter.plugin.platforms.web.fileName`) is honored.
    - **Other platforms (or `None`)**: for each plugin whose entry has a
      `dartPluginClass`, emits `<DartPluginClass>.registerWith(null);` —
      the Dart-side registrant convention used by Flutter on
      mobile/desktop. `fileName` (or legacy `dartFileName`) is honored.

    Args:
        plugins: List of plugin structs (name, platforms dict).
        target_platform: Optional platform string (e.g. "web", "linux", "android").
            When set, only registers plugins for that platform. When None,
            falls back to legacy "first platform with dartPluginClass wins".

    Returns:
        String of Dart source code, or empty string if no Dart plugins.
    """
    if target_platform == "web":
        return _make_web_registrant_content(plugins)

    dart_plugins = []
    for plugin in plugins:
        if target_platform:
            info = plugin.platforms.get(target_platform, {})
            if not info:
                continue
            dart_class = info.get("dartPluginClass", "")
            if dart_class:
                dart_file_name = info.get("fileName", info.get("dartFileName", plugin.name + ".dart"))
                dart_plugins.append(struct(
                    package = plugin.name,
                    dart_plugin_class = dart_class,
                    dart_file_name = dart_file_name,
                ))
        else:
            # Legacy: pick first platform with dartPluginClass.
            for _platform, info in plugin.platforms.items():
                dart_class = info.get("dartPluginClass", "")
                if dart_class:
                    dart_file_name = info.get("fileName", info.get("dartFileName", plugin.name + ".dart"))
                    dart_plugins.append(struct(
                        package = plugin.name,
                        dart_plugin_class = dart_class,
                        dart_file_name = dart_file_name,
                    ))
                    break

    if not dart_plugins:
        return ""

    lines = ["// GENERATED — do not edit.", "// ignore_for_file: depend_on_referenced_packages"]
    for p in dart_plugins:
        lines.append("import 'package:%s/%s';" % (p.package, p.dart_file_name))
    lines.append("")
    lines.append("void registerPlugins() {")
    for p in dart_plugins:
        # Non-web Dart plugins use the no-arg `registerWith()` signature
        # (e.g. PathProviderFoundation, UrlLauncherMacOS). Web plugins use
        # the registrar-passing signature; that path is handled by
        # _make_web_registrant_content.
        lines.append("  %s.registerWith();" % p.dart_plugin_class)
    lines.append("}")
    lines.append("")
    return "\n".join(lines)

def _make_web_registrant_content(plugins):
    """Generate the Dart registrant source for Flutter web.

    Web plugins are pure Dart, and Flutter's `flutter pub get` accepts
    either `pluginClass` (most modern web plugins, e.g. `url_launcher_web`,
    `package_info_plus`) or `dartPluginClass` (older convention, still
    used by some plugins).

    When `pluginClass` is set, the registrar is the global
    `webPluginRegistrar` from `package:flutter_web_plugins`. When only
    `dartPluginClass` is set, fall back to the same `null`-registrar
    convention used on mobile/desktop.
    """
    web_plugins_with_registrar = []
    web_plugins_no_registrar = []
    for plugin in plugins:
        info = plugin.platforms.get("web", {})
        if not info:
            continue
        plugin_class = info.get("pluginClass", "")
        if plugin_class and plugin_class != "none":
            file_name = info.get("fileName", info.get("dartFileName", plugin.name + ".dart"))
            web_plugins_with_registrar.append(struct(
                package = plugin.name,
                plugin_class = plugin_class,
                file_name = file_name,
            ))
            continue
        dart_class = info.get("dartPluginClass", "")
        if dart_class:
            file_name = info.get("fileName", info.get("dartFileName", plugin.name + ".dart"))
            web_plugins_no_registrar.append(struct(
                package = plugin.name,
                plugin_class = dart_class,
                file_name = file_name,
            ))

    if not web_plugins_with_registrar and not web_plugins_no_registrar:
        return ""

    lines = ["// GENERATED — do not edit.", "// ignore_for_file: depend_on_referenced_packages"]
    if web_plugins_with_registrar:
        lines.append("import 'package:flutter_web_plugins/flutter_web_plugins.dart';")
    for p in web_plugins_with_registrar + web_plugins_no_registrar:
        lines.append("import 'package:%s/%s';" % (p.package, p.file_name))
    lines.append("")
    lines.append("void registerPlugins() {")
    for p in web_plugins_with_registrar:
        lines.append("  %s.registerWith(webPluginRegistrar);" % p.plugin_class)
    for p in web_plugins_no_registrar:
        # `dartPluginClass`-only plugins use the no-arg signature on web
        # too — same as Flutter's non-web Dart-side registrant convention.
        lines.append("  %s.registerWith();" % p.plugin_class)
    lines.append("}")
    lines.append("")
    return "\n".join(lines)

def make_wrapper_main_content(original_import, registrant_import = None, agent_import = None):
    """Generate a wrapper main.dart that composes optional setup steps then user main.

    The wrapper can call (in order, before user `main()`):
    - `WidgetsFlutterBinding.ensureInitialized()` (when `agent_import` is set, so
      service extensions can register against a live binding before `runApp`)
    - `registerRulesFlutterAgentExtensions()` from the AI-agent stub (when
      `agent_import` is set; debug-only, injected by `flutter_compile_kernel`)
    - `registerPlugins()` from the generated plugin registrant (when
      `registrant_import` is set)

    Args:
        original_import: Import URI for the original main (e.g. 'package:my_app/main.dart').
        registrant_import: Optional relative import path for the generated registrant.
        agent_import: Optional relative import path for the agent extensions library.

    Returns:
        String of Dart source code.
    """
    lines = ["// GENERATED — do not edit."]
    if agent_import:
        lines.append("import 'package:flutter/widgets.dart';")
        lines.append("import '%s' as agent;" % agent_import)
    lines.append("import '%s' as entrypoint;" % original_import)
    if registrant_import:
        lines.append("import '%s' as reg;" % registrant_import)
    lines.extend(["", "void main() {"])
    if agent_import:
        lines.append("  WidgetsFlutterBinding.ensureInitialized();")
        lines.append("  agent.registerRulesFlutterAgentExtensions();")
    if registrant_import:
        lines.append("  reg.registerPlugins();")
    lines.append("  entrypoint.main();")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)

def _collect_native_plugins(plugins, target_platform):
    """Collect plugins with a native pluginClass for the given platform.

    Args:
        plugins: List of plugin structs.
        target_platform: Platform string ("linux", "windows", "macos", "ios", "android").

    Returns:
        List of structs with name, plugin_class, and (for android) package fields.
    """
    result = []
    for plugin in plugins:
        info = plugin.platforms.get(target_platform, {})
        if info:
            plugin_class = info.get("pluginClass", "")
            if plugin_class and plugin_class != "none":
                result.append(struct(
                    name = plugin.name,
                    plugin_class = plugin_class,
                    package = info.get("package", ""),
                ))
    return result

def make_linux_registrant_content(plugins):
    """Generate C++ source for Linux native plugin registration.

    Args:
        plugins: List of plugin structs (from _collect_native_plugins).

    Returns:
        String of C++ source code for generated_plugin_registrant.cc.
    """
    lines = [
        "// GENERATED — do not edit.",
        "#include <flutter_linux/flutter_linux.h>",
        "",
    ]

    # Forward declarations (snake_case function names from plugin class).
    for p in plugins:
        fn_name = _to_snake_case(p.plugin_class)
        lines.append("extern void %s_register_with_registrar(FlPluginRegistrar* registrar);" % fn_name)

    lines.append("")
    lines.append("void fl_register_plugins(FlPluginRegistry* registry) {")
    for p in plugins:
        fn_name = _to_snake_case(p.plugin_class)
        lines.append("  g_autoptr(FlPluginRegistrar) %s_registrar =" % fn_name)
        lines.append('      fl_plugin_registry_get_registrar_for_plugin(registry, "%s");' % p.plugin_class)
        lines.append("  %s_register_with_registrar(%s_registrar);" % (fn_name, fn_name))
    lines.append("}")
    lines.append("")
    return "\n".join(lines)

def make_windows_registrant_content(plugins):
    """Generate C++ source for Windows native plugin registration.

    Args:
        plugins: List of plugin structs (from _collect_native_plugins).

    Returns:
        String of C++ source code for generated_plugin_registrant.cc.
    """
    lines = [
        "// GENERATED — do not edit.",
        "#include <flutter/plugin_registry.h>",
        "",
    ]

    # Forward declarations (PascalCase with RegisterWithRegistrar suffix).
    for p in plugins:
        lines.append("void %sRegisterWithRegistrar(" % p.plugin_class)
        lines.append("    flutter::PluginRegistrarWindows* registrar);")

    lines.append("")
    lines.append("void RegisterPlugins(flutter::PluginRegistry* registry) {")
    for p in plugins:
        lines.append("  %sRegisterWithRegistrar(" % p.plugin_class)
        lines.append('      registry->GetRegistrarForPlugin("%s"));' % p.plugin_class)
    lines.append("}")
    lines.append("")
    return "\n".join(lines)

def make_macos_registrant_content(plugins):
    """Generate Swift source for macOS native plugin registration.

    Produces the free function `RegisterGeneratedPlugins(registry:)` that
    the macOS runner's MainFlutterWindow.swift calls at startup. Each
    plugin's Swift module is imported by package name — Bazel
    swift_library targets default to a module name matching the package
    name (lowercased) unless overridden via `apple_module_name`.

    Args:
        plugins: List of plugin structs (from _collect_native_plugins).

    Returns:
        String of Swift source code for GeneratedPluginRegistrant.swift.
    """
    lines = [
        "// GENERATED — do not edit.",
        "import FlutterMacOS",
    ]
    seen_modules = {}
    for p in plugins:
        module_name = p.name
        if module_name not in seen_modules:
            seen_modules[module_name] = True
            lines.append("import %s" % module_name)
    lines.append("")
    lines.append("func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {")
    for p in plugins:
        lines.append('    %s.register(with: registry.registrar(forPlugin: "%s"))' % (p.plugin_class, p.plugin_class))
    lines.append("}")
    lines.append("")
    return "\n".join(lines)

def make_android_registrant_content(plugins, java_package = "io.flutter.plugins"):
    """Generate Java source for Android plugin registration.

    Mirrors `flutter pub get`'s `GeneratedPluginRegistrant.java`. Each
    plugin's Java/Kotlin class is registered against the FlutterEngine
    by constructing it and adding it to the engine's plugin set. The
    fully-qualified class name comes from `flutter.plugin.platforms.
    android.package` + `pluginClass`.

    Args:
        plugins: List of plugin structs (must include `package` and
            `plugin_class` from _collect_native_plugins for "android").
        java_package: Java package for the GeneratedPluginRegistrant
            class itself. Defaults to `io.flutter.plugins` to match
            flutter_tools' convention.

    Returns:
        String of Java source code for GeneratedPluginRegistrant.java.
    """
    lines = [
        "// GENERATED — do not edit.",
        "package %s;" % java_package,
        "",
        "import androidx.annotation.Keep;",
        "import androidx.annotation.NonNull;",
        "import io.flutter.Log;",
        "import io.flutter.embedding.engine.FlutterEngine;",
        "",
        "@Keep",
        "public final class GeneratedPluginRegistrant {",
        '  private static final String TAG = "GeneratedPluginRegistrant";',
        "  public static void registerWith(@NonNull FlutterEngine flutterEngine) {",
    ]
    for p in plugins:
        # `_collect_native_plugins` doesn't carry package — it's stamped
        # via the Android-specific platform info dict. Caller passes the
        # raw plugin struct so we can read p.platforms here too. As a
        # defense, fall back to a generic `io.flutter.plugins.<name>`.
        java_pkg = getattr(p, "package", "")
        if not java_pkg:
            java_pkg = "io.flutter.plugins.%s" % p.name.replace("_", "")
        fqcn = "%s.%s" % (java_pkg, p.plugin_class)
        lines.append("    try {")
        lines.append("      flutterEngine.getPlugins().add(new %s());" % fqcn)
        lines.append("    } catch (Exception e) {")
        lines.append('      Log.e(TAG, "Error registering plugin %s, %s", e);' % (p.name, fqcn))
        lines.append("    }")
    lines.append("  }")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)

def make_ios_registrant_content(plugins):
    """Generate Swift source for iOS native plugin registration.

    Produces the `GeneratedPluginRegistrant` class with a static `register`
    method that the iOS runner's AppDelegate calls at startup. Each
    plugin's Swift module is imported by package name — Bazel
    swift_library targets default to a module name matching the package
    name (lowercased) unless overridden via `apple_module_name`.

    Args:
        plugins: List of plugin structs (from _collect_native_plugins).

    Returns:
        String of Swift source code for GeneratedPluginRegistrant.swift.
    """
    lines = [
        "// GENERATED — do not edit.",
        "import Flutter",
    ]
    seen_modules = {}
    for p in plugins:
        module_name = p.name
        if module_name not in seen_modules:
            seen_modules[module_name] = True
            lines.append("import %s" % module_name)
    lines.append("")
    lines.append("@objc class GeneratedPluginRegistrant: NSObject {")
    lines.append("    @objc static func register(with registry: FlutterPluginRegistry) {")
    for p in plugins:
        lines.append('        %s.register(with: registry.registrar(forPlugin: "%s")!)' % (p.plugin_class, p.plugin_class))
    lines.append("    }")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)

def _to_snake_case(name):
    """Convert PascalCase to snake_case.

    Args:
        name: A PascalCase string (e.g. "UrlLauncherPlugin").

    Returns:
        snake_case string (e.g. "url_launcher_plugin").
    """
    result = []
    for i, c in enumerate(name.elems()):
        if c.isupper() and i > 0:
            result.append("_")
        result.append(c.lower())
    return "".join(result)

_EMPTY_LINUX_REGISTRANT = """\
// GENERATED — no native plugins.
#include <flutter_linux/flutter_linux.h>

void fl_register_plugins(FlPluginRegistry* registry) {}
"""

_EMPTY_WINDOWS_REGISTRANT = """\
// GENERATED — no native plugins.
#include <flutter/plugin_registry.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {}
"""

_EMPTY_MACOS_REGISTRANT = """\
// GENERATED — no native plugins.
import FlutterMacOS

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {}
"""

_EMPTY_IOS_REGISTRANT = """\
// GENERATED — no native plugins.
import Flutter

@objc class GeneratedPluginRegistrant: NSObject {
    @objc static func register(with registry: FlutterPluginRegistry) {}
}
"""

_EMPTY_ANDROID_REGISTRANT = """\
// GENERATED — no native plugins.
package io.flutter.plugins;

import androidx.annotation.Keep;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.FlutterEngine;

@Keep
public final class GeneratedPluginRegistrant {
  public static void registerWith(@NonNull FlutterEngine flutterEngine) {}
}
"""

_LINUX_REGISTRANT_HEADER = """\
#ifndef GENERATED_PLUGIN_REGISTRANT_
#define GENERATED_PLUGIN_REGISTRANT_
#include <flutter_linux/flutter_linux.h>
void fl_register_plugins(FlPluginRegistry* registry);
#endif
"""

_WINDOWS_REGISTRANT_HEADER = """\
#ifndef GENERATED_PLUGIN_REGISTRANT_
#define GENERATED_PLUGIN_REGISTRANT_
#include <flutter/plugin_registry.h>
void RegisterPlugins(flutter::PluginRegistry* registry);
#endif
"""

def generate_native_plugin_registrant_header(ctx, target_platform):
    """Generate a native plugin registrant header file.

    Produces the .h that declares the registration function so runner code
    can #include "flutter/generated_plugin_registrant.h".

    Args:
        ctx: Rule context.
        target_platform: Platform string ("linux" or "windows").

    Returns:
        File: The generated .h file, or None for unsupported platforms.
    """
    if target_platform == "linux":
        content = _LINUX_REGISTRANT_HEADER
    elif target_platform == "windows":
        content = _WINDOWS_REGISTRANT_HEADER
    else:
        return None

    header = ctx.actions.declare_file(ctx.label.name + "_native_plugin_registrant.h")
    ctx.actions.write(header, content)
    return header

def generate_native_plugin_registrant(ctx, plugins, target_platform):
    """Generate a native plugin registrant source file.

    Always generates a file (no-op if no native plugins) so the runner can
    unconditionally call the registration function.

    Args:
        ctx: Rule context.
        plugins: List of plugin structs.
        target_platform: Platform string ("linux", "windows", "macos").

    Returns:
        File: The generated native source file, or None for unsupported platforms.
    """
    native_plugins = _collect_native_plugins(plugins, target_platform)

    if target_platform == "linux":
        content = make_linux_registrant_content(native_plugins) if native_plugins else _EMPTY_LINUX_REGISTRANT
        ext = ".cc"
    elif target_platform == "windows":
        content = make_windows_registrant_content(native_plugins) if native_plugins else _EMPTY_WINDOWS_REGISTRANT
        ext = ".cc"
    elif target_platform == "macos":
        content = make_macos_registrant_content(native_plugins) if native_plugins else _EMPTY_MACOS_REGISTRANT
        ext = ".swift"
    elif target_platform == "ios":
        content = make_ios_registrant_content(native_plugins) if native_plugins else _EMPTY_IOS_REGISTRANT
        ext = ".swift"
    elif target_platform == "android":
        content = make_android_registrant_content(native_plugins) if native_plugins else _EMPTY_ANDROID_REGISTRANT

        # Android needs the file in a `io/flutter/plugins/` subdir so
        # kt_android_library / android_library picks up the right
        # Java package layout. Caller (flutter_android_registrant)
        # places it accordingly.
        ext = ".java"
    else:
        return None

    if target_platform == "android":
        registrant = ctx.actions.declare_file(ctx.label.name + "/io/flutter/plugins/GeneratedPluginRegistrant.java")
    else:
        registrant = ctx.actions.declare_file(ctx.label.name + "_native_plugin_registrant" + ext)
    ctx.actions.write(registrant, content)
    return registrant

def generate_dart_plugin_registrant(ctx, plugins, target_platform = None):
    """Generate a Dart plugin registrant source file via ctx.actions.write.

    Args:
        ctx: Rule context.
        plugins: List of plugin structs.
        target_platform: Optional platform string to filter plugins by.

    Returns:
        File: The generated registrant .dart file, or None if no Dart plugins.
    """
    content = make_registrant_content(plugins, target_platform = target_platform)
    if not content:
        return None
    registrant = ctx.actions.declare_file(ctx.label.name + "_plugin_registrant.dart")
    ctx.actions.write(registrant, content)
    return registrant
