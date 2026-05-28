"""Spoke repository rule for Flutter SDK packages (package:flutter).

Downloads the Flutter SDK source from GitHub and generates a dart_library
target for the framework. Follows the same hub/spoke pattern as rules_dart's
pub_lock_package, so it integrates seamlessly into the same hub repo.
"""

_GITHUB_URL_TEMPLATE = "https://github.com/flutter/flutter/archive/refs/tags/{version}.tar.gz"

def _flutter_sdk_package_impl(repository_ctx):
    flutter_version = repository_ctx.attr.flutter_version
    package_name = repository_ctx.attr.package_name

    # Download Flutter SDK source, extracting only the relevant package.
    repository_ctx.download_and_extract(
        url = _GITHUB_URL_TEMPLATE.format(version = flutter_version),
        sha256 = repository_ctx.attr.sha256 if repository_ctx.attr.sha256 else "",
        stripPrefix = "flutter-{version}/packages/{pkg}".format(
            version = flutter_version,
            pkg = package_name,
        ),
    )

    # Discover deps from the downloaded pubspec.yaml, filtering to
    # packages available in the lock file (same pattern as pub_lock_package).
    bazel_deps = []
    pubspec_path = repository_ctx.path("pubspec.yaml")
    if pubspec_path.exists:
        content = repository_ctx.read(pubspec_path)
        all_deps = _parse_pubspec_deps(content)
        available = {p: True for p in repository_ctx.attr.lock_packages}
        bazel_deps = sorted([d for d in all_deps if d in available])

    # Build dep labels pointing to sibling spoke repos.
    dep_labels = ['        "@{hub}__{dep}//:{dep}",'.format(
        hub = repository_ctx.attr.hub_name,
        dep = dep,
    ) for dep in bazel_deps]

    deps_block = ""
    if dep_labels:
        deps_block = "    deps = [\n{deps}\n    ],\n".format(
            deps = "\n".join(dep_labels),
        )

    # The "flutter" package uses flutter_library (not dart_library) so that
    # its shader source files are propagated transitively via FlutterInfo.
    # Other SDK packages (flutter_test, etc.) use plain dart_library.
    if package_name == "flutter":
        build_content = """\
load("@rules_flutter//flutter:defs.bzl", "flutter_library")

flutter_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"]),
    shaders = glob(["lib/src/material/shaders/*.frag"]),
{deps}    package_name = "{name}",
    visibility = ["//visibility:public"],
)
""".format(
            name = package_name,
            deps = deps_block,
        )
    else:
        build_content = """\
load("@rules_dart//dart:defs.bzl", "dart_library")

dart_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"]),
{deps}    package_name = "{name}",
    visibility = ["//visibility:public"],
)
""".format(
            name = package_name,
            deps = deps_block,
        )

    repository_ctx.file("BUILD.bazel", build_content)

    # Emit an empty `android/BUILD.bazel` so the hub's aggregator
    # (`@<hub>//android:all_android_plugin_libs`) can depend on every
    # spoke uniformly, including SDK-provided packages like
    # `package:flutter` and `package:flutter_test`. Loaded lazily — only
    # parsed when something queries `@<spoke>//android:lib`, so non-Android
    # workspaces never pay the `@rules_kotlin` cost.
    repository_ctx.file("android/BUILD.bazel", """\
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

kt_android_library(
    name = "lib",
    srcs = [],
    visibility = ["//visibility:public"],
)
""")

def _parse_pubspec_deps(content):
    """Extract dependency names from a pubspec.yaml file.

    Minimal inline parser — same logic as rules_dart's yaml_parser but
    inlined here because repository rules cannot load .bzl files from
    other repositories.
    """
    deps = []
    in_deps = False
    for line in content.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            in_deps = (stripped == "dependencies:")
        elif in_deps and indent == 2:
            colon_pos = stripped.find(":")
            if colon_pos > 0:
                dep_name = stripped[:colon_pos].strip()
                if dep_name and not dep_name.startswith("#"):
                    deps.append(dep_name)
    return deps

flutter_sdk_package = repository_rule(
    implementation = _flutter_sdk_package_impl,
    doc = "Downloads a Flutter SDK package (e.g. package:flutter) and generates a dart_library target.",
    attrs = {
        "flutter_version": attr.string(
            doc = "Flutter SDK version tag on GitHub.",
            mandatory = True,
        ),
        "package_name": attr.string(
            doc = "The package name within the Flutter SDK (e.g. 'flutter', 'flutter_test').",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "Expected SHA-256 of the Flutter SDK source tarball.",
            default = "",
        ),
        "hub_name": attr.string(
            doc = "Name of the hub repo (for constructing cross-spoke dep labels).",
            mandatory = True,
        ),
        "lock_packages": attr.string_list(
            doc = "All package names in the lock file (for dep filtering).",
            default = [],
        ),
    },
)
