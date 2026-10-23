"""Package-relative keys for Flutter `assets`.

flutter_tools (`lib/src/asset.dart` at the pinned SDK) keys an asset of the
application's own package by its path relative to that package's root, and an
asset of a dependency package `p` by `packages/p/<path relative to p's root>`.
In Bazel the package root is the package directory of the target that lists
the asset: any file under it is keyed by its path relative to that directory,
even when a nested BUILD file makes it another Bazel package. Generated files
follow the same rule by their repository-relative path. Every rule that lists
`assets` keys its files here, exactly once, and
the key travels with the file through `FlutterInfo.assets` to the bundle
action, so no consumer computes a key a second time and every platform bundle
(test trees included) agrees.
"""

load("//flutter:providers.bzl", "FlutterInfo")

def _listing_dir(workspace_root, package):
    """The listing target's package directory in `File.short_path` space.

    `short_path` spells an external repository root `../<repo>` where a label
    spells it `external/<repo>`, so the root is translated before joining.
    """
    root = workspace_root
    if root.startswith("external/"):
        root = ".." + root[len("external"):]
    if package == "":
        return root
    if root == "":
        return package
    return root + "/" + package

def _repo_relative(short_path):
    """The file's repo-root-relative path from its `short_path`.

    Generated files live under `bazel-out/<config>/bin/`; what follows is the
    same repo-relative spelling a source file carries.
    """
    if short_path.startswith("bazel-out/"):
        bin_idx = short_path.find("/bin/")
        if bin_idx != -1:
            short_path = short_path[bin_idx + len("/bin/"):]
    if short_path.startswith("external/"):
        short_path = ".." + short_path[len("external"):]
    return short_path

def is_within_package(workspace_root, package, short_path):
    """Whether the file lives in the listing target's package or below it.

    A target at the workspace root contains every same-repository file, so
    its bundles keep exactly today's keys. Anything else — a sibling package,
    a parent directory, another repository — is outside, and the caller must
    refuse it rather than guess a key.

    Args:
      workspace_root: The listing label's `workspace_root`.
      package: The listing label's `package`.
      short_path: The asset file's `short_path`.

    Returns:
      True when the file may be keyed relative to the package.
    """
    rel = _repo_relative(short_path)
    listing_dir = _listing_dir(workspace_root, package)
    if listing_dir == "":
        return not rel.startswith("../")
    return rel.startswith(listing_dir + "/")

def relative_key(workspace_root, package, short_path):
    """The file's path relative to the listing target's package.

    Callers must check `is_within_package` first and fail on the outside;
    this assumes the file is within and only strips the prefix.

    Args:
      workspace_root: The listing label's `workspace_root`.
      package: The listing label's `package`.
      short_path: The asset file's `short_path`.

    Returns:
      The package-relative key. For a target at the workspace root this is
      the `short_path` itself, so root bundles stay byte-identical.
    """
    rel = _repo_relative(short_path)
    listing_dir = _listing_dir(workspace_root, package)
    if listing_dir == "":
        return rel
    return rel[len(listing_dir) + 1:]

def _checked_relative_key(label, file):
    """The package-relative key for one listed file, or a failure.

    The rule is by directory: the file's repository-relative path (generated
    files shed their `bazel-out/<config>/bin/` prefix first) must sit in the
    listing target's package directory or below it, and the key is the path
    relative to that directory. A nested BUILD file, filegroup or
    `exports_files` changes nothing — those files are still under the
    directory. Only a sibling or parent directory, or another repository, is
    outside and refused. A target at the workspace root strips nothing, so
    root bundles keep exactly today's keys.
    """
    if not is_within_package(label.workspace_root, label.package, file.short_path):
        fail("%s: asset %s is outside the target's package; move it into a flutter_library with a package_name and depend on it instead." % (label, file.short_path))
    return relative_key(label.workspace_root, label.package, file.short_path)

def app_asset_entries(label, files):
    """Key an application, test or bundle target's own `assets`.

    Args:
      label: The listing target's label; its package directory is the key root.
      files: The target's own asset `File`s.

    Returns:
      A list of `struct(key, file, label)` asset entries.
    """
    return [
        struct(key = _checked_relative_key(label, f), file = f, label = str(label))
        for f in files
    ]

def library_asset_entries(label, package_name, files):
    """Key a `flutter_library` or `flutter_plugin` target's own `assets`.

    Args:
      label: The listing target's label; its package directory is the key root.
      package_name: The library's effective Dart package name (the attribute,
        or its documented default). Always non-empty, so the key always takes
        the `packages/<name>/` form.
      files: The target's own asset `File`s.

    Returns:
      A list of `struct(key, file, label)` asset entries.
    """
    return [
        struct(key = "packages/" + package_name + "/" + _checked_relative_key(label, f), file = f, label = str(label))
        for f in files
    ]

def dedupe_asset_entries(label, entries):
    """Drop same-file duplicates, refusing two files that share one key.

    Args:
      label: The bundling target's label, for the message.
      entries: Asset entries in bundle order (own entries first).

    Returns:
      The entries with same-key same-file repeats removed.
    """
    by_key = {}
    ordered = []
    for e in entries:
        seen = by_key.get(e.key)
        if seen == None:
            by_key[e.key] = e
            ordered.append(e.key)
        elif seen.file != e.file:
            fail("%s: two assets share key '%s': %s (from %s) and %s (from %s); give one a different path." % (label, e.key, seen.file.short_path, seen.label, e.file.short_path, e.label))
    return [by_key[k] for k in ordered]

def bundle_asset_entries(label, own_files, deps):
    """Every entry one bundle ships: the target's own plus transitive deps'.

    Args:
      label: The bundling target's label; its package roots its own assets.
      own_files: The target's own asset `File`s.
      deps: The target's `deps`, some providing `FlutterInfo`.

    Returns:
      The deduplicated `struct(key, file, label)` entries for the bundle.
    """
    entries = list(app_asset_entries(label, own_files))
    for dep in deps:
        if FlutterInfo in dep:
            entries.extend(dep[FlutterInfo].assets.to_list())
    return dedupe_asset_entries(label, entries)
