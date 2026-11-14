"""Repositories for the fixture packages, as `flutter_pub.from_lock` makes them.

Each package is the repositories `flutter_pub.from_lock` makes of a built
package: its source and its library, and the one index over the packages.
`MODULE.bazel` names the library of each, which is what an application depends
on.
"""

# The repository rules `flutter_pub.from_lock` makes a package's repositories
# with, loaded to make our own: there is no public name for them.
# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private:flutter_pub_index.bzl", "INDEX_REPO", "flutter_pub_index", "library_repo", "source_repo")

# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private:flutter_pub_library_repo.bzl", "flutter_pub_library_repo")

# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private:flutter_pub_package.bzl", "flutter_pub_package")

# The packages under `//registry`, with the version of each.
PACKAGES = {
    "fx_dev_only": "1.0.0",
    "fx_dirs": "1.0.0",
    "fx_extra": "1.0.0",
    "fx_flavors": "1.0.0",
    "fx_font_borrower": "1.0.0",
    "fx_font_owner": "1.0.0",
    "fx_licence_dart": "1.0.0",
    "fx_licence_shared": "1.0.0",
    "fx_names": "1.0.0",
    "fx_nolicence": "1.0.0",
    "fx_notices": "1.0.0",
    "fx_platforms": "1.0.0",
    "fx_self_paths": "1.0.0",
    "fx_shader_flavors": "1.0.0",
    "fx_shaders": "1.0.0",
    "fx_variants": "1.0.0",
}

def _pubs_impl(mctx):
    # Resolving a label into the registry fetches it, which is what makes its
    # directory exist to be named in a URL.
    registry = mctx.path(Label("@pub_registry//:registry")).dirname
    checksums = json.decode(mctx.read(Label("@pub_registry//:checksums.json")))
    flutter_pub_index(
        name = INDEX_REPO,
        built = sorted(PACKAGES.keys()),
        other = [],
    )
    for name, version in PACKAGES.items():
        flutter_pub_package(
            name = source_repo(name),
            package_name = name,
            version = version,
            sha256 = checksums[name],
            base_url = "file://" + str(registry),
        )
        flutter_pub_library_repo(
            name = library_repo(name),
            package_name = name,
        )
    return mctx.extension_metadata(reproducible = True)

fixture_pubs = module_extension(
    implementation = _pubs_impl,
)
