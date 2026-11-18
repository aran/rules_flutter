"""The golden service the integration tests of a build share.

Compares the goldens of an integration test for its host runner, which has no
`dart:ui`: started by the runner, told which test it compares for. It needs only
`package:flutter_test`, of which the build has one copy
(`flutter_pub_lib__flutter_test`), so one service serves every
`flutter_pub.from_lock()` hub that lists `flutter_test`. A hub's `goldens/`
package aliases it.

Made only when some lock lists `flutter_test`. Loaded lazily: it is parsed when
an integration test asks for it.
"""

load("//flutter/private:flutter_pub_index.bzl", "library_repo")
load("//flutter/private:package_metadata_content.bzl", "METADATA_TARGET_NAME")

visibility("//flutter/...")

def _flutter_pub_goldens_impl(ctx):
    ctx.file("BUILD.bazel", """\
load("@rules_dart//dart:defs.bzl", "dart_package_metadata")
load("{flutter_test_bzl}", "flutter_test")

dart_package_metadata(
    name = "{metadata}",
    package_name = "rules_flutter_golden_service",
)

flutter_test(
    name = "service",
    main = "{service}",
    srcs = ["{comparator}"],
    package = ":{metadata}",
    deps = ["@{flutter_test_repo}//:flutter_test"],
    tags = ["manual"],
    testonly = True,
    visibility = ["//visibility:public"],
)
""".format(
        flutter_test_bzl = str(Label("//flutter/private:generated_repos.bzl")),
        service = str(Label("//flutter/private/goldens:service.dart")),
        comparator = str(Label("//flutter/private/goldens:comparator.dart")),
        flutter_test_repo = library_repo("flutter_test"),
        metadata = METADATA_TARGET_NAME,
    ))
    return ctx.repo_metadata(reproducible = True)

flutter_pub_goldens = repository_rule(
    implementation = _flutter_pub_goldens_impl,
    doc = "The golden service the integration tests of a build share, a `flutter_test` over the build's `flutter_test`.",
)
