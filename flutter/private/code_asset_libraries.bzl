"""What the build says about each code-asset library an application bundles.

A library in `native_deps` is a target the application names, so the
application reads its `flutter_native_library` wrapper and its sources straight
off that edge. A code asset is not named by the application at all: it rides
`DartPackageInfo.code_assets` up from whichever package owns it — a
`flutter_plugin`, a `flutter_library`, or a plain `dart_library` written by a
rule set that knows nothing of Flutter — and that record holds only the
`DartCodeAssetInfo`, not the target that declared it.

This aspect goes back to the targets. Applied to an application's `deps` and
`code_assets`, it follows every attribute that is not a tool, and the
toolchains a rule lists in rules_dart's `DART_TOOLCHAIN_TYPES_ATTR`, as
rules_dart's own aspects over the Dart graph do: which attribute carries a
package or its code asset is the rule's business, and a forwarding rule may
name it anything. At every target that provides `DartCodeAssetInfo` with a
library, it records what a debug app's `_dev_config.json` says about a
`native_deps` library: the binding contract, when the asset is a
`flutter_native_library`, and the first-party sources below it either way.

Records are keyed by asset id and library `File`, and the application looks up
only the libraries it bundles, so a record for anything else the walk passes —
a tool's library, a copy built in another configuration — is never read. A
bundled library the walk did not reach has no record, and a debug build of the
application fails rather than describe it as a library with no sources: a pub
prebuilt with nothing first-party below it is known not to change between
reloads, and a library nothing describes is not, so the dev tool could not
tell a reload that changed it from one that did not.
"""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo")
load("@rules_dart//dart:utils.bzl", "DART_TOOLCHAIN_TYPES_ATTR")
load("//flutter:providers.bzl", "FlutterNativeLibraryInfo")
load("//flutter/private:native_sources.bzl", "NativeSourcesInfo", "native_sources_aspect")

CodeAssetLibrariesInfo = provider(
    doc = "The code-asset libraries at or below this target, with what their build declares.",
    fields = {
        "records": "depset[struct] or None (none below). Each struct has: asset_id (str), library (File, the library the asset loads), contract (tuple[File], empty when nothing describes the bindings), sources (tuple[File]), hot_patch (File, the wrapper's `*.hot_patch.json`, or None).",
    },
)

def _propagated_attrs(ctx):
    """Every attribute but tools and the toolchain list."""
    return [
        name
        for name in dir(ctx.rule.attr)
        if name != DART_TOOLCHAIN_TYPES_ATTR and not getattr(ctx.rule.attr, name).is_tool
    ]

def _propagated_toolchains(ctx):
    """The toolchain types the rule lists for rules_dart's aspects."""
    types = getattr(ctx.rule.attr, DART_TOOLCHAIN_TYPES_ATTR, None)
    return list(types.value) if types != None else []

def _records_of(dep, found):
    if CodeAssetLibrariesInfo in dep:
        records = dep[CodeAssetLibrariesInfo].records
        if records != None:
            found.append(records)

def _below(ctx, skip):
    """The records of every dependency the aspect reached, but attribute [skip]."""
    found = []
    for name in dir(ctx.rule.attr):
        if name == skip or name == DART_TOOLCHAIN_TYPES_ATTR:
            continue
        value = getattr(ctx.rule.attr, name)
        if type(value) == "Target":
            _records_of(value, found)
        elif type(value) == "list":
            for dep in value:
                if type(dep) == "Target":
                    _records_of(dep, found)
        elif type(value) == "dict":
            for dep in value.keys():
                if type(dep) == "Target":
                    _records_of(dep, found)
    for toolchain_type in getattr(ctx.rule.attr, DART_TOOLCHAIN_TYPES_ATTR, []):
        toolchain = ctx.rule.toolchains[toolchain_type.label]
        if toolchain != None:
            _records_of(toolchain, found)
    return found

def _code_asset_libraries_aspect_impl(target, ctx):
    asset = target[DartCodeAssetInfo] if DartCodeAssetInfo in target else None
    if asset != None and asset.dynamic_library == None:
        asset = None
    wrapper = target[FlutterNativeLibraryInfo] if asset != None and FlutterNativeLibraryInfo in target else None

    # A wrapper describes the asset it wraps, so the bare record its `library`
    # holds for the same library is not a second opinion about it.
    transitive = _below(ctx, skip = "library" if wrapper != None else None)
    if asset == None:
        if not transitive:
            return [CodeAssetLibrariesInfo(records = None)]
        if len(transitive) == 1:
            return [CodeAssetLibrariesInfo(records = transitive[0])]
        return [CodeAssetLibrariesInfo(records = depset(transitive = transitive))]

    contract = ()
    hot_patch = None
    if wrapper != None:
        contract = tuple(wrapper.binding_contract.to_list())
        hot_patch = wrapper.hot_patch.manifest if wrapper.hot_patch else None
    sources = ()
    if NativeSourcesInfo in target:
        sources = tuple(target[NativeSourcesInfo].sources.to_list())
    record = struct(
        asset_id = asset.asset_id,
        library = asset.dynamic_library,
        contract = contract,
        sources = sources,
        hot_patch = hot_patch,
    )
    return [CodeAssetLibrariesInfo(records = depset([record], transitive = transitive))]

code_asset_libraries_aspect = aspect(
    implementation = _code_asset_libraries_aspect_impl,
    attr_aspects = _propagated_attrs,
    toolchains_aspects = _propagated_toolchains,
    requires = [native_sources_aspect],
    doc = "Collects, per code asset below an application's `deps`, the binding contract and sources its build declares.",
)

def code_asset_libraries(deps, code_assets, bundled):
    """The records of the code-asset libraries the target bundles, keyed by asset id.

    An id named in [code_assets] is the target's own choice of library, so its
    records replace whatever [deps] hold under that id, as the asset itself
    does (see `resolve_native_assets`).

    Args:
        deps: Targets the `code_asset_libraries_aspect` was applied to.
        code_assets: The target's own `code_assets`, with the aspect applied.
        bundled: dict[str, File], each asset id the target loads from a code
            asset to the library it resolved to. A record for any other id,
            or for the id with another library, is not read.

    Returns:
        dict[str, struct]: asset id to its record. An id without one has none
        the walk could reach.
    """
    explicit = _by_id(code_assets, {}, bundled)
    return _by_id(deps, explicit, bundled) | explicit

def _record_identity(record):
    """The identity two records share exactly when they describe one library alike."""
    return (record.library, record.contract, record.sources, record.hot_patch)

def _by_id(targets, skip, bundled):
    by_id = {}
    for record in depset(transitive = [
        target[CodeAssetLibrariesInfo].records
        for target in targets
        if CodeAssetLibrariesInfo in target and target[CodeAssetLibrariesInfo].records != None
    ]).to_list():
        if record.asset_id in skip or bundled.get(record.asset_id) != record.library:
            continue

        # One target reached twice is one record. Two that disagree would leave
        # the dev config describing whichever came first.
        seen = by_id.get(record.asset_id)
        if seen != None and _record_identity(seen) != _record_identity(record):
            fail((
                "Two code assets below this application claim the id %r for " +
                "library %s and disagree about it (contract %s, and contract " +
                "%s). An id names one library: wrap it once, or name the one " +
                "to use in this target's `code_assets`."
            ) % (
                record.asset_id,
                record.library.path,
                [f.path for f in seen.contract],
                [f.path for f in record.contract],
            ))
        if seen == None:
            by_id[record.asset_id] = record
    return by_id

def describe_code_asset_libraries(label, assets, records, binding_contracts, native_lib_sources, debug):
    """Puts what each bundled code-asset library's build declares on its bundled path.

    Several ids can share one library, and so one bundled path. The library's
    contract is then every id's contract, and its sources every id's build's.
    One id whose bindings nothing describes leaves the library's calls
    undescribed too, so its contract is empty: the dev tool cannot know that a
    rebuild still serves that id's bindings.

    A library no id has a record for is one the walk could not reach: nothing
    says what it is built from. A debug build fails on it, because the dev
    tool could not tell when it changed; other builds have no dev tool and
    bundle it as usual.

    One library is one image in the running process, so one patch builder
    serves every id it carries: the wrappers naming it may name one `hot_patch`
    between them, or several naming the same one, but not two different ones.

    Args:
        label: The application's label, for error messages.
        assets: The `FlutterNativeAssetInfo` the application staged from code
            assets.
        records: From `code_asset_libraries`.
        binding_contracts: dict[str, list[File]], bundled path to contract
            Files; updated in place.
        native_lib_sources: dict[str, list[File]], bundled path to source
            Files; updated in place.
        debug: bool, whether this is a debug build, which the dev tool runs.
    """
    served_by_path = {}
    files = {}
    for asset in assets:
        if asset.file != None:
            files[asset.file.path] = asset.file
            served_by_path.setdefault(asset.file.path, []).append(
                struct(asset_id = asset.asset_id, record = records.get(asset.asset_id)),
            )
    for path, served in served_by_path.items():
        records_here = [s.record for s in served if s.record != None]
        if not records_here:
            if debug:
                fail((
                    "%s: bundles %s for %s, but no target that provides the " +
                    "code asset is reachable from this target, so a debug " +
                    "build cannot say what the library is built from and hot " +
                    "reload could not tell when it changes. Declare the asset " +
                    "with a target of its own (a `dart_code_asset`, or a " +
                    "`flutter_native_library` wrapping one) and name it in " +
                    "this target's `code_assets`."
                ) % (label, files[path].basename, ", ".join([s.asset_id for s in served])))
            continue
        patches = {}
        for s in served:
            if s.record != None and s.record.hot_patch != None:
                patches.setdefault(s.record.hot_patch, []).append(s.asset_id)
        if len(patches) > 1:
            fail((
                "%s: the asset ids served by %s name %d different `hot_patch` " +
                "targets (%s). They share one library, which a running app " +
                "loads once, so one patch builder must serve them all: name " +
                "the same `hot_patch` on every wrapper of it, or on one."
            ) % (
                label,
                path,
                len(patches),
                "; ".join(["%s for %s" % (m.path, ", ".join(ids)) for m, ids in patches.items()]),
            ))
        if len(records_here) == len(served) and all([r.contract for r in records_here]):
            binding_contracts[path] = _unique_files([f for r in records_here for f in r.contract])
        native_lib_sources[path] = _unique_files([f for r in records_here for f in r.sources])

def _unique_files(files):
    """`files` with repeats dropped, in first-seen order."""
    return list({f: None for f in files}.keys())
