"""Analysis tests for `web_dir`, the directory served at a web bundle's root."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:web.bzl", "flutter_web_app")
load("//flutter/private:flutter_web_application.bzl", "flutter_web_bundle")
load(":action_content.bzl", "action_config")

def _sources_by_dst(env):
    """The bundle's copy list as {destination: source path}."""
    bundle = action_config(env, "FlutterWebBundle")
    if bundle == None:
        return {}
    return {c["dst"]: c["src"] for c in bundle["copies"]}

def _assert_source(env, copies, dst, src_suffix):
    src = copies.get(dst)
    asserts.true(
        env,
        src != None and src.endswith(src_suffix),
        "%s must come from %s, got %s" % (dst, src_suffix, src),
    )

def _bundle_strips_web_dir_test_impl(ctx):
    """Only the named directory is stripped; `web/` becomes an ordinary path.

    Both fixtures hold a `favicon.png`, so a rule that still stripped `web/`
    too would put two files on one destination rather than pass.
    """
    env = analysistest.begin(ctx)
    copies = _sources_by_dst(env)
    _assert_source(env, copies, "favicon.png", "web_dir/web_apps/second/favicon.png")
    _assert_source(env, copies, "icons/icon-192.png", "web_dir/web_apps/second/icons/icon-192.png")
    _assert_source(env, copies, "web/favicon.png", "web_dir/web/favicon.png")
    return analysistest.end(env)

_bundle_strips_web_dir_test = analysistest.make(_bundle_strips_web_dir_test_impl)

def _app_discovers_from_web_dir_test_impl(ctx):
    """Tier 1 finds the page, manifest and icons in `web_dir`, not `web/`."""
    env = analysistest.begin(ctx)
    copies = _sources_by_dst(env)
    _assert_source(env, copies, "manifest.json", "web_dir/web_apps/second/manifest.json")
    _assert_source(env, copies, "favicon.png", "web_dir/web_apps/second/favicon.png")
    _assert_source(env, copies, "icons/icon-192.png", "web_dir/web_apps/second/icons/icon-192.png")

    # The template files reach the bundle through their attrs, not as assets.
    for dst in ["index.html", "manifest.json"]:
        asserts.false(
            env,
            "web_apps/second/" + dst in copies,
            "%s must not also ship as an asset: %s" % (dst, copies),
        )

    # Nothing from the other app's `web/` comes along.
    asserts.false(
        env,
        [s for s in copies.values() if "web_dir/web/" in s],
        "web/ belongs to another app: %s" % copies,
    )

    template = action_config(env, "FlutterWebTemplate")
    if template != None:
        index = [f for f in template["files"] if f["label"] == "index.html"]
        asserts.equals(env, 1, len(index))
        if index:
            asserts.true(
                env,
                index[0]["template"].endswith("web_dir/web_apps/second/index.html"),
                "index.html must be templated from web_dir: %s" % index[0]["template"],
            )
    return analysistest.end(env)

_app_discovers_from_web_dir_test = analysistest.make(_app_discovers_from_web_dir_test_impl)

def _invalid_web_dir_test_impl(ctx):
    """A trailing slash would strip nothing, so it is refused rather than ignored."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "web_dir must be a directory relative to the package")
    return analysistest.end(env)

_invalid_web_dir_test = analysistest.make(_invalid_web_dir_test_impl, expect_failure = True)

def web_dir_test_suite(name):
    """Fixtures and tests for `web_dir`.

    Instantiated from `flutter/tests/web_dir/BUILD.bazel`, beside the
    directories the fixtures name.

    Args:
        name: Prefix for the generated test targets.
    """
    flutter_web_bundle(
        name = "_bundle",
        package_name = "web_dir",
        main = "main.dart",
        web_dir = "web_apps/second",
        web_assets = [
            "web/favicon.png",
            "web_apps/second/favicon.png",
            "web_apps/second/icons/icon-192.png",
        ],
        tags = ["manual"],
    )
    flutter_web_app(
        name = "_app",
        package_name = "web_dir",
        main = "main.dart",
        deps = [],
        web_dir = "web_apps/second",
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = "_trailing_slash",
        package_name = "web_dir",
        main = "main.dart",
        web_dir = "web_apps/second/",
        tags = ["manual"],
    )

    _bundle_strips_web_dir_test(
        name = name + "_bundle",
        target_under_test = ":_bundle",
    )
    _app_discovers_from_web_dir_test(
        name = name + "_app",
        target_under_test = ":_app",
    )
    _invalid_web_dir_test(
        name = name + "_trailing_slash",
        target_under_test = ":_trailing_slash",
    )
