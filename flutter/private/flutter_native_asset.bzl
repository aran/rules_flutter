"""`flutter_native_asset` — captures Native Assets `CodeAsset` metadata.

Composes existing primitives. The rule does not produce or rebuild a
binary; it only reads `CcSharedLibraryInfo` (or nothing, for non-bundled
modes) and stamps a `FlutterNativeAssetInfo` provider that the
application-side aggregator reads to emit the `--native-assets`
manifest the frontend_server consumes.

Four currently-supported `LinkMode` values:

  * `dynamic_loading_bundle` — `library` (a `cc_shared_library`) is
    required; the rule grabs the per-platform shared library File from
    `CcSharedLibraryInfo.linker_input.libraries[0].dynamic_library` and
    plumbs both the manifest entry and the file (so the platform
    application rule can embed it).
  * `dynamic_loading_system` — `system_uri` is required (e.g.
    `libsqlite3.so.0`); manifest-only entry, no bundling.
  * `dynamic_loading_executable` — manifest-only entry; engine looks up
    symbols in the runner executable.
  * `dynamic_loading_process` — manifest-only entry; engine uses
    `dlsym(RTLD_DEFAULT, …)`.

`static` is rejected with a pointer to the upstream Dart tracker —
neither the Dart SDK nor the Flutter engine implement static linking
of Native Assets today.
"""

load("@rules_cc//cc/common:cc_shared_library_info.bzl", "CcSharedLibraryInfo")
load("//flutter:providers.bzl", "FlutterInfo", "FlutterNativeAssetInfo")

_VALID_LINK_MODES = (
    "dynamic_loading_bundle",
    "dynamic_loading_system",
    "dynamic_loading_executable",
    "dynamic_loading_process",
)

_VALID_TARGET_OSES = ("macos", "ios", "linux", "windows", "android")

def _extract_dynamic_library(library_target):
    """Pull the dynamic-library File out of a `cc_shared_library` target.

    `cc_shared_library` advertises its produced shared library through
    `CcSharedLibraryInfo.linker_input.libraries[*].dynamic_library`.
    There's exactly one such library per `cc_shared_library`; we return
    it directly.
    """
    if CcSharedLibraryInfo not in library_target:
        fail(
            "flutter_native_asset(library = %s) must point at a target " % library_target.label +
            "that provides CcSharedLibraryInfo (i.e. a `cc_shared_library`).",
        )
    info = library_target[CcSharedLibraryInfo]
    libraries = info.linker_input.libraries
    if not libraries:
        fail("flutter_native_asset: `library` %s has no libraries in its CcSharedLibraryInfo" % library_target.label)
    for lib in libraries:
        if lib.dynamic_library != None:
            return lib.dynamic_library
    fail("flutter_native_asset: `library` %s has no dynamic_library File on its CcSharedLibraryInfo" % library_target.label)

def _flutter_native_asset_impl(ctx):
    link_mode = ctx.attr.link_mode

    if link_mode == "static":
        fail(
            "flutter_native_asset: link_mode = \"static\" is reserved by the " +
            "Dart SDK but not yet implemented by either the Dart or Flutter " +
            "runtimes. Track upstream support at " +
            "https://github.com/dart-lang/sdk/issues/49418. Use " +
            "`dynamic_loading_bundle` for embedded shared libraries until " +
            "that lands.",
        )

    if link_mode not in _VALID_LINK_MODES:
        fail(
            "flutter_native_asset: invalid link_mode %r. Expected one of: %s." % (
                link_mode,
                ", ".join(_VALID_LINK_MODES),
            ),
        )

    if ctx.attr.target_os not in _VALID_TARGET_OSES:
        fail(
            "flutter_native_asset: target_os %r is not one of %s." % (
                ctx.attr.target_os,
                ", ".join(_VALID_TARGET_OSES),
            ),
        )

    files_depset = depset()
    bundle_filename = ""
    system_uri = ""

    if link_mode == "dynamic_loading_bundle":
        if ctx.attr.library == None:
            fail("flutter_native_asset: link_mode = \"dynamic_loading_bundle\" requires `library = <cc_shared_library>`.")
        if not ctx.attr.bundle_filename:
            fail("flutter_native_asset: link_mode = \"dynamic_loading_bundle\" requires `bundle_filename = \"<basename>\"`.")
        if ctx.attr.system_uri:
            fail("flutter_native_asset: `system_uri` is only valid with link_mode = \"dynamic_loading_system\".")
        cc_dylib = _extract_dynamic_library(ctx.attr.library)

        # Re-declare the dylib in this rule's output namespace at
        # `<bundle_filename>`. rules_apple's `additional_contents`
        # machinery uses the file's package-relative path inside the
        # destination directory — `Contents/Frameworks/<bundle_filename>`
        # is what we want — and a raw cc_shared_library output's short_path
        # lives under `_solib_<arch>/...` which trips
        # `bundle_paths.owner_relative_path`.
        #
        # If the underlying cc_shared_library uses the same filename for
        # its `shared_lib_name`, this declare_file collides; the overlay
        # is responsible for naming `cc_shared_library(shared_lib_name)`
        # to something other than the bundle filename. The error from
        # Bazel ("file is generated by these conflicting actions") is the
        # signal to rename.
        dylib = ctx.actions.declare_file(ctx.attr.bundle_filename)
        ctx.actions.symlink(output = dylib, target_file = cc_dylib)
        files_depset = depset([dylib])
        bundle_filename = ctx.attr.bundle_filename
    elif link_mode == "dynamic_loading_system":
        if not ctx.attr.system_uri:
            fail("flutter_native_asset: link_mode = \"dynamic_loading_system\" requires `system_uri = \"<uri>\"`.")
        if ctx.attr.library != None:
            fail("flutter_native_asset: `library` is only valid with link_mode = \"dynamic_loading_bundle\".")
        if ctx.attr.bundle_filename:
            fail("flutter_native_asset: `bundle_filename` is only valid with link_mode = \"dynamic_loading_bundle\".")
        system_uri = ctx.attr.system_uri
    else:  # dynamic_loading_executable / dynamic_loading_process
        if ctx.attr.library != None:
            fail("flutter_native_asset: `library` is only valid with link_mode = \"dynamic_loading_bundle\".")
        if ctx.attr.bundle_filename:
            fail("flutter_native_asset: `bundle_filename` is only valid with link_mode = \"dynamic_loading_bundle\".")
        if ctx.attr.system_uri:
            fail("flutter_native_asset: `system_uri` is only valid with link_mode = \"dynamic_loading_system\".")

    asset_info = FlutterNativeAssetInfo(
        asset_id = ctx.attr.asset_id,
        link_mode = link_mode,
        files = files_depset,
        target_os = ctx.attr.target_os,
        bundle_filename = bundle_filename,
        system_uri = system_uri,
    )

    # Mirror the FlutterInfo shape so flutter_native_asset targets can be
    # listed directly in `flutter_application(deps = ...)` if a workspace
    # prefers that over routing through `flutter_plugin(native_assets = ...)`.
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
        native_assets = depset([asset_info]),
        data_assets = depset(),
        pub_fonts = depset(),
        pub_assets = depset(),
        pub_shaders = depset(),
    )

    return [
        DefaultInfo(files = files_depset),
        asset_info,
        flutter_info,
    ]

flutter_native_asset = rule(
    implementation = _flutter_native_asset_impl,
    attrs = {
        "asset_id": attr.string(
            doc = "The Dart asset id (e.g. `package:objective_c/objective_c.dylib`). " +
                  "This is the id Dart code binds to with `@Native(assetId: ...)` " +
                  "(or `Native.addressOf`); the VM resolves it at bind time through " +
                  "the kernel manifest the frontend_server reads. Note raw " +
                  "`DynamicLibrary.open(...)` does NOT resolve asset ids — the VM " +
                  "passes the literal string to `dlopen`.",
            mandatory = True,
        ),
        "link_mode": attr.string(
            doc = "Link mode. One of `dynamic_loading_bundle`, " +
                  "`dynamic_loading_system`, `dynamic_loading_executable`, " +
                  "`dynamic_loading_process`. The reserved `static` mode " +
                  "fails fast — neither Dart nor Flutter implements it today.",
            mandatory = True,
            values = list(_VALID_LINK_MODES) + ["static"],
        ),
        "library": attr.label(
            doc = "A `cc_shared_library` target whose dynamic library will be " +
                  "embedded into the app bundle. Required for " +
                  "`dynamic_loading_bundle`; forbidden for the other modes.",
            providers = [CcSharedLibraryInfo],
        ),
        "bundle_filename": attr.string(
            doc = "Filename inside the platform bundle slot (e.g. " +
                  "`objective_c.dylib`). Required for `dynamic_loading_bundle`.",
        ),
        "system_uri": attr.string(
            doc = "System library URI, e.g. `libsqlite3.so.0`. Required for " +
                  "`dynamic_loading_system`.",
        ),
        "target_os": attr.string(
            doc = "Target OS this asset applies to.",
            mandatory = True,
            values = list(_VALID_TARGET_OSES),
        ),
    },
    doc = "Captures a Native Assets `CodeAsset` declaration. Composes existing rules — does not produce or rebuild any binary itself.",
    provides = [FlutterNativeAssetInfo, FlutterInfo],
)
