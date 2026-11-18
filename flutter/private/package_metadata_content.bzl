"""The package metadata target a generated BUILD file declares its package with.

rules_dart writes it (`make_package_metadata_content`), so a package
rules_flutter fetches is declared as rules_dart's `pub` declares the same
package: with its source, what it was fetched as, which is what lets a program
reaching both fetchers' copies take them for one package.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "pub_package_identity", _make_package_metadata_content = "make_package_metadata_content")

visibility("//flutter/...")

# The name of the package metadata target a package BUILD file that
# rules_flutter writes declares, and its targets name in `package`. It is the
# name Gazelle gives one, and the one rules_dart's generated packages use.
METADATA_TARGET_NAME = "pubspec-metadata"

def package_metadata_loads(source = None):
    """The loads a generated BUILD file needs for its package metadata.

    Args:
        source: Where the package came from (`package_fetched`), or None.

    Returns:
        The `load` lines `pub_package_identity` gives for the source: the
        declaration's rule, and with a purl, `package_metadata`.
    """
    return pub_package_identity(source).loads

def make_package_metadata_content(
        package_name,
        language_version,
        version = "",
        code_assets = [],
        build_hook = "",
        link_hook = "",
        license_file = "",
        source = None,
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
        source: Where it came from (`pub_hosted_source`, `pub_git_source`,
            `pub_path_source`), whose fetched identity makes it the fetched
            declaration rules_dart's `pub` writes for the same lock entry; or
            None for a package no fetcher states.
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
        source = source,
        visibility = visibility,
    )
