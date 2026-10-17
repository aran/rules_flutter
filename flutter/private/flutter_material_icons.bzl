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

load("@rules_dart//dart:utils.bzl", "dart_info_no_package")
load("//flutter/private:flutter_info.bzl", "flutter_info")

_MATERIAL_ICONS_BUNDLE_PATH = "fonts/MaterialIcons-Regular.otf"

def _flutter_material_icons_impl(ctx):
    toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    material_tc = ctx.toolchains["@rules_flutter//flutter/private:material_icons_toolchain_type"]
    font_subset_tc = ctx.toolchains["@rules_flutter//flutter/private:font_subset_toolchain_type"]
    material_font = toolchain.flutter_sdk_info.material_icons_font or (material_tc.material_icons_font if material_tc else None)
    if not material_font:
        fail("Flutter toolchain does not provide material_icons_font; cannot " +
             "build @rules_flutter//flutter:material_icons.")
    const_finder = toolchain.flutter_sdk_info.const_finder or (font_subset_tc.const_finder if font_subset_tc else None)
    font_subset = toolchain.flutter_sdk_info.font_subset or (font_subset_tc.font_subset if font_subset_tc else None)

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
        const_finder = const_finder,
        font_subset = font_subset,
    )

    return [
        DefaultInfo(files = depset([material_font])),
        # A DartInfo so consumers can list this target in
        # `flutter_application(deps = [...])`, whose `deps` attr requires one.
        # It records no package, so it contributes nothing to the consumer's
        # package_config.json or transitive sources — material_icons ships zero
        # Dart code; only the font.
        dart_info_no_package(),
        flutter_info(pub_fonts = [contribution]),
    ]

flutter_material_icons = rule(
    implementation = _flutter_material_icons_impl,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_flutter//flutter/private:material_icons_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_flutter//flutter/private:font_subset_toolchain_type", mandatory = False),
    ],
    doc = "Toolchain-backed MaterialIcons font target. List in " +
          "`flutter_application(deps = [...])` to bundle MaterialIcons.",
)
