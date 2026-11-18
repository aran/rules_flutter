"""The `FlutterInfo` constructor.

`FlutterInfo` is built by several rules — `flutter_library`, `flutter_plugin`
and `flutter_material_icons`.
Construction goes through here so no caller decides how a field merges: a rule
that does not contribute on a channel must still forward its dependencies'
values, and writing `depset()` instead silently drops them.

Reading does not go through here: `FlutterInfo` stays public and is indexed
directly by every consumer.

This mirrors `dart_info()` in rules_dart, deliberately — the two providers
travel together and a reader who has understood one should recognise the other.
The one structural difference is that `DartInfo` always records a package of
its own, so it needs a second constructor for the degenerate case, while every
`FlutterInfo` channel is optional by nature. Contributing on none of them is an
ordinary call with no arguments, not a special one.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("//flutter:providers.bzl", "FlutterInfo")

visibility("//flutter/...")

def dedup_plugins(all_plugins):
    """Deduplicates plugin structs by name, keeping first occurrence.

    A plugin reached through two paths in the dependency graph — the common
    case for a federated pub plugin — must be registered once.

    Args:
        all_plugins: List of plugin structs.

    Returns:
        List of unique plugin structs, in first-seen order.
    """
    seen = {}
    unique = []
    for p in all_plugins:
        if p.name not in seen:
            seen[p.name] = True
            unique.append(p)
    return unique

def plugins_in_registration_order(all_plugins):
    """The plugins of an app, each once, in the order the app registers them.

    A plugin comes after every plugin its package depends on directly, so a
    plugin that relies on another's state finds it set up; plugins with no
    dependency between them come in name order. A dependency cycle is broken
    at the unplaced plugin with the fewest unplaced dependencies, by name.
    flutter_tools' `sortByDependencies`, which every registrant it generates
    follows.

    Args:
        all_plugins: Plugin structs, possibly repeated (`dedup_plugins`). A
            struct's `dependencies` names the plugins its package depends on
            directly; one without the field depends on none.

    Returns:
        The unique plugin structs, ordered.
    """
    plugins = {p.name: p for p in dedup_plugins(all_plugins)}
    in_degree = {}
    dependents = {name: [] for name in plugins}
    for name, plugin in plugins.items():
        deps = {
            dep: True
            for dep in getattr(plugin, "dependencies", [])
            if dep != name and dep in plugins
        }
        in_degree[name] = len(deps)
        for dep in deps:
            dependents[dep].append(name)

    available = sorted([name for name, degree in in_degree.items() if degree == 0])
    placed = {}
    ordered = []

    # Each pass places one plugin, so as many passes as plugins suffice.
    for _ in plugins:
        if not available:
            unplaced = [name for name in plugins if name not in placed]
            available = [sorted(unplaced, key = lambda n: (in_degree[n], n))[0]]
        current = available.pop(0)
        placed[current] = True
        ordered.append(plugins[current])
        freed = []
        for dependent in dependents[current]:
            in_degree[dependent] -= 1
            if in_degree[dependent] == 0 and dependent not in placed:
                freed.append(dependent)
        if freed:
            available = sorted(available + freed)
    return ordered

def direct_package_names(deps):
    """The packages `deps` themselves are, by name: what a target depends on directly.

    What a `flutter_library` of the main repository gives `flutter_info()`
    as its `app_dependencies`.

    Args:
        deps: Targets, those without `DartInfo` ignored.

    Returns:
        A list of package names.
    """
    return [package.package_name for dep in deps if DartInfo in dep for package in dep[DartInfo].packages]

def plugins_on_platform(plugins, platform):
    """The plugins registered on `platform`, in the order its registrant registers them.

    flutter_tools orders each platform's plugins among themselves
    (`sortByDependencies` over the plugins chosen on it), which is not always
    the order of every plugin with the others left out.

    Args:
        plugins: Plugin structs, as `FlutterApplicationInfo.plugins` holds them.
        platform: The platform.

    Returns:
        The plugins with an entry for `platform`, ordered.
    """
    return plugins_in_registration_order([p for p in plugins if platform in p.platforms])

def _with_dependencies(plugin, deps, package_dependencies, plugin_names):
    """[plugin] with `dependencies`: the plugins its package depends on directly.

    Those `package_dependencies` names for its package, when it names any:
    the packages of its pubspec's `dependencies` that are plugins
    (`plugin_names`). Otherwise those its target's direct `deps` declare. A
    dependency declares the plugins of its own packages (a plugin's name is
    its package's), not those it only passes on from its own dependencies, so
    a plugin reached through a package that is not one is no dependency, as
    pub's direct dependencies are what flutter_tools orders by.
    """
    if plugin.name in package_dependencies:
        names = {n: True for n in package_dependencies[plugin.name] if n in plugin_names and n != plugin.name}
        return struct(name = plugin.name, platforms = plugin.platforms, dependencies = sorted(names), implements = plugin.implements)
    names = {}
    for dep in deps:
        if FlutterInfo not in dep or DartInfo not in dep:
            continue
        own = {package.package_name: True for package in dep[DartInfo].packages}
        for p in dep[FlutterInfo].plugins:
            if p.name in own:
                names[p.name] = True
    return struct(name = plugin.name, platforms = plugin.platforms, dependencies = sorted(names), implements = plugin.implements)

def flutter_info(
        deps = [],
        shader_srcs = [],
        plugins = [],
        native_libraries = [],
        apple_plugin_libraries = [],
        linux_plugin_libraries = [],
        windows_plugin_libraries = [],
        apple_privacy_manifests = [],
        pub_fonts = [],
        pub_assets = [],
        pub_shaders = [],
        additional_licenses = [],
        android_libs = [],
        app_dependencies = [],
        package_dependencies = {}):
    """Builds a `FlutterInfo`, merging its dependencies' contributions.

    The caller supplies only what this target contributes itself, as plain
    lists; everything transitive is merged here. Adding a field to
    `FlutterInfo` is therefore a change to this function and nothing else.

    A `deps` entry with no `FlutterInfo` is skipped rather than an error: a
    Flutter target's `deps` legally holds plain `dart_library` targets, and
    every caller would otherwise re-derive that check.

    Args:
      deps: Targets whose `FlutterInfo` contributions are merged in. Entries
        without one are ignored.
      shader_srcs: The Flutter framework's own shader sources (`.frag`/`.glsl`),
        which only `package:flutter` ships.
      plugins: Plugin metadata structs this target declares. Deduplicated by
        name against the dependencies' plugins, this target's first.
      native_libraries: The records of the native libraries this target
        contributes, typically from a plugin's `native_deps`: see
        `FlutterInfo.native_libraries` and `native_library_records`.
      apple_plugin_libraries: Apple plugin library structs this target
        declares (`platform`, `label`, `cc_info`, `swift_info`, `package`).
      linux_plugin_libraries: Linux plugin source bundles this target declares
        (`label`, `srcs`, `hdrs`, `include_dirs`, `package`).
      windows_plugin_libraries: Windows plugin source bundles, same shape.
      apple_privacy_manifests: `PrivacyInfo.xcprivacy` files this target ships.
      pub_fonts: Font contribution structs from a pub `flutter.fonts` block.
      pub_assets: Asset contribution structs from a pub `flutter.assets` block.
      pub_shaders: Shader contribution structs from a `flutter.shaders` block.
      additional_licenses: `struct(package_name, files)` pairs this target
        contributes, the files of its `flutter: licenses:`.
      android_libs: `struct(package, group, lib)` records this target
        contributes, one per plugin Android library it selects (`lib` is the
        `JavaInfo`-bearing Target; `group` the Maven group of the plugin's
        Android `flutter_plugin_platform`, or "").
      app_dependencies: The packages, by name, this target depends on
        directly, when it is one whose dependencies are the application's
        (`FlutterInfo.app_dependencies`).
      package_dependencies: For a package of `plugins`, the packages its
        pubspec depends on directly, by name: what its plugin's
        `dependencies` are read from in place of `deps`, for a target that
        builds several packages whose dependencies differ (a pub dependency
        cycle).

    Returns:
      A `FlutterInfo`.
    """
    dep_infos = [dep[FlutterInfo] for dep in deps if FlutterInfo in dep]

    dep_plugins = []
    for info in dep_infos:
        dep_plugins.extend(info.plugins)
    plugin_names = {p.name: True for p in plugins + dep_plugins} if package_dependencies else {}

    return FlutterInfo(
        shader_srcs = depset(
            direct = shader_srcs,
            transitive = [info.shader_srcs for info in dep_infos],
        ),
        # A list, not a depset: the structs carry a `platforms` dict, which is
        # unhashable. Order is meaningful to the registrant generators, and
        # this target's own plugins come first.
        plugins = dedup_plugins([_with_dependencies(p, deps, package_dependencies, plugin_names) for p in plugins] + dep_plugins),
        native_libraries = depset(
            direct = native_libraries,
            transitive = [info.native_libraries for info in dep_infos],
        ),
        # Four per-platform channels rather than one tagged union, because the
        # integration mechanisms genuinely differ: Apple carries compiled
        # `CcInfo`/`SwiftInfo` to link against, Linux and Windows carry source
        # bundles their runner folds into its own compile. Apple multiplexes
        # macOS and iOS in one channel precisely because those two do share a
        # mechanism.
        apple_plugin_libraries = depset(
            direct = apple_plugin_libraries,
            transitive = [info.apple_plugin_libraries for info in dep_infos],
        ),
        linux_plugin_libraries = depset(
            direct = linux_plugin_libraries,
            transitive = [info.linux_plugin_libraries for info in dep_infos],
        ),
        windows_plugin_libraries = depset(
            direct = windows_plugin_libraries,
            transitive = [info.windows_plugin_libraries for info in dep_infos],
        ),
        apple_privacy_manifests = depset(
            direct = apple_privacy_manifests,
            transitive = [info.apple_privacy_manifests for info in dep_infos],
        ),
        pub_fonts = depset(
            direct = pub_fonts,
            transitive = [info.pub_fonts for info in dep_infos],
        ),
        pub_assets = depset(
            direct = pub_assets,
            transitive = [info.pub_assets for info in dep_infos],
        ),
        pub_shaders = depset(
            direct = pub_shaders,
            transitive = [info.pub_shaders for info in dep_infos],
        ),
        additional_licenses = depset(
            direct = additional_licenses,
            transitive = [info.additional_licenses for info in dep_infos],
        ),
        android_libs = depset(
            direct = android_libs,
            transitive = [info.android_libs for info in dep_infos],
        ),
        app_dependencies = depset(
            direct = app_dependencies,
            transitive = [info.app_dependencies for info in dep_infos],
        ),
    )
