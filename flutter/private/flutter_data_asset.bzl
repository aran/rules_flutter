"""`flutter_data_asset` — captures Native Assets `DataAsset` metadata.

Each declaration carries a single file, an `asset_id` of the form
`package:<pkg>/<within-package-name>` (matching the Dart Native
Assets spec), and propagates a `FlutterDataAssetInfo` that
`flutter_application` reads to bundle the file at
`flutter_assets/data/<pkg>/<name>` (matching `InstallDataAssets` in
flutter_tools).
"""

load("//flutter:providers.bzl", "FlutterDataAssetInfo", "FlutterInfo")

def _split_asset_id(asset_id):
    """Split a `package:<pkg>/<name>` asset id into (package, name).

    `<name>` may contain slashes — we split on the first `/` only.
    """
    if not asset_id.startswith("package:"):
        fail("flutter_data_asset: asset_id %r must start with `package:`." % asset_id)
    rest = asset_id[len("package:"):]
    if "/" not in rest:
        fail("flutter_data_asset: asset_id %r must be of the form `package:<pkg>/<name>`." % asset_id)
    pkg, _, name = rest.partition("/")
    if not pkg or not name:
        fail("flutter_data_asset: asset_id %r must contain a non-empty package and name." % asset_id)
    return pkg, name

def _flutter_data_asset_impl(ctx):
    pkg, name = _split_asset_id(ctx.attr.asset_id)
    if not ctx.file.file:
        fail("flutter_data_asset: `file` is required.")

    info = FlutterDataAssetInfo(
        asset_id = ctx.attr.asset_id,
        package = pkg,
        name = name,
        file = ctx.file.file,
    )

    flutter_info = FlutterInfo(
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
        data_assets = depset([info]),
        pub_fonts = depset(),
        pub_assets = depset(),
        pub_shaders = depset(),
    )

    return [
        DefaultInfo(files = depset([ctx.file.file])),
        info,
        flutter_info,
    ]

flutter_data_asset = rule(
    implementation = _flutter_data_asset_impl,
    attrs = {
        "asset_id": attr.string(
            doc = "Native Assets `DataAsset` id of the form " +
                  "`package:<pkg>/<within-package-name>`. Bundled at " +
                  "`flutter_assets/data/<pkg>/<within-package-name>`.",
            mandatory = True,
        ),
        "file": attr.label(
            doc = "The data file to bundle. A single file label.",
            mandatory = True,
            allow_single_file = True,
        ),
    },
    doc = "Captures a Native Assets `DataAsset` declaration.",
    provides = [FlutterDataAssetInfo, FlutterInfo],
)
