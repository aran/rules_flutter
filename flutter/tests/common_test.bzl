"""Unit tests for app_entrypoint.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:app_entrypoint.bzl", "app_main_package_uri", "compute_wrapper_main_import", "resolve_wrapper_main_import", "synthesize_app_package")

def _wrapper_import_depth_4_test_impl(ctx):
    """Wrapper at bazel-out/k8-fastbuild/bin/my_app/ (depth=4) to my_app/lib/main.dart."""
    env = unittest.begin(ctx)
    result = compute_wrapper_main_import(4, "my_app/lib/main.dart")
    asserts.equals(env, "../../../../my_app/lib/main.dart", result)
    return unittest.end(env)

def _wrapper_import_depth_3_test_impl(ctx):
    """Wrapper at bazel-out/fastbuild/bin/ (depth=3) to lib/main.dart."""
    env = unittest.begin(ctx)
    result = compute_wrapper_main_import(3, "lib/main.dart")
    asserts.equals(env, "../../../lib/main.dart", result)
    return unittest.end(env)

def _app_main_package_uri_lib_main_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "package:app_flutter/main.dart",
        app_main_package_uri("app_flutter", "lib/main.dart"),
    )
    return unittest.end(env)

def _app_main_package_uri_nested_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "package:app_flutter/src/a.dart",
        app_main_package_uri("app_flutter", "lib/src/a.dart"),
    )

    # A workspace-prefixed path resolves against the package's own lib/.
    asserts.equals(
        env,
        "package:app_flutter/main.dart",
        app_main_package_uri("app_flutter", "e2e/macos_example/lib/main.dart"),
    )
    return unittest.end(env)

def _app_main_package_uri_none_test_impl(ctx):
    env = unittest.begin(ctx)

    # Not under lib/ → no package mapping to express.
    asserts.equals(env, None, app_main_package_uri("app_flutter", "main.dart"))

    # No package name → None.
    asserts.equals(env, None, app_main_package_uri("", "lib/main.dart"))
    return unittest.end(env)

def _resolve_wrapper_main_import_prefers_package_uri_test_impl(ctx):
    """A `package:` URI flows through the colocated `rootUri` to reach codegen siblings."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "package:my_app/main.dart",
        resolve_wrapper_main_import("my_app", "my_app/lib/main.dart", 4),
    )
    return unittest.end(env)

def _resolve_wrapper_main_import_falls_back_to_relative_test_impl(ctx):
    """No `package_name` → no `package:` mapping; relative path keeps the wrapper working."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "../../../main.dart",
        resolve_wrapper_main_import("", "main.dart", 3),
    )
    return unittest.end(env)

def _synthesize_app_package_replaces_collision_test_impl(ctx):
    """A transitive same-name `lib_root==""` collides with the app's rootUri and is dropped."""
    env = unittest.begin(ctx)
    packages = [
        struct(package_name = "transitive", lib_root = "../pub/transitive", language_version = ""),
        struct(package_name = "my_app", lib_root = "", language_version = ""),
    ]
    result = synthesize_app_package(packages, "my_app")
    asserts.equals(env, 2, len(result))
    asserts.equals(env, "transitive", result[0].package_name)
    asserts.equals(env, "my_app", result[1].package_name)
    asserts.equals(env, "", result[1].lib_root)
    return unittest.end(env)

_t0_test = unittest.make(_wrapper_import_depth_4_test_impl)
_t1_test = unittest.make(_wrapper_import_depth_3_test_impl)
_t2_test = unittest.make(_app_main_package_uri_lib_main_test_impl)
_t3_test = unittest.make(_app_main_package_uri_nested_test_impl)
_t4_test = unittest.make(_app_main_package_uri_none_test_impl)
_t5_test = unittest.make(_resolve_wrapper_main_import_prefers_package_uri_test_impl)
_t6_test = unittest.make(_resolve_wrapper_main_import_falls_back_to_relative_test_impl)
_t7_test = unittest.make(_synthesize_app_package_replaces_collision_test_impl)

def common_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test)
