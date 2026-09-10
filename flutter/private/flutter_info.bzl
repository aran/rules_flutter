"""The `FlutterInfo` constructor.

`FlutterInfo` is built by several rules — `flutter_library`, `flutter_plugin`,
`flutter_native_asset`, `flutter_data_asset` and `flutter_material_icons`.
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

load("//flutter:providers.bzl", "FlutterInfo")

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

def flutter_info(
        deps = [],
        asset_dirs = [],
        shader_srcs = [],
        plugins = [],
        native_libs = [],
        apple_plugin_libraries = [],
        linux_plugin_libraries = [],
        windows_plugin_libraries = [],
        apple_privacy_manifests = [],
        native_assets = [],
        data_assets = [],
        pub_fonts = [],
        pub_assets = [],
        pub_shaders = []):
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
      asset_dirs: Directories of Flutter assets this target ships.
      shader_srcs: Raw shader sources (`.frag`/`.glsl`) this target ships.
      plugins: Plugin metadata structs this target declares. Deduplicated by
        name against the dependencies' plugins, this target's first.
      native_libs: Shared libraries this target contributes, typically from a
        plugin's `native_deps`.
      apple_plugin_libraries: Apple plugin library structs this target
        declares (`platform`, `label`, `cc_info`, `swift_info`, `package`).
      linux_plugin_libraries: Linux plugin source bundles this target declares
        (`label`, `srcs`, `hdrs`, `include_dirs`, `package`).
      windows_plugin_libraries: Windows plugin source bundles, same shape.
      apple_privacy_manifests: `PrivacyInfo.xcprivacy` files this target ships.
      native_assets: `FlutterNativeAssetInfo` providers this target declares.
      data_assets: `FlutterDataAssetInfo` providers this target declares.
      pub_fonts: Font contribution structs from a pub `flutter.fonts` block.
      pub_assets: Asset contribution structs from a pub `flutter.assets` block.
      pub_shaders: Shader contribution structs from a `flutter.shaders` block.

    Returns:
      A `FlutterInfo`.
    """
    dep_infos = [dep[FlutterInfo] for dep in deps if FlutterInfo in dep]

    dep_plugins = []
    for info in dep_infos:
        dep_plugins.extend(info.plugins)

    return FlutterInfo(
        asset_dirs = depset(
            direct = asset_dirs,
            transitive = [info.asset_dirs for info in dep_infos],
        ),
        shader_srcs = depset(
            direct = shader_srcs,
            transitive = [info.shader_srcs for info in dep_infos],
        ),
        # A list, not a depset: the structs carry a `platforms` dict, which is
        # unhashable. Order is meaningful to the registrant generators, and
        # this target's own plugins come first.
        plugins = dedup_plugins(plugins + dep_plugins),
        transitive_native_libs = depset(
            direct = native_libs,
            transitive = [info.transitive_native_libs for info in dep_infos],
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
        native_assets = depset(
            direct = native_assets,
            transitive = [info.native_assets for info in dep_infos],
        ),
        data_assets = depset(
            direct = data_assets,
            transitive = [info.data_assets for info in dep_infos],
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
    )
