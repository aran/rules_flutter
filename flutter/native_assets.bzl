"""Public Tier-2 surface for Flutter Native Assets.

Re-exports the marker rules used by `ext/<pkg>/<major>/BUILD.bazel.tpl`
overlays and by monorepo plugins that want to declare Native Assets
without going through the pub-spoke ext mechanism.

Typical usage in an overlay or hand-written BUILD:

    load("@rules_cc//cc:cc_shared_library.bzl", "cc_shared_library")
    load("@rules_cc//cc:objc_library.bzl", "objc_library")
    load("@rules_flutter//flutter:native_assets.bzl",
        "flutter_native_asset",
        "flutter_data_asset")

    objc_library(name = "_pkg_objc", srcs = [...], copts = ["-fobjc-arc"])
    cc_shared_library(
        name = "_pkg_dylib",
        deps = [":_pkg_objc"],
        user_link_flags = ["-Wl,-install_name,@rpath/pkg.dylib"],
    )
    flutter_native_asset(
        name = "pkg_native_asset_macos",
        asset_id = "package:pkg/pkg.dylib",
        link_mode = "dynamic_loading_bundle",
        library = ":_pkg_dylib",
        bundle_filename = "pkg.dylib",
        target_os = "macos",
    )

    flutter_data_asset(
        name = "blob",
        asset_id = "package:pkg/blob.bin",
        file = "data/blob.bin",
    )
"""

load(
    "//flutter/private:flutter_data_asset.bzl",
    _flutter_data_asset = "flutter_data_asset",
)
load(
    "//flutter/private:flutter_native_asset.bzl",
    _flutter_native_asset = "flutter_native_asset",
)
load(
    "//flutter/private:flutter_native_assets.bzl",
    _flutter_native_assets_manifest = "flutter_native_assets_manifest",
)

flutter_native_asset = _flutter_native_asset
flutter_data_asset = _flutter_data_asset
flutter_native_assets_manifest = _flutter_native_assets_manifest
