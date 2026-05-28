"""Toolchain-backed MaterialIcons font target.

`@rules_flutter//flutter:material_icons` is a regular FlutterInfo provider
target — same shape as any pub-spoke `flutter_library` shipping a font —
backed by the active flutter toolchain's MaterialIcons-Regular.otf file.

Apps that use Material widgets opt in by listing this label in their
`flutter_application(deps = [...])`. The asset-bundle aggregator walks
transitive `FlutterInfo.pub_fonts` and bundles MaterialIcons via the same
code path it uses for cupertino_icons or any other pub package's font —
no special case in `flutter_build_assets`.

The `package_name = ""` sentinel on the contribution tells the aggregator
to bundle the font at bare `fonts/MaterialIcons-Regular.otf` and to write
FontManifest family `MaterialIcons` (no `packages/<pkg>/` prefix). This
matches Flutter's built-in MaterialIcons widget, which references the
font via `fontFamily: "MaterialIcons"` with no `fontPackage` — so
const_finder's tree-shaking key shape is preserved.

A single small custom rule (rather than a `flutter_library` macro) avoids
selecting the platform-specific toolchain repo at the call site: the rule
discovers the font File via `ctx.toolchains[...]` instead.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("//flutter:providers.bzl", "FlutterInfo")

_MATERIAL_ICONS_BUNDLE_PATH = "fonts/MaterialIcons-Regular.otf"

def _flutter_material_icons_impl(ctx):
    toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    material_font = toolchain.flutter_sdk_info.material_icons_font
    if not material_font:
        fail("Flutter toolchain does not provide material_icons_font; cannot " +
             "build @rules_flutter//flutter:material_icons.")

    # Tuples (not lists) inside the struct because depset elements must be
    # fully immutable — mutable fields propagate to the struct's mutability.
    contribution = struct(
        package_name = "",
        family = "MaterialIcons",
        fonts = (struct(
            asset_path = _MATERIAL_ICONS_BUNDLE_PATH,
            weight = None,
            style = None,
        ),),
        files = (material_font,),
    )

    return [
        DefaultInfo(files = depset([material_font])),
        # Empty DartInfo so consumers can list this target in
        # `flutter_application(deps = [...])` (whose `deps` attr requires
        # DartInfo). The empty depsets contribute nothing to the consumer's
        # package_config.json or transitive sources — material_icons ships
        # zero Dart code; only the font.
        DartInfo(
            package_name = "rules_flutter_material_icons",
            lib_root = "",
            transitive_srcs = depset(),
            transitive_packages = depset(),
        ),
        FlutterInfo(
            asset_dirs = depset(),
            shader_srcs = depset(),
            plugins = [],
            transitive_native_libs = depset(),
            apple_plugin_libraries = depset(),
            linux_plugin_libraries = depset(),
            windows_plugin_libraries = depset(),
            android_plugin_libraries = depset(),
            apple_privacy_manifests = depset(),
            native_assets = depset(),
            data_assets = depset(),
            pub_fonts = depset([contribution]),
            pub_assets = depset(),
            pub_shaders = depset(),
        ),
    ]

flutter_material_icons = rule(
    implementation = _flutter_material_icons_impl,
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
    doc = "Toolchain-backed MaterialIcons font target. List in " +
          "`flutter_application(deps = [...])` to bundle MaterialIcons.",
)
