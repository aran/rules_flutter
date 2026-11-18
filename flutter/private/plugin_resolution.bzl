"""Which implementation of each plugin an application registers on each platform.

A federated plugin is an app-facing package (`url_launcher`) whose platforms
are implemented by other packages (`url_launcher_android`), each saying so with
`implements:`; the app-facing package may name a `default_package` for a
platform. Two packages implementing one plugin on one platform can both reach
an app, and only one may register. flutter_tools chooses it
(`_resolvePluginImplementations` in `flutter_plugins.dart`), and this is that
choice:

- the only candidate;
- else the one the application depends on directly; of two such, the one that
  implements the plugin when the other is the app-facing package's own inline
  implementation, and otherwise an error;
- else the app-facing package's `default_package`;
- else an error.

A `default_package` that is not among the application's plugins, or that has
no implementation of its own on that platform, is ignored, and flutter_tools
warns about it and builds on. Its words are this choice's `warnings`, which
`plugin_warnings_validation` prints from an action, the way a compiler's
warnings reach a Bazel build.

A package with an implementation of its own for a platform and no `implements`
implements itself, so an ordinary plugin is its own only candidate.

flutter_tools chooses twice: once over every implementation, for the native
registrants and the web's (`nativeOrDart`), and once over the Dart ones only,
for the Dart plugin registrant (`dart`). The two can differ: a candidate with a
`pluginClass` and no `dartPluginClass` is a candidate only of the first.

"Directly" is what an app's pubspec lists under `dependencies`. Its BUILD
counterpart is `FlutterInfo.app_dependencies`: the packages the application
target and the `flutter_library` targets of the main repository depend on.
"""

load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "portable_tools")
load("//flutter/private:flutter_info.bzl", "direct_package_names", "plugins_in_registration_order")

visibility("//flutter/...")

# The platforms flutter_tools chooses for, in the order it reports on them.
_PLATFORMS = ("android", "ios", "linux", "macos", "windows", "web")

_NATIVE_OR_DART = "nativeOrDart"
_DART = "dart"

def _inline(plugin, platform):
    # A platform entry is an implementation unless it only names a
    # `default_package` (`_providesImplementationForPlatform`).
    info = plugin.platforms.get(platform)
    return info != None and not info.default_package

def _inline_dart(plugin, platform):
    # flutter_tools reads `dartPluginClass` of every platform but the web.
    info = plugin.platforms.get(platform)
    return platform != "web" and info != None and bool(info.dart_plugin_class)

def _has_inline(plugin, platform, mode):
    return _inline(plugin, platform) if mode == _NATIVE_OR_DART else _inline_dart(plugin, platform)

def _default_package(plugin, platform):
    # Nor does it read the web's `default_package`.
    info = plugin.platforms.get(platform)
    return info.default_package if platform != "web" and info != None else ""

def _pubspec_error(plugin, platform, mode):
    """`_validatePlugin`: a `default_package` beside an implementation."""
    implements = plugin.implements
    default = _default_package(plugin, platform)
    if plugin.name == implements and plugin.name == default:
        return None
    if not default:
        return None
    if implements:
        return (
            "Plugin {name}:{platform} provides an implementation for {implements} " +
            "and also references a default implementation for {default}, which is currently not supported. " +
            "Ask the maintainers of {name} to either remove the implementation via `implements: {implements}` " +
            "or avoid referencing a default implementation via `platforms: {platform}: default_package: {default}`.\n"
        ).format(name = plugin.name, platform = platform, implements = implements, default = default)
    if _has_inline(plugin, platform, mode):
        keys = " dartPluginClass" if mode == _DART else "` `pluginClass` or `dartPluginClass"
        return (
            "Plugin {name}:{platform} which provides an inline implementation " +
            "cannot also reference a default implementation for {default}. " +
            "Ask the maintainers of {name} to either remove the implementation via `platforms: {platform}:{keys}` " +
            "or avoid referencing a default implementation via `platforms: {platform}: default_package: {default}`.\n"
        ).format(name = plugin.name, platform = platform, default = default, keys = keys)
    return None

def _implemented_plugin(plugin, platform, mode):
    """`_getImplementedPlugin`: the plugin `plugin` is a candidate for, or None."""
    if not _has_inline(plugin, platform, mode):
        return None
    return plugin.implements or plugin.name

def _default_impl_plugin(plugin, platform, mode):
    """`_getDefaultImplPlugin`: the package that implements `plugin` by default, or None."""
    default = _default_package(plugin, platform)
    if default:
        return default
    return plugin.name if _has_inline(plugin, platform, mode) else None

def _names(plugins):
    return "".join(["  %s\n" % p.name for p in plugins])

def _choose(platform, name, candidates, default, is_direct):
    """`_resolveImplementationOfPlugin`: (the chosen candidate or None, an error or None)."""
    if len(candidates) == 1:
        return candidates[0], None
    direct = [c for c in candidates if is_direct(c.name)]
    if len(direct) == 1:
        return direct[0], None
    if direct:
        # An app-facing package's inline implementation, depended on directly,
        # gives way to another direct dependency that implements it.
        implementing = [c for c in direct if c.implements]
        if len(implementing) == 1 and len(direct) == 2:
            return implementing[0], None
        return None, (
            "Plugin {name}:{platform} has conflicting direct dependency implementations:\n{names}" +
            "To fix this issue, remove all but one of these from the `deps` of the application " +
            "and of the `flutter_library` targets of this repository that it depends on.\n"
        ).format(name = name, platform = platform, names = _names(direct))
    if default != None and default.name in [c.name for c in candidates]:
        return default, None
    return None, (
        "Plugin {name}:{platform} has multiple possible implementations:\n{names}" +
        "To fix this issue, add one of these to the `deps` of the application.\n"
    ).format(name = name, platform = platform, names = _names(candidates))

def _default_warning(plugin, platform, default_name, default):
    """flutter_tools' warning about a `default_package` it ignores, or None."""
    if default == None:
        return (
            "Package {name}:{platform} references {default}:{platform} as the default plugin, " +
            "but the package does not exist, or is not a plugin package.\n" +
            "Ask the maintainers of {name} to either avoid referencing a default implementation " +
            "via `platforms: {platform}: default_package: {default}` " +
            "or create a plugin named {default}.\n"
        ).format(name = plugin.name, platform = platform, default = default_name)
    if not _inline(default, platform):
        return (
            "Package {name}:{platform} references {default}:{platform} as the default plugin, " +
            "but it does not provide an inline implementation.\n" +
            "Ask the maintainers of {name} to either avoid referencing a default implementation " +
            "via `platforms: {platform}: default_package: {default}` " +
            "or add an inline implementation to {default} via `platforms: {platform}:` " +
            "`pluginClass` or `dartPluginClass`.\n"
        ).format(name = plugin.name, platform = platform, default = default_name)
    return None

def _resolve_platform(plugins, by_name, platform, mode, is_direct):
    """`_resolvePluginImplementationsByPlatform`: the chosen plugins' names, the errors and the warnings."""
    pubspec_errors = []
    warnings = []
    candidates = {}
    defaults = {}
    for plugin in plugins:
        error = _pubspec_error(plugin, platform, mode)
        if error:
            pubspec_errors.append(error)
            continue
        implemented = _implemented_plugin(plugin, platform, mode)
        default_name = _default_impl_plugin(plugin, platform, mode)

        # A default that is not in the app, or that implements nothing here,
        # flutter_tools warns about and ignores.
        default = by_name.get(default_name) if default_name else None
        warning = _default_warning(plugin, platform, default_name, default) if default_name else None
        if warning:
            warnings.append(warning)
        if default != None and _inline(default, platform) and (mode == _NATIVE_OR_DART or _has_inline(default, platform, mode)):
            defaults[plugin.name] = default
        if implemented:
            candidates.setdefault(implemented, []).append(plugin)

    chosen = {}
    resolution_errors = []
    for name, implementations in candidates.items():
        resolution, error = _choose(platform, name, implementations, defaults.get(name), is_direct)
        if error:
            resolution_errors.append(error)
        elif resolution != None:
            chosen[resolution.name] = True
    return struct(chosen = chosen, pubspec_errors = pubspec_errors, resolution_errors = resolution_errors, warnings = warnings)

def _resolve(plugins, mode, is_direct, warnings):
    """`_resolvePluginImplementations`: per platform, the names chosen; and the error, or None.

    Adds its warnings to `warnings`, a dict whose keys keep their order.
    """
    by_name = {p.name: p for p in plugins}
    chosen = {}
    printed = []
    pubspec_error = False
    resolution_error = False
    for platform in _PLATFORMS:
        result = _resolve_platform(plugins, by_name, platform, mode, is_direct)
        printed.extend(result.pubspec_errors + result.resolution_errors)
        for warning in result.warnings:
            warnings[warning] = True
        if result.pubspec_errors:
            pubspec_error = True
        elif result.resolution_errors:
            resolution_error = True
        else:
            chosen[platform] = result.chosen
    if pubspec_error:
        return chosen, "".join(printed) + "Please resolve the plugin pubspec errors"
    if resolution_error:
        return chosen, "".join(printed) + "Please resolve the plugin implementation selection errors"
    return chosen, None

def _restricted(plugins, chosen):
    """The plugins chosen on some platform, each with only the platforms it is chosen on."""
    result = []
    for plugin in plugins:
        platforms = {
            platform: info
            for platform, info in plugin.platforms.items()
            if plugin.name in chosen.get(platform, {})
        }
        if platforms:
            result.append(struct(
                name = plugin.name,
                platforms = platforms,
                dependencies = plugin.dependencies,
                implements = plugin.implements,
            ))
    return result

def _unchosen(plugins, chosen):
    """Per platform, the plugins with an implementation there that were not chosen.

    Their native code stays out of an application on that platform, as
    flutter_tools leaves them out of the Gradle, CocoaPods, Swift package and
    CMake builds it generates from the same choice. Platforms where every
    candidate was chosen, which are most, are left out.
    """
    result = {}
    for platform in _PLATFORMS:
        on = chosen.get(platform, {})
        names = {p.name: True for p in plugins if _inline(p, platform) and p.name not in on}
        if names:
            result[platform] = names
    return result

def choose_implementations(plugins, app_dependencies):
    """Choose each plugin's implementation on each platform, as flutter_tools does.

    Args:
        plugins: The plugin structs of `FlutterInfo.plugins` that reach the
            application, possibly repeated.
        app_dependencies: depset[str] of the packages the application depends
            on directly (`FlutterInfo.app_dependencies` and its own). Read
            only where two implementations of one plugin compete.

    Returns:
        struct(native, dart, unchosen, warnings, error). `native` and `dart` are the plugins each
        set of registrants registers, each struct with only the platforms it
        is chosen on, and plugins chosen on none left out: `native` the choice
        over every implementation, which the native registrants and the web's
        follow, `dart` the choice over Dart implementations, which the Dart
        plugin registrant follows. Order a platform's with
        `plugins_on_platform`. `unchosen` maps a platform to the names, as a
        dict's keys, of the plugins with an implementation there that the
        native choice passed over, and has no entry for a platform where
        nothing was. `warnings` are flutter_tools' words, each once, about a
        `default_package` the choice ignored. `error` is flutter_tools' report when a
        platform's choice cannot be made or a plugin's `default_package` sits
        beside an implementation of its own, on any platform, whichever the
        application is built for; None otherwise, and `native`, `dart` and
        `unchosen` are None when it is not.
    """
    plugins = plugins_in_registration_order(plugins)

    # Flattened when first asked, which is only where implementations
    # compete: most applications never are.
    cache = {}

    def is_direct(name):
        if "names" not in cache:
            cache["names"] = {n: True for n in app_dependencies.to_list()}
        return name in cache["names"]

    # Both choices warn alike: flutter_tools asks whether a default
    # implements anything at all, whichever it is choosing.
    warnings = {}
    native, error = _resolve(plugins, _NATIVE_OR_DART, is_direct, warnings)
    if error:
        return struct(native = None, dart = None, unchosen = None, warnings = None, error = error)
    dart, error = _resolve(plugins, _DART, is_direct, warnings)
    if error:
        return struct(native = None, dart = None, unchosen = None, warnings = None, error = error)
    return struct(
        native = _restricted(plugins, native),
        dart = _restricted(plugins, dart),
        unchosen = _unchosen(plugins, native),
        warnings = list(warnings),
        error = None,
    )

def application_plugins(label, deps):
    """`choose_implementations` over the plugins an application's `deps` bring.

    The application's own `deps` are among its direct dependencies wherever
    the application is: it is the root, as the app is whose pubspec
    flutter_tools reads.

    Args:
        label: The application's label.
        deps: Its `deps`.

    Returns:
        struct(native, dart, unchosen, warnings), as `choose_implementations`
        has them. Fails with its error.
    """
    plugins = []
    transitive = []
    for dep in deps:
        if FlutterInfo in dep:
            plugins.extend(dep[FlutterInfo].plugins)
            transitive.append(dep[FlutterInfo].app_dependencies)
    chosen = choose_implementations(plugins, depset(direct_package_names(deps), transitive = transitive))
    if chosen.error:
        fail("%s: %s" % (label, chosen.error))
    return chosen

# The attribute `plugin_warnings_validation` reads: a rule that resolves an
# application's plugins declares it, with `PORTABLE`.
PLUGIN_WARNINGS_TOOL_ATTR = {
    "_print_warnings": attr.label(
        default = Label("//flutter/private/tools:print_warnings.dart"),
        allow_single_file = True,
    ),
}

def plugin_warnings_validation(ctx, resolution):
    """The action that prints the choice's warnings, as flutter_tools does.

    Args:
        ctx: The rule context, declaring `PLUGIN_WARNINGS_TOOL_ATTR` and
            `PORTABLE`.
        resolution: What `application_plugins` returned.

    Returns:
        The stamps for the `_validation` output group: none when there is
        nothing to say, else one, whose action prints each warning and
        succeeds, so a build of the target shows them.
    """
    if not resolution.warnings:
        return []
    tools = portable_tools(ctx)
    stamp = ctx.actions.declare_file(ctx.label.name + ".plugin_warnings")
    args = ctx.actions.args()
    args.add(ctx.file._print_warnings)
    args.add_all(resolution.warnings, before_each = "--warning")
    args.add("--stamp", stamp)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset([ctx.file._print_warnings], transitive = [tools.sdk_files.run]),
        outputs = [stamp],
        mnemonic = "FlutterPluginWarnings",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Warning of the plugin choices of %{label}",
    )
    return [stamp]

def chosen_native_libraries(resolution, platform, records):
    """The `native_deps` records of an application, without those of implementations it did not choose.

    flutter_tools builds no native code of an implementation the choice
    passed over on the platform being built, so its `native_deps` libraries
    stay out of the bundle, as its other native code does.

    Args:
        resolution: What `application_plugins` returned.
        platform: The platform being built (`detect_target_platform`).
        records: Records of `FlutterInfo.native_libraries`, each with its
            `package`.

    Returns:
        The records kept, in order.
    """
    names = resolution.unchosen.get(platform)
    if not names:
        return records
    return [r for r in records if r.package not in names]

def chosen_native_code(resolution, android_libs, apple_plugin_libraries, apple_privacy_manifests, linux_plugin_libraries, windows_plugin_libraries):
    """An application's native plugin code, without that of implementations it did not choose.

    Each entry is matched by the package it belongs to, and on Apple by its
    platform too. A privacy manifest is left out with the library of the
    plugin it ships with, which carries it. A depset is flattened only where
    the choice passed over an implementation on its platform, so an
    application with no competing implementations passes its own through.

    Args:
        resolution: What `application_plugins` returned.
        android_libs: depset of `FlutterInfo.android_libs` entries.
        apple_plugin_libraries: depset of `FlutterInfo.apple_plugin_libraries` entries.
        apple_privacy_manifests: depset[File] of `FlutterInfo.apple_privacy_manifests`.
        linux_plugin_libraries: depset of `FlutterInfo.linux_plugin_libraries` entries.
        windows_plugin_libraries: depset of `FlutterInfo.windows_plugin_libraries` entries.

    Returns:
        struct with the same fields, filtered.
    """
    unchosen = resolution.unchosen

    def keep(entries, platform):
        names = unchosen.get(platform)
        if not names:
            return entries
        return depset([e for e in entries.to_list() if e.package not in names])

    if unchosen.get("ios") or unchosen.get("macos"):
        kept = []
        dropped_manifests = {}
        for e in apple_plugin_libraries.to_list():
            if e.package in unchosen.get(e.platform, {}):
                for f in e.privacy_manifests:
                    dropped_manifests[f] = True
            else:
                kept.append(e)
        apple_plugin_libraries = depset(kept)
        if dropped_manifests:
            apple_privacy_manifests = depset([f for f in apple_privacy_manifests.to_list() if f not in dropped_manifests])

    return struct(
        android_libs = keep(android_libs, "android"),
        apple_plugin_libraries = apple_plugin_libraries,
        apple_privacy_manifests = apple_privacy_manifests,
        linux_plugin_libraries = keep(linux_plugin_libraries, "linux"),
        windows_plugin_libraries = keep(windows_plugin_libraries, "windows"),
    )
