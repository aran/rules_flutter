"""Spoke repository rule for the Flutter framework package (package:flutter).

Downloads the Flutter SDK source from GitHub and generates a flutter_library
target for the framework. Follows the same hub/spoke pattern as rules_dart's
pub_lock_package, so it integrates seamlessly into the same hub repo.

`package:flutter` is the one Flutter SDK package with a rule of its own. The
others (`flutter_test`, `integration_test`, ...) are built from the same source
tarball by `flutter_pub_package`, as a hosted package is built from its archive.
The framework cannot be: its shaders (`lib/src/material/shaders/*.frag`) are
declared in no pubspec (flutter_tools hardcodes them), so they reach the bundle
through `flutter_framework_library.framework_shaders`, not the pub-asset
channel.

Like a pub spoke, this spoke declares the language version the package's own
`environment.sdk` implies, which is what pub writes for it too. Omitting it is
not neutral: `package_config.json` reads a missing `languageVersion` as the
current SDK's.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "find_pub_license_file")
load("@rules_dart//dart/pub:pubspec.bzl", "read_pubspec")
load("//flutter/private:artifact_urls.bzl", "flutter_source_tarball_url")
load("//flutter/private:flutter_pub_index.bzl", "library_label", "read_index")
load("//flutter/private:framework_source.bzl", "dependency_constraint_message", "link_framework_package", "lock_floor_message", "locked_versions", "read_framework", "unusable_message", "write_failing_stub")
load("//flutter/private:package_metadata_content.bzl", "METADATA_TARGET_NAME", "make_package_metadata_content", "package_metadata_loads")
load("//flutter/private:pinned.bzl", "pinned")

visibility("//flutter/...")

_PACKAGE = "flutter"

def make_flutter_framework_build_content(deps, language_version, license_file = ""):
    """Generate BUILD content for the framework spoke.

    The package is a `flutter_framework_library` (not a dart_library) so
    that its shader source files are propagated transitively via FlutterInfo.

    `lib/` is partitioned into `srcs` + `resources`, the same shape
    rules_dart's pub spokes use: everything under lib/ is addressable as
    `package:flutter/<path>` whatever its extension (package:flutter ships
    lib/analysis_options.yaml and lib/fix_data/*.yaml), so the non-Dart
    remainder rides `DartInfo.transitive_resources` rather than being
    dropped. The ink_sparkle .frag appears on both channels by design:
    `framework_shaders` routes it through the impellerc compile into flutter_assets,
    `resources` keeps it a member of the staged package tree.

    Args:
        deps: Fully-qualified Bazel label strings for sibling spokes.
        language_version: Dart language version string (e.g. `"3.11"`), as
            derived from the package's `environment.sdk`.
        license_file: The package's `NOTICES` or `LICENSE` (`find_pub_license_file`), or "".

    Returns:
        BUILD.bazel content as a string.
    """
    deps_block = ""
    if deps:
        dep_lines = ['        "{}",'.format(dep) for dep in deps]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    return package_metadata_loads() + """\
load("@rules_flutter//flutter/private:generated_repos.bzl", "flutter_framework_library")

{metadata}
flutter_framework_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"]),
    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
    framework_shaders = glob(["lib/src/material/shaders/*.frag"]),
{deps}    package = ":{metadata_target}",
    runtime_independent = True,
    visibility = ["//visibility:public"],
)
""".format(
        name = _PACKAGE,
        deps = deps_block,
        metadata = make_package_metadata_content(
            _PACKAGE,
            language_version = language_version,
            license_file = license_file,
        ),
        metadata_target = METADATA_TARGET_NAME,
    )

def _flutter_framework_package_impl(repository_ctx):
    flutter_version = repository_ctx.attr.flutter_version

    if repository_ctx.attr.framework_json:
        unusable = unusable_message(repository_ctx)
        if unusable:
            write_failing_stub(repository_ctx, [_PACKAGE], unusable)
            return

        # A framework source of the root module's choosing: its package.
        flutter_version = read_framework(repository_ctx)["version"]
        missing = link_framework_package(repository_ctx, _PACKAGE)
        if missing:
            write_failing_stub(repository_ctx, [_PACKAGE], missing)
            return
    else:
        _download_framework(repository_ctx, flutter_version)

    # Discover deps and the language version from the pubspec.yaml, read as
    # pub reads it, and filter deps to packages available in the lock
    # file (same pattern as pub_lock_package). A pubspec with no
    # `environment.sdk` gets pub's default language version, which is what pub
    # writes for such a package.
    index = read_index(repository_ctx, repository_ctx.attr.prefix)
    read = read_pubspec(repository_ctx, _PACKAGE, flutter_version, locked_versions = locked_versions(index))
    if read.error:
        write_failing_stub(repository_ctx, [_PACKAGE], read.error)
        return
    pubspec = read.pubspec

    # What the locks were resolved against must fit the SDK this spoke belongs
    # to. A lock that does not leaves the package's target failing, so that
    # only a build of this SDK fails, and every SDK's spokes still fetch
    # (`bazel fetch --all`).
    misfit = (
        lock_floor_message(index, repository_ctx.attr.sdk, flutter_version) or
        dependency_constraint_message(index, repository_ctx.attr.sdk, _PACKAGE, pubspec.unsatisfied)
    )
    if misfit:
        write_failing_stub(repository_ctx, [_PACKAGE], misfit)
        return
    bazel_deps = sorted([d for d in pubspec.dependencies if d in index.built or d in index.other])
    language_version = pubspec.language_version

    # Build dep labels pointing to the libraries of the packages' repos.
    dep_labels = [library_label(index, dep) for dep in bazel_deps]

    repository_ctx.file("BUILD.bazel", make_flutter_framework_build_content(
        deps = dep_labels,
        language_version = language_version,
        license_file = find_pub_license_file(repository_ctx),
    ))

def _download_framework(repository_ctx, flutter_version):
    # Download Flutter SDK source, extracting only the framework package.
    #
    # This same tarball is requested once per SDK package in the lock (by
    # flutter_pub_package), and again by flutter_gen_l10n_repo and
    # flutter_dev_root_repo. Because every one of those fetches is pinned to
    # the same checksum, Bazel's content-addressed repository cache serves
    # them all from a single download; an unpinned fetch could not be
    # deduplicated that way.
    repository_ctx.download_and_extract(
        url = flutter_source_tarball_url(flutter_version),
        sha256 = pinned(flutter_version + ".tar.gz", repository_ctx.attr.sha256),
        stripPrefix = "flutter-{version}/packages/{pkg}".format(
            version = flutter_version,
            pkg = _PACKAGE,
        ),
    )

flutter_framework_package = repository_rule(
    implementation = _flutter_framework_package_impl,
    doc = "Downloads package:flutter from the pinned Flutter source and generates its flutter_library target.",
    attrs = {
        "flutter_version": attr.string(
            doc = "Flutter SDK version tag on GitHub. Unused with `framework_json`.",
        ),
        "sha256": attr.string(
            doc = "Expected SHA-256 of the Flutter SDK source tarball. " +
                  "Guaranteed non-empty by the caller: extensions.bzl reads " +
                  "it through `flutter_source_sha256()`, which refuses a " +
                  "version with no recorded checksum.",
        ),
        "framework_json": attr.label(
            doc = "The `flutter_framework.json` of a framework source, in place of the release tarball.",
            allow_single_file = True,
        ),
        "sdk": attr.string(
            doc = "The SDK whose framework this is, for messages.",
            default = "flutter",
        ),
        "prefix": attr.string(
            doc = "The prefix of the index the package is planned against.",
            default = "flutter_pub",
        ),
    },
)
