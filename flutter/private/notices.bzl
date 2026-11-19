"""The `NOTICES` asset: the licences a program ships, merged as flutter_tools does.

`showLicensePage` and `LicenseRegistry` read one asset, `NOTICES.Z` (gzip) or,
on the web, `NOTICES`. It is made by its own action rather than by the asset
bundle's: its inputs are licence files alone, so an edit to an asset or a new
kernel does not rerun it, and programs with the same packages share its output
through the cache. Merging and compressing the engine's 1.3 MB of licences is
the costly part of bundling.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING", "collect_packages", "package_license_file")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:exec_groups.bzl", "PORTABLE")
load("//flutter/private:path_mapping.bzl", "file_ref", "json_config_args")

visibility("//flutter/...")

# The package the engine's licence file is listed under: flutter_tools reads it
# from `sky_engine`, which every Flutter app depends on.
_ENGINE_PACKAGE = "sky_engine"

# What a rule that calls `flutter_notices_action` declares: the tool, and the
# engine's licences, which every Flutter program ships. The latter is
# `sky_engine`'s `LICENSE`, the file flutter_tools lists them from.
NOTICES_ATTRS = {
    "_notices_tool": attr.label(
        default = Label("//flutter/private/tools:collect_notices.dart"),
        allow_single_file = True,
    ),
    "_engine_license": attr.label(
        default = Label("@flutter_sky_engine//:LICENSE"),
        allow_single_file = True,
    ),
}

def notices_asset_key(web):
    """The key the framework loads the notices from.

    Args:
        web: Whether the bundle is for the web, which reads it uncompressed.

    Returns:
        `NOTICES` for the web, `NOTICES.Z` otherwise.
    """
    return "NOTICES" if web else "NOTICES.Z"

def package_licenses_of(deps, own = []):
    """The licence file of each package in the closure of `deps`, by package name.

    The closure is the program's own, not the lock's: a package only a
    dependency of something else (a dev dependency of the project, say) is not
    shipped and is not listed. The records come from `collect_packages`, which
    keeps for one package the record that names a licence, and fails when two
    name different ones.

    Args:
        deps: Targets; those with `DartInfo` contribute.
        own: `(package name, File)` of the program itself, if it has a licence.

    Returns:
        A list of `(package name, File)` sorted by name, then the program's own.
    """
    records = collect_packages([dep for dep in deps if DartInfo in dep])
    listed = {}
    for record in records:
        f = package_license_file(record)
        if f:
            listed[record.package_name] = f

    # The program's own package is listed once, as its own: a library of it
    # in `deps` names the same declaration, and so the same licence.
    for name, _ in own:
        listed.pop(name, None)
    return [(name, listed[name]) for name in sorted(listed)] + own

def additional_licenses_of(deps, own = []):
    """The `flutter: licenses:` files of the packages `deps` reach, in the order they are appended.

    flutter_tools appends them in the order its walk of the package graph meets
    the packages, which a build cannot recover: it depends on the order of
    each pubspec's dependencies. They are ordered by package name instead,
    each package's files as it lists them, and the program's own last.

    Args:
        deps: Targets; those with `FlutterInfo` contribute.
        own: `(package name, [File])` of the program itself, if it lists any.

    Returns:
        A list of `(package name, [File])`, for `flutter_notices_action`.
    """
    listed = depset(transitive = [dep[FlutterInfo].additional_licenses for dep in deps if FlutterInfo in dep]).to_list()
    return [(entry.package_name, list(entry.files)) for entry in sorted(listed, key = lambda entry: entry.package_name)] + own

def flutter_notices_action(ctx, tools, packages, additional, engine_license, web):
    """Merge licence files into the program's `NOTICES` asset.

    Args:
        ctx: Rule context, with `_notices_tool`. Its label names the output.
        tools: `FlutterExecToolsInfo` of the `PORTABLE` group (`portable_tools`).
        packages: list of `(package name, File)`: each package's licence file.
            The same package twice is one, when the files are alike.
        additional: list of `(package name, [File])`: the files a package's
            `flutter: licenses:` lists. They are appended in this order, so
            the caller fixes it.
        engine_license: The File holding the engine's licences.
        web: Whether the bundle is for the web.

    Returns:
        The declared output File, to bundle under `notices_asset_key(web)`.
    """
    tool = ctx.file._notices_tool
    out = ctx.actions.declare_file("%s_%s" % (ctx.label.name, notices_asset_key(web)))

    refs = []
    config = {
        "packages": [{"name": name, "file": file_ref(refs, f)} for name, f in packages],
        "engine": {"name": _ENGINE_PACKAGE, "file": file_ref(refs, engine_license)},
        "additional": [
            {"name": name, "files": [file_ref(refs, f) for f in files]}
            for name, files in additional
        ],
        "web": web,
    }

    args = ctx.actions.args()
    args.add(tool)
    args.add("--output", out)
    args.add("--config")

    ctx.actions.run(
        executable = tools.dart,
        arguments = [args, json_config_args(ctx, config, refs)],
        inputs = depset(
            direct = [tool, engine_license] + [f for _, f in packages] + [f for _, files in additional for f in files],
            transitive = [tools.sdk_files.run],
        ),
        outputs = [out],
        mnemonic = "FlutterNotices",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Collecting licences %s" % ctx.label,
    )
    return out
