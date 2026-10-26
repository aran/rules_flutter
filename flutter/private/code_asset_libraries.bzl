"""What the build says about each code-asset library an application bundles.

A library in `native_deps` is a target the application names, so the
application reads its `flutter_native_library` wrapper and its sources straight
off that edge. A code asset is not named by the application at all: it rides
`DartPackageInfo.code_assets` up from whichever package owns it — a
`flutter_plugin`, a `flutter_library`, or a plain `dart_library` written by a
rule set that knows nothing of Flutter — and that record holds only the
`DartCodeAssetInfo`, not the target that declared it.

This aspect goes back to the targets. Applied to an application's `deps`, it
walks the Dart package graph's `deps` and `code_assets` edges and, at every
target that provides `DartCodeAssetInfo`, records per asset id what a debug
app's `_dev_config.json` says about a `native_deps` library: the binding
contract, when the asset is a `flutter_native_library`, and the first-party
sources below it either way. The application then puts those on the path it
bundled the library under.

One walk for every owner, rather than each Flutter package rule carrying its own
code assets' records up `FlutterInfo`: a package owns its asset id, so a wrapper
can only go in the owning package's `code_assets`, and the owner of a bridge's
bindings is often a `dart_library`.
"""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo")
load("//flutter:providers.bzl", "FlutterNativeLibraryInfo")
load("//flutter/private:native_sources.bzl", "NativeSourcesInfo", "native_sources_aspect")

CodeAssetLibrariesInfo = provider(
    doc = "The code-asset libraries at or below this target, with what their build declares.",
    fields = {
        "libraries": "depset[struct]: One per code-asset target. Each struct has: asset_id (str), library (File, the library the asset loads, or None), contract (tuple[File], empty when nothing describes the bindings), sources (tuple[File]).",
    },
)

# The edges a code asset reaches an application through: a package's own
# `code_assets`, and the `deps` that make it part of the package graph.
_ATTRS = ["deps", "code_assets"]

def _code_asset_libraries_aspect_impl(target, ctx):
    direct = []
    if DartCodeAssetInfo in target:
        asset = target[DartCodeAssetInfo]
        contract = ()
        if FlutterNativeLibraryInfo in target:
            contract = tuple(target[FlutterNativeLibraryInfo].binding_contract.to_list())
        sources = ()
        if NativeSourcesInfo in target:
            sources = tuple(target[NativeSourcesInfo].sources.to_list())
        direct.append(struct(
            asset_id = asset.asset_id,
            library = asset.dynamic_library,
            contract = contract,
            sources = sources,
        ))

    transitive = []
    for attr in _ATTRS:
        for dep in getattr(ctx.rule.attr, attr, None) or []:
            if type(dep) == "Target" and CodeAssetLibrariesInfo in dep:
                transitive.append(dep[CodeAssetLibrariesInfo].libraries)
    return [CodeAssetLibrariesInfo(libraries = depset(direct, transitive = transitive))]

code_asset_libraries_aspect = aspect(
    implementation = _code_asset_libraries_aspect_impl,
    attr_aspects = _ATTRS,
    requires = [native_sources_aspect],
    doc = "Collects, per code asset below an application's `deps`, the binding contract and sources its build declares.",
)

def code_asset_libraries(deps):
    """The code-asset libraries below [deps], keyed by asset id.

    Args:
        deps: Targets the `code_asset_libraries_aspect` was applied to.

    Returns:
        dict[str, struct]: asset id to the record `CodeAssetLibrariesInfo`
        holds for it.
    """
    by_id = {}
    for record in depset(transitive = [
        dep[CodeAssetLibrariesInfo].libraries
        for dep in deps
        if CodeAssetLibrariesInfo in dep
    ]).to_list():
        # One target reached twice is one record. Two that disagree would leave
        # the dev config describing whichever came first, which may not be the
        # library the application bundled under that id.
        seen = by_id.get(record.asset_id)
        if seen != None and seen != record:
            fail((
                "Two code assets below this application claim the id %r and " +
                "disagree about it (library %s with contract %s, and library " +
                "%s with contract %s). An id names one library."
            ) % (
                record.asset_id,
                seen.library.path if seen.library else None,
                [f.path for f in seen.contract],
                record.library.path if record.library else None,
                [f.path for f in record.contract],
            ))
        by_id[record.asset_id] = record
    return by_id
