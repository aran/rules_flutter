"""`flutter_native_assets_manifest` — emits the `--native-assets` JSON
manifest the Flutter frontend_server reads.

The frontend_server's `--native-assets` flag points at a JSON file in
the format produced by Flutter's frontend_server (see
`packages/flutter_tools/lib/src/isolated/native_assets/dart_hook_result.dart`
in the flutter/flutter repository). Per-target
section, per-asset entry:

    {
      "format-version": [1, 0, 0],
      "native-assets": {
        "macos_arm64": {
          "package:objective_c/objective_c.dylib": ["absolute", "objective_c.dylib"],
          "package:libsqlite3/libsqlite3.so": ["system", "libsqlite3.so.0"]
        }
      }
    }

The manifest is always emitted, even when the depset is empty
(`{"format-version":[1,0,0],"native-assets":{}}`). That keeps the
kernel-compile path uniform — no `if manifest:` branches downstream.

The Flutter engine reads the relative-path entries verbatim and
`dlopen`s them inside the platform bundle slot:

  * macOS: `<App>.app/Contents/Frameworks/<basename>` (loose dylib)
  * iOS:   `<App>.app/Frameworks/<name>.framework/<name>` — iOS forbids
           loose embedded dylibs, so each `dynamic_loading_bundle` asset is
           wrapped in its own `.framework` (matching flutter_tools'
           `frameworkUri`). The manifest entry is the framework-relative path.
  * Linux: `<bundle>/lib/<basename>` (resolved relative to the runner)
  * Windows: next to the runner exe
  * Android: `lib/<abi>/<basename>` inside the APK

Multi-arch Apple builds are out of scope: rules_flutter targets one
arch per `bazel build` invocation. Universal binaries flow through
`apple_universal_binary` over the dylib outputs at the user's
discretion.
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo")

# Map (target_os, arch) → the Target string Dart's
# `Target.fromArchitectureAndOS` would produce. Keep this mirrored
# with the `hooks_runner` package's `lib/src/model/target.dart`
# (published on pub.dev). The string format is `<os>_<arch>` with
# OS lowercased and architecture lowercased (e.g. `macos_arm64`,
# `ios_arm64`, `linux_x64`, `windows_x64`, `android_arm64`).
_OS_ARCH_TO_TARGET = {
    ("macos", "arm64"): "macos_arm64",
    ("macos", "x64"): "macos_x64",
    ("ios", "arm64"): "ios_arm64",
    ("ios", "x64"): "ios_x64",
    ("linux", "arm64"): "linux_arm64",
    ("linux", "x64"): "linux_x64",
    ("linux", "arm"): "linux_arm",
    ("windows", "arm64"): "windows_arm64",
    ("windows", "x64"): "windows_x64",
    ("android", "arm64"): "android_arm64",
    ("android", "arm"): "android_arm",
    ("android", "x64"): "android_x64",
}

def native_asset_framework_name(filename):
    """Derive the framework name for a bundled native-asset dylib on Apple.

    Mirrors flutter_tools' `frameworkUri` (native_assets_host.dart): strip a
    trailing `.dylib`, drop a leading `lib`, and sanitize to `[A-Za-z0-9_-]`.
    iOS embeds each `dynamic_loading_bundle` dylib as `<name>.framework/<name>`.
    The manifest path and the framework-assembly rule both call this so they
    agree on the name.

    Args:
      filename: The dylib's basename (e.g. `objective_c.dylib`).

    Returns:
      The sanitized framework name (e.g. `objective_c`).
    """
    name = filename
    if name.endswith(".dylib"):
        name = name[:-len(".dylib")]
        if name.startswith("lib"):
            name = name[len("lib"):]
    sanitized = ""
    for c in name.elems():
        if c.isalnum() or c == "_" or c == "-":
            sanitized += c
    return sanitized

def _path_list_for(asset, target_os):
    """Return the manifest path-list shape for `asset`.

    For `dynamic_loading_bundle` the engine's `KernelAssetAbsolutePath` is the
    path it `dlopen`s inside the bundle. On iOS the dylib is wrapped in a
    `.framework`, so the path is `<name>.framework/<name>`; every other OS
    places a loose dylib/so/dll and uses the bare basename.
    """
    if asset.link_mode == "dynamic_loading_bundle":
        if target_os == "ios":
            fw = native_asset_framework_name(asset.bundle_filename)
            return ["absolute", "%s.framework/%s" % (fw, fw)]
        return ["absolute", asset.bundle_filename]
    if asset.link_mode == "dynamic_loading_system":
        return ["system", asset.system_uri]
    if asset.link_mode == "dynamic_loading_executable":
        return ["executable"]
    if asset.link_mode == "dynamic_loading_process":
        return ["process"]
    fail("flutter_native_assets_manifest: unsupported link_mode %r" % asset.link_mode)

def native_assets_target_string(target_os, target_arch):
    """Return the Dart Target string for a (target_os, arch) pair, or "".

    Used by `flutter_application` to label the per-target manifest
    section. Returns "" when the pair isn't supported, in which case
    the caller emits an empty `native-assets` dict (which is still
    valid for the engine).
    """
    if not target_os or not target_arch:
        return ""
    return _OS_ARCH_TO_TARGET.get((target_os, target_arch), "")

def write_native_assets_manifest(
        ctx,
        output_file,
        native_assets,
        target_os,
        target_arch):
    """Write the canonical `--native-assets` JSON manifest.

    Filters `native_assets` (a list of `FlutterNativeAssetInfo`) down
    to those declared for `target_os`, groups them under the matching
    Dart Target string, and serializes the result to `output_file`.

    When the input list is empty (or no asset matches the current
    target), the manifest is still written but with an empty
    `native-assets` map — keeping the frontend_server invocation
    uniform.

    Args:
      ctx: Rule context. Used only for `ctx.actions.write`.
      output_file: The File to write the manifest into.
      native_assets: Iterable of `FlutterNativeAssetInfo` providers.
      target_os: Target OS string (`macos`, `ios`, `linux`, `windows`,
        `android`). Empty string means "no platform context" — emits
        an empty manifest.
      target_arch: Target architecture string (`arm64`, `x64`, etc.).
        Empty defers to the host arch implicitly via an empty
        manifest map.
    """
    target_string = native_assets_target_string(target_os, target_arch)

    section = {}
    for asset in native_assets:
        if asset.target_os != target_os:
            continue
        section[asset.asset_id] = _path_list_for(asset, target_os)

    # Assets declared for this OS but no resolvable `<os>_<arch>` key means
    # the manifest would silently omit them and every `@Native` binding
    # would fail at runtime, far from the cause. Break loudly instead.
    if section and not target_string:
        fail(
            "flutter_native_assets_manifest: %d native asset(s) are declared " % len(section) +
            "for target_os %r but the target architecture could not be " % target_os +
            "determined (got %r). " % target_arch +
            "The --native-assets manifest would silently omit them and " +
            "@Native bindings would fail at runtime. This is a rules_flutter " +
            "bug in host_target_arch's cpu detection — please report the " +
            "bazel-out cpu segment of this build.",
        )

    manifest = {
        "format-version": [1, 0, 0],
        "native-assets": (
            {target_string: section} if (target_string and section) else {}
        ),
    }

    ctx.actions.write(output_file, json.encode_indent(manifest, indent = "  "))

def collect_bundled_code_asset_files(native_assets, target_os):
    """Return a single depset of files that should be embedded for `target_os`.

    Filters by `target_os` and `link_mode = dynamic_loading_bundle`. The
    remaining link modes contribute manifest entries only — no files to
    bundle.

    Args:
      native_assets: Iterable of `FlutterNativeAssetInfo` providers.
      target_os: Target OS string (`macos`, `ios`, `linux`, `windows`,
        `android`). Only assets matching this OS contribute.

    Returns:
      A `depset[File]` carrying every shared library that needs to be
      placed into the platform application's bundle slot.
    """
    depsets = []
    for asset in native_assets:
        if asset.link_mode != "dynamic_loading_bundle":
            continue
        if asset.target_os != target_os:
            continue
        depsets.append(asset.files)
    return depset(transitive = depsets)

# -- Tier 2 standalone rule ----------------------------------------------------

def _flutter_native_assets_manifest_impl(ctx):
    if FlutterApplicationInfo not in ctx.attr.application:
        fail("flutter_native_assets_manifest: `application` must provide FlutterApplicationInfo.")
    app_info = ctx.attr.application[FlutterApplicationInfo]
    if app_info.native_assets_manifest == None:
        fail(
            "flutter_native_assets_manifest: the application target's " +
            "FlutterApplicationInfo carries no native_assets_manifest. " +
            "This should never happen — flutter_application always emits one.",
        )
    return [DefaultInfo(files = depset([app_info.native_assets_manifest]))]

flutter_native_assets_manifest = rule(
    implementation = _flutter_native_assets_manifest_impl,
    attrs = {
        "application": attr.label(
            doc = "A `flutter_application` target. The manifest produced by " +
                  "the application is re-exposed via this rule's DefaultInfo " +
                  "for callers that want a standalone manifest target.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
    },
    doc = "Re-exposes a flutter_application's `--native-assets` manifest as a standalone target.",
)
