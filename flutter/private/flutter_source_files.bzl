"""The repositories holding the Flutter SDK packages' files, and nothing generated.

A Flutter SDK package other than `package:flutter` (`flutter_test`,
`integration_test`, ...) is `packages/<name>` of the pinned Flutter source. Its
source repository (`flutter_pub_package`) generates its build from
rules_flutter's and rules_dart's Starlark, so the cache key Bazel stores that
repository under changes with every edit to that Starlark. Were the package's
files stored in it, Bazel's repository contents cache would keep another copy
of them for each. So they are kept in repositories of their own, defined here
with only the fetching code loaded, which the source repository links in with
rules_dart's `link_pub_files`, as it does a hosted or git package's
(`pub_archive_files`, `pub_git_files`).

The source tarball holds the whole monorepo, engine included, so an extraction
from it reads all of it, however little it keeps. `flutter_source_packages`
extracts all of `packages/` once per release, and each package's
`flutter_source_files` links its directory from there, so a build that uses
several SDK packages reads the tarball once rather than once for each.

Keep this file's loads to the fetching code: each `.bzl` it loads is part of
the key of every release's packages.
"""

load("@rules_dart//dart/pub:pub_files_root.bzl", "write_pub_files_root")
load("//flutter/private:artifact_urls.bzl", "flutter_source_tarball_url")
load("//flutter/private:pinned.bzl", "pinned")

visibility("//flutter/...")

def missing_sdk_package_message(name, version):
    """What a build of a Flutter release says of a lock's SDK package the release does not have."""
    return (
        "pubspec.lock lists `{name}` from the Flutter SDK, but Flutter {version}'s " +
        "source has no packages/{name}; re-resolve the lock with the pinned " +
        "toolchain (`bazel run @rules_flutter//flutter/pub -- get`)."
    ).format(name = name, version = version)

def flutter_sdk_files_identity(flutter_version, sha256):
    """What a `flutter_source_files` repository holds, for its source repository's `files_identity`.

    Args:
        flutter_version: Its `flutter_version`.
        sha256: The `sha256` of its release's `flutter_source_packages`.

    Returns:
        The identity: the Flutter release and the digest of its source.
    """
    return "flutter {} sha256:{}".format(flutter_version, sha256)

# The file at the root of a release's `flutter_source_packages`, and of each of
# its `flutter_source_files`, whose load makes Bazel set that repository up.
# Links into it name it in the output base that builds, so a repository whose
# files link there must load this before they are read through: a vendored
# repository is never fetched again, so nothing else would set it up.
SOURCE_LOAD = "flutter_source.bzl"

def flutter_source_load(repo_file):
    """The load that makes Bazel set up a release's `flutter_source_packages` before links into it are read.

    Args:
        repo_file: The label of a file at the root of the release's
            `flutter_source_packages`, or of one of its `flutter_source_files`.

    Returns:
        The load statement, for the start of a BUILD file.
    """
    return 'load("{}", "FLUTTER_SOURCE")\n'.format(repo_file.same_package_label(SOURCE_LOAD))

def _flutter_source_packages_impl(rctx):
    # The tarball is the one every consumer of the framework source fetches,
    # pinned to the same digest, so Bazel's repository cache serves it to all
    # of them from one download. Only `packages/` is extracted, to the root.
    version = rctx.attr.flutter_version
    rctx.download_and_extract(
        url = flutter_source_tarball_url(version),
        sha256 = pinned(version + ".tar.gz", rctx.attr.sha256),
        stripPrefix = "flutter-{}/packages".format(version),
    )
    rctx.file("BUILD.bazel", "")
    rctx.file(SOURCE_LOAD, "FLUTTER_SOURCE = {}\n".format(json.encode(version)))
    return rctx.repo_metadata(reproducible = True)

flutter_source_packages = repository_rule(
    implementation = _flutter_source_packages_impl,
    attrs = {
        "flutter_version": attr.string(
            doc = "The Flutter version whose pinned source tarball holds the packages.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "The recorded digest of that tarball (`flutter_source_sha256`).",
            mandatory = True,
        ),
    },
    doc = "Extracts `packages/` of the pinned Flutter source, for each `flutter_source_files` of the release to link from.",
)

# Bazel's own root names, which would make the root another package or
# repository: a package's entry of one of these names is not linked in, as
# rules_dart's `link_pub_files` links none. framework_source.bzl's
# `NEVER_LINKED` is the same list; loading it here would make its loads part of
# the key of `flutter_source_packages`.
_NOT_LINKED = ["BUILD", "BUILD.bazel", "MODULE.bazel", "REPO.bazel", "WORKSPACE", "WORKSPACE.bazel", "WORKSPACE.bzlmod"]

def _flutter_source_files_impl(rctx):
    # A package the source lacks has no directory to link, and nothing would
    # say why, so the package is first looked up in `packages`, the release's
    # own list of them.
    name = rctx.attr.package_name
    version = rctx.attr.flutter_version
    if not rctx.attr.packages:
        fail((
            "flutter_source_files `{name}` has `flutter_version` {version} " +
            "but no `packages`, so it cannot tell whether the source has packages/{name}."
        ).format(name = name, version = version))
    if name not in rctx.attr.packages:
        # The pub extension declares no files repository for a package its
        # SDK does not have, so that only a build of that SDK fails.
        fail(missing_sdk_package_message(name, version))

    # Unwatched: the release's packages change only with their repository's
    # attributes, and `rctx.path(source)` already makes this repository depend
    # on that repository.
    package_dir = rctx.path(rctx.attr.source).dirname.get_child(name)
    for child in package_dir.readdir(watch = "no"):
        if child.basename not in _NOT_LINKED:
            rctx.symlink(child, child.basename)

    # The root's marker and the file whose load `link_pub_files` returns, so
    # Bazel sets this repository up before the links are read through, as in
    # a vendored build; and the file whose load sets up the repository these
    # links name in turn.
    write_pub_files_root(rctx)
    rctx.file(SOURCE_LOAD, 'load("{}", _FLUTTER_SOURCE = "FLUTTER_SOURCE")\n\nFLUTTER_SOURCE = _FLUTTER_SOURCE\n'.format(
        rctx.attr.source.same_package_label(SOURCE_LOAD),
    ))

    # Never reproducible: the files are links into this output base's
    # `flutter_source_packages`, which a cached copy would not link into.
    return rctx.repo_metadata(reproducible = False)

flutter_source_files = repository_rule(
    implementation = _flutter_source_files_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The package under `packages/` of the Flutter source.",
            mandatory = True,
        ),
        "flutter_version": attr.string(
            doc = "The Flutter version whose source holds the package, for messages.",
            mandatory = True,
        ),
        "source": attr.label(
            doc = "The `BUILD.bazel` of the release's `flutter_source_packages`.",
            allow_single_file = True,
            mandatory = True,
        ),
        "packages": attr.string_list(
            doc = "The packages under `packages/` of that source (`flutter_sdk_packages`). A `package_name` " +
                  "not among them fails the fetch, before anything is linked, saying to re-resolve the lock.",
            mandatory = True,
        ),
    },
    doc = "Links `packages/<package_name>` of the pinned Flutter source, for `flutter_pub_package` to link in.",
)
