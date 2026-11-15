"""The web SDK slice of an engine checkout's out dirs.

`flutter_local_engine` (local_sdk.bzl) reads the checkout; this module
links the web SDK of its `wasm_release` out dir (`flutter_web_sdk/`, the
`--web` build of `tools/gn`, where flutter_tools'
`CachedLocalWebSdkArtifacts` reads it) and writes the `web` package
(the labels of `engine_labels.bzl`):

* `web:sdk`: the `flutter_web_sdk` slice, with the platform kernels the web
  compilers read and whether the out dir holds the renderers (`canvaskit/`).
* the files a web application names (`engine_labels.WEB_SLICE_FILES`), as
  aliases into the linked tree.

The web SDK's `libraries.json` includes `../dart-sdk/lib/libraries.json`, so the
Dart SDK of the host tools is linked beside it, as the release's web SDK
repository does. The compilers that read the platform kernels are that Dart
SDK's, which is why the pieces are checked against it (`sdk_check.dart`).
"""

load("//flutter/private:engine_out_dirs.bzl", "dict_text", "link_into", "out_dir_provenance", "select_out_dir")

# The files of the web SDK tree a web application names, by their target in
# the `web` package, and where each is in the repository (the linked
# `flutter_web_sdk` directory is `web-sdk/`, the Dart SDK `dart-sdk/`).
WEB_TREE_FILES = {
    "dart2wasm_platform.dill": "web-sdk/kernel/dart2wasm_platform.dill",
    "dart2js_platform.dill": "web-sdk/kernel/dart2js_platform.dill",
    "ddc_outline.dill": "web-sdk/kernel/ddc_outline.dill",
    "libraries.json": "web-sdk/libraries.json",
    "ddc_dart_sdk.js": "web-sdk/kernel/ddc/canary/dart_sdk.js",
    "ddc_module_loader.js": "dart-sdk/lib/dev_compiler/ddc/ddc_module_loader.js",
    "dart_stack_trace_mapper.js": "dart-sdk/lib/dev_compiler/web/dart_stack_trace_mapper.js",
}

# What the out dir's `flutter_web_sdk` must hold, relative to it.
_REQUIRED = [
    "libraries.json",
    "kernel/dart2js_platform.dill",
    "kernel/dart2wasm_platform.dill",
    "kernel/ddc_outline.dill",
    "kernel/ddc/canary/dart_sdk.js",
    "flutter_js/flutter.js",
    "flutter_js/flutter.js.map",
]

# The BUILD text of the root package, which the `web` package's slices name.
WEB_ROOT_BUILD = """
filegroup(
    name = "web_sdk_files",
    srcs = glob(["web-sdk/**", "dart-sdk/lib/**"]),
    visibility = ["//visibility:public"],
)
"""

def web_slices(repository_ctx, out_root, candidates, args_of, pins, found, dart_sdk_linked):
    """The web slices the out dirs provide, and why they are missing.

    Args:
        repository_ctx: The adapter's repository context; the tree is linked into it.
        out_root: The `engine/src/out` path.
        candidates: The out dirs found, as `struct(name, os, mode, sim, unopt, cpu)`.
        args_of: Each out dir's `args.gn`, by directory name.
        pins: Out dir names the user chose, or empty.
        found: A description of the out dirs found, for messages.
        dart_sdk_linked: Whether the Dart SDK of the host tools is linked at `dart-sdk`.

    Returns:
        `struct(provided, reasons, root_build)`: BUILD text by `(package, target)` of
        the slices that exist, why the others do not, and the BUILD text the
        root package needs.
    """
    result = struct(provided = {}, reasons = {}, root_build = "")

    def missing(why):
        result.reasons[("web", "sdk")] = why
        for target in WEB_TREE_FILES:
            result.reasons[("web", target)] = why
        result.reasons[("web", "files")] = why
        return result

    pick = select_out_dir(candidates, ["wasm"], "release", "wasm", pins)
    if not pick.name:
        return missing((
            "The engine out dirs under {out} have no web SDK: {error}. Found: {found}. " +
            "Build one in the checkout (engine/src/flutter/tools/gn --web --runtime-mode release, then " +
            "ninja -C out/wasm_release flutter/web_sdk), or build for another platform."
        ).format(out = out_root, error = pick.error, found = found))
    if not dart_sdk_linked:
        return missing((
            "The web SDK of {name} needs the Dart SDK of the host tools, which the host debug out dir " +
            "should provide, and it is missing (see the host tools slice)."
        ).format(name = pick.name))
    tree = out_root.get_child(pick.name).get_child("flutter_web_sdk")
    absent = [n for n in _REQUIRED if not tree.get_child(n).exists] if tree.exists else ["flutter_web_sdk"]
    if absent:
        return missing((
            "The out dir {out} lacks {absent} in its flutter_web_sdk: build the web SDK (ninja -C out/{name} flutter/web_sdk)."
        ).format(out = out_root.get_child(pick.name), absent = ", ".join(absent), name = pick.name))

    link_into(repository_ctx, tree, "web-sdk")
    has_canvaskit = tree.get_child("canvaskit").get_child("canvaskit.wasm").exists
    provenance = dict_text(out_dir_provenance(pick.name, args_of[pick.name]))
    result.provided[("web", "files")] = """
alias(
    name = "files",
    actual = "//:web_sdk_files",
    visibility = ["//visibility:public"],
)
"""
    for target, path in WEB_TREE_FILES.items():
        result.provided[("web", target)] = """
alias(
    name = "{target}",
    actual = "//:{path}",
    visibility = ["//visibility:public"],
)
""".format(target = target, path = path)
    result.provided[("web", "sdk")] = """
flutter_web_sdk(
    name = "sdk",
    files = ":files",
    dart2js_platform_dill = ":dart2js_platform.dill",
    dart2wasm_platform_dill = ":dart2wasm_platform.dill",
    ddc_outline_dill = ":ddc_outline.dill",
    has_canvaskit = {has_canvaskit},
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(has_canvaskit = "True" if has_canvaskit else "False", provenance = provenance)
    return struct(provided = result.provided, reasons = result.reasons, root_build = WEB_ROOT_BUILD)
