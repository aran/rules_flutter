"""The package metadata target a generated BUILD file declares its package with.

rules_dart writes it (`make_package_metadata_content`), so a package
rules_flutter fetches is declared as rules_dart's `pub` declares the same
package: with what it was fetched as, its fetched identity, which is what lets
a program reaching both fetchers' copies take them for one package.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "pub_package_identity", _make_package_metadata_content = "make_package_metadata_content")

# The name of the package metadata target a package BUILD file that
# rules_flutter writes declares, and its targets name in `package`. It is the
# name Gazelle gives one, and the one rules_dart's generated packages use.
METADATA_TARGET_NAME = "pubspec-metadata"

# What a generated BUILD file of a package with no fetched identity loads the
# rule from.
PACKAGE_METADATA_LOAD = 'load("@rules_dart//dart:defs.bzl", "dart_package_metadata")\n'

def package_metadata_loads(fetched_identity = "", purl = ""):
    """The loads a generated BUILD file needs for its package metadata.

    Args:
        fetched_identity: What the package was fetched as, or "" (see
            `make_package_metadata_content`).
        purl: The package's purl when `fetched_identity` is not one
            (`package_fetched`), or "".

    Returns:
        The `load` lines: with a fetched identity, those
        `pub_package_identity` gives for it.
    """
    return pub_package_identity(fetched_identity, purl).loads if fetched_identity or purl else PACKAGE_METADATA_LOAD

def make_package_metadata_content(
        package_name,
        language_version,
        version = "",
        code_assets = [],
        build_hook = "",
        link_hook = "",
        license_file = "",
        fetched_identity = "",
        visibility = "//visibility:public"):
    """The package metadata target stating a generated package's facts.

    Args:
        package_name: The package's name.
        language_version: Its Dart language version, or "".
        version: Its version, or "".
        code_assets: The `dart_code_asset` labels it carries.
        build_hook: Its `hook/build.dart`, package-relative, or "".
        link_hook: Its `hook/link.dart`, package-relative, or "".
        license_file: Its `NOTICES` or `LICENSE`, package-relative, or "".
        fetched_identity: What it was fetched as (`pub_hosted_purl`,
            `pub_git_identity`, `pub_path_identity`), which makes it rules_dart's
            `fetched_package_metadata`; or "" for a package no fetcher states.
        visibility: The target's visibility.

    Returns:
        BUILD content: the target, without its loads
        (`package_metadata_loads`).
    """
    return _make_package_metadata_content(
        package_name,
        language_version,
        version = version,
        code_assets = code_assets,
        build_hook = build_hook,
        link_hook = link_hook,
        license_file = license_file,
        fetched_identity = fetched_identity,
        visibility = visibility,
    )
