"""Unit and analysis tests for swift_packages.bzl and swift_package_product.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:swift_package_product.bzl", "flutter_swift_package_product", "is_visible_label")
load(
    "//flutter/private:swift_packages.bzl",
    "compare_versions",
    "merge_pins",
    "parse_package_resolved",
    "requirement_swift",
    "requirement_text",
    "requirement_violation",
    "swift_package_repo",
    "swift_product_label",
)

_V2 = """{
  "pins" : [
    {
      "identity" : "firebase-ios-sdk",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/firebase/firebase-ios-sdk",
      "state" : {
        "revision" : "dc6dfd442b1f3ec215ed62b8beb2623ffab010d6",
        "version" : "13.1.1"
      }
    },
    {
      "identity" : "promises",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/google/promises.git",
      "state" : {
        "branch" : "main",
        "revision" : "540318ecedd63d883069ae7f1ed811a2df00b6ac"
      }
    }
  ],
  "version" : 2
}"""

def _parse_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = parse_package_resolved(_V2, "Package.resolved")
    asserts.equals(env, ["firebase-ios-sdk", "promises"], [p.identity for p in pins])
    asserts.equals(env, "13.1.1", pins[0].version)
    asserts.equals(env, "", pins[1].version)
    asserts.equals(env, "main", pins[1].branch)
    asserts.equals(env, "540318ecedd63d883069ae7f1ed811a2df00b6ac", pins[1].revision)

    # Version 1, as older Xcode writes it.
    v1 = parse_package_resolved("""{"object": {"pins": [{"package": "Promises",
        "repositoryURL": "https://github.com/google/promises.git",
        "state": {"branch": null, "revision": "abc", "version": "2.4.0"}}]}, "version": 1}""", "old")
    asserts.equals(env, [("promises", "abc", "2.4.0", "")], [(p.identity, p.revision, p.version, p.branch) for p in v1])
    return unittest.end(env)

parse_test = unittest.make(_parse_test_impl)

def _merge_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = parse_package_resolved(_V2, "a")
    merged = merge_pins([("a", pins), ("b", pins[:1])])
    asserts.equals(env, ["firebase-ios-sdk", "promises"], sorted(merged.keys()))
    return unittest.end(env)

merge_test = unittest.make(_merge_test_impl)

def _names_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "swiftpkg_firebase_ios_sdk", swift_package_repo("firebase-ios-sdk"))
    asserts.equals(env, "@swiftpkg_firebase_ios_sdk//:FirebaseCore", swift_product_label("firebase-ios-sdk", "FirebaseCore"))
    return unittest.end(env)

names_test = unittest.make(_names_test_impl)

def _versions_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, 1, compare_versions("13.10.0", "13.9.0"))
    asserts.equals(env, 0, compare_versions("13.1.1", "13.1.1+build"))
    asserts.equals(env, -1, compare_versions("2.0.0-beta.2", "2.0.0"))
    asserts.equals(env, -1, compare_versions("2.0.0-beta.2", "2.0.0-beta.10"))
    asserts.equals(env, -1, compare_versions("2.0.0-alpha", "2.0.0-alpha.1"))
    asserts.equals(env, 1, compare_versions("2.0.0-beta", "2.0.0-alpha.1"))
    return unittest.end(env)

versions_test = unittest.make(_versions_test_impl)

def _pin(version = "", branch = "", revision = "abc"):
    return struct(identity = "p", location = "", version = version, branch = branch, revision = revision)

_EXACT = {"exact": ["13.1.1"]}
_FROM = {"range": [{"lowerBound": "1.2.0", "upperBound": "2.0.0"}]}

def _requirement_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", requirement_violation(_EXACT, _pin("13.1.1")))
    asserts.equals(env, "pins 13.2.0", requirement_violation(_EXACT, _pin("13.2.0")))
    asserts.equals(env, "", requirement_violation(_FROM, _pin("1.9.9")))
    asserts.equals(env, "pins 2.0.0", requirement_violation(_FROM, _pin("2.0.0")))
    asserts.equals(env, "pins 1.2.0-beta", requirement_violation(_FROM, _pin("1.2.0-beta")))

    # A version requirement is not met by a branch or revision pin.
    asserts.equals(env, "pins branch main (abc)", requirement_violation(_EXACT, _pin(branch = "main")))
    asserts.equals(env, "", requirement_violation({"branch": ["main"]}, _pin(branch = "main")))
    asserts.equals(env, "pins 1.0.0", requirement_violation({"revision": ["def"]}, _pin("1.0.0")))
    asserts.equals(env, "", requirement_violation({"revision": ["abc"]}, _pin("1.0.0")))

    asserts.equals(env, "exact 13.1.1", requirement_text(_EXACT))
    asserts.equals(env, "1.2.0 to below 2.0.0", requirement_text(_FROM))
    asserts.equals(env, 'exact: "13.1.1"', requirement_swift(_EXACT))
    asserts.equals(env, 'from: "1.2.0"', requirement_swift(_FROM))
    asserts.equals(env, '.upToNextMinor(from: "1.2.0")', requirement_swift({"range": [{"lowerBound": "1.2.0", "upperBound": "1.3.0"}]}))
    asserts.equals(env, '"1.2.0"..<"1.2.5"', requirement_swift({"range": [{"lowerBound": "1.2.0", "upperBound": "1.2.5"}]}))
    asserts.equals(env, 'branch: "main"', requirement_swift({"branch": ["main"]}))
    return unittest.end(env)

requirement_test = unittest.make(_requirement_test_impl)

def _not_injected_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "package:firebase_core 5.1.0 depends on the Swift package product `FirebaseCore` of `@swiftpkg_not_injected`")
    asserts.expect_failure(env, "the root module does not hand that repository to rules_flutter")
    asserts.expect_failure(env, '    inject_repo(flutter_pub, "swiftpkg_not_injected")\n')
    return analysistest.end(env)

_not_injected_test = analysistest.make(_not_injected_test_impl, expect_failure = True)

def _injected_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, Label("@bazel_skylib//lib:paths"), analysistest.target_under_test(env).label)
    return analysistest.end(env)

_injected_test = analysistest.make(_injected_test_impl)

def _label_rendering_test_impl(ctx):
    env = unittest.begin(ctx)

    # `is_visible_label` reads Bazel's text for a label whose repository no
    # mapping names, which no API promises. A Bazel that renders it otherwise
    # fails here, where the function would take every label for a visible one
    # and a missing `inject_repo` would fail with Bazel's message, not ours.
    asserts.equals(
        env,
        "@@[unknown repo 'swiftpkg_not_injected' requested from @@]//:FirebaseCore",
        ctx.attr.unknown,
        "Bazel renders a label of an unknown repository otherwise; update is_visible_label",
    )
    asserts.false(env, is_visible_label(ctx.attr.unknown))
    asserts.equals(env, "@@bazel_skylib+//lib:paths", ctx.attr.visible)
    asserts.true(env, is_visible_label(ctx.attr.visible))
    return unittest.end(env)

# The labels' text is taken in the loading phase, where
# `native.package_relative_label` converts them as `flutter_swift_package_product`
# does, and handed to the test as strings.
_label_rendering_test = unittest.make(
    _label_rendering_test_impl,
    attrs = {
        "unknown": attr.string(mandatory = True),
        "visible": attr.string(mandatory = True),
    },
)

def swift_packages_test_suite(name):
    """The unit tests, and a product of a repository the root did and did not inject.

    Args:
        name: The test_suite name.
    """

    # This repository's MODULE.bazel sees no `swiftpkg_not_injected`, as a
    # pub extension's repository does not see one the root did not inject.
    flutter_swift_package_product(
        name = "_not_injected_product",
        product = "@swiftpkg_not_injected//:FirebaseCore",
        package = "firebase_core",
        version = "5.1.0",
        tags = ["manual"],
    )
    _not_injected_test(name = name + "_not_injected", target_under_test = ":_not_injected_product")

    # One it sees is the product itself.
    flutter_swift_package_product(
        name = "_injected_product",
        product = "@bazel_skylib//lib:paths",
        package = "firebase_core",
        version = "5.1.0",
        tags = ["manual"],
    )
    _injected_test(name = name + "_injected", target_under_test = ":_injected_product")

    _label_rendering_test(
        name = name + "_label_rendering",
        unknown = str(native.package_relative_label("@swiftpkg_not_injected//:FirebaseCore")),
        visible = str(native.package_relative_label("@bazel_skylib//lib:paths")),
    )

    unittest.suite(name + "_unit", parse_test, merge_test, names_test, versions_test, requirement_test)
    native.test_suite(name = name, tests = [name + "_unit", name + "_not_injected", name + "_injected", name + "_label_rendering"])
