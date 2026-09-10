"""Unit tests for app_entrypoint.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_main_package_uri",
    "check_foreign_root_package",
    "compute_wrapper_main_import",
    "package_lib_prefix",
    "resolve_wrapper_main_import",
    "synthesize_app_package",
)

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
    """The workspace-rooted app: `lib_root` is `""` and `lib/` is the prefix."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "package:app_flutter/main.dart",
        app_main_package_uri("app_flutter", "", "lib/main.dart"),
    )
    asserts.equals(
        env,
        "package:app_flutter/src/a.dart",
        app_main_package_uri("app_flutter", "", "lib/src/a.dart"),
    )
    return unittest.end(env)

def _app_main_package_uri_nested_test_impl(ctx):
    """An app in a nested Bazel package strips its own root, not the workspace's."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "package:app_flutter/main.dart",
        app_main_package_uri(
            "app_flutter",
            "e2e/macos_example",
            "e2e/macos_example/lib/main.dart",
        ),
    )
    asserts.equals(
        env,
        "package:app_flutter/src/a.dart",
        app_main_package_uri(
            "app_flutter",
            "e2e/macos_example",
            "e2e/macos_example/lib/src/a.dart",
        ),
    )
    return unittest.end(env)

def _app_main_package_uri_answers_only_what_lib_root_backs_test_impl(ctx):
    """A URI is offered only when the app's own record backs it.

    The mapping and the URI come from one prefix, so a nested `main` read
    against a workspace-rooted record yields `None` rather than a URI naming a
    different app's entrypoint.
    """
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        None,
        app_main_package_uri("app_flutter", "", "e2e/macos_example/lib/main.dart"),
    )

    # And the converse: a workspace-root `main` under a nested record.
    asserts.equals(
        env,
        None,
        app_main_package_uri("app_flutter", "e2e/macos_example", "lib/main.dart"),
    )
    return unittest.end(env)

def _app_main_package_uri_none_test_impl(ctx):
    env = unittest.begin(ctx)

    # Not under lib/ → no package mapping to express.
    asserts.equals(env, None, app_main_package_uri("app_flutter", "", "main.dart"))

    # Nor when the package root is nested and `main` sits beside its `lib/`.
    asserts.equals(
        env,
        None,
        app_main_package_uri("app_flutter", "web/boot", "web/boot/main.dart"),
    )

    # No package name → None.
    asserts.equals(env, None, app_main_package_uri("", "", "lib/main.dart"))
    return unittest.end(env)

def _package_lib_prefix_test_impl(ctx):
    """One prefix, shared by the compile path, the dev config and the analyzer split."""
    env = unittest.begin(ctx)
    asserts.equals(env, "lib/", package_lib_prefix(""))
    asserts.equals(env, "custom_boot/lib/", package_lib_prefix("custom_boot"))

    # External repos reach short_path space as `../X`; the prefix follows.
    asserts.equals(env, "../my_repo/pkg/lib/", package_lib_prefix("../my_repo/pkg"))
    return unittest.end(env)

def _resolve_wrapper_main_import_prefers_package_uri_test_impl(ctx):
    """A `package:` URI flows through the colocated `rootUri` to reach codegen siblings."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "package:my_app/main.dart",
        resolve_wrapper_main_import(
            "my_app",
            "my_app",
            "my_app/lib/main.dart",
            "my_app/lib/main.dart",
            4,
        ),
    )
    return unittest.end(env)

def _resolve_wrapper_main_import_falls_back_to_relative_test_impl(ctx):
    """No `package:` mapping → a relative path keeps the wrapper working.

    The fallback is walked in exec-path space while the mapping is decided in
    `short_path` space, which is why the two paths are separate arguments: a
    generated `main` differs between them, and testing the exec path against
    a `short_path` prefix would miss the mapping it does have.
    """
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "../../../main.dart",
        resolve_wrapper_main_import("", "", "main.dart", "main.dart", 3),
    )

    # A generated `main`: the mapping is found in short_path space, so the
    # wrapper still imports by `package:` rather than climbing to bazel-out.
    asserts.equals(
        env,
        "package:my_app/main.dart",
        resolve_wrapper_main_import(
            "my_app",
            "my_app",
            "my_app/lib/main.dart",
            "bazel-out/darwin-fastbuild/bin/my_app/lib/main.dart",
            4,
        ),
    )
    return unittest.end(env)

def _check_foreign_root_package_same_name_ok_test_impl(ctx):
    """A same-name record at the app's root is the ordinary collapse, not an error.

    A `flutter_library` and the `flutter_test` beside it that both name the
    package are two Bazel targets contributing to one Dart package; the
    synthesized record is what they become.
    """
    env = unittest.begin(ctx)
    packages = [
        struct(package_name = "transitive", lib_root = "../pub/transitive", language_version = ""),
        struct(package_name = "my_app", lib_root = "", language_version = ""),
    ]
    asserts.equals(env, None, check_foreign_root_package("//:app", packages, "my_app", ""))
    return unittest.end(env)

def _check_foreign_root_package_reports_foreign_test_impl(ctx):
    """A differently named record at the app's root stops the build.

    Nothing else can supply that package name once the record is dropped, so
    the frontend would report an unresolved `package:` URI at the import and
    say nothing about the target that caused it.
    """
    env = unittest.begin(ctx)
    packages = [
        struct(package_name = "dep_lib", lib_root = "dep_lib", language_version = ""),
    ]
    err = check_foreign_root_package("//dep_lib:probe_test", packages, "dep_lib_probe", "dep_lib")
    asserts.true(env, err != None, "a foreign package at the app's root must be reported")
    asserts.true(env, "//dep_lib:probe_test" in err, "names the target")
    asserts.true(env, "dep_lib" in err, "names the foreign package")
    asserts.true(env, "dep_lib_probe" in err, "names the app's own package")
    return unittest.end(env)

def _check_foreign_root_package_reports_every_offender_test_impl(ctx):
    """Every foreign record is named, not just the first — one fix, one build."""
    env = unittest.begin(ctx)
    packages = [
        struct(package_name = "a_lib", lib_root = "", language_version = ""),
        struct(package_name = "b_lib", lib_root = "", language_version = ""),
        struct(package_name = "elsewhere", lib_root = "../pub/elsewhere", language_version = ""),
    ]
    err = check_foreign_root_package("//:app", packages, "my_app", "")
    asserts.true(env, err != None)
    asserts.true(env, "a_lib" in err and "b_lib" in err, "names both offenders")
    asserts.false(env, "elsewhere" in err, "a package rooted elsewhere is not an offender")
    return unittest.end(env)

def _synthesize_app_package_replaces_collision_test_impl(ctx):
    """A transitive entry at the app's own `lib_root` collides and is dropped."""
    env = unittest.begin(ctx)
    packages = [
        struct(package_name = "transitive", lib_root = "../pub/transitive", language_version = ""),
        struct(package_name = "my_app", lib_root = "", language_version = ""),
    ]
    result = synthesize_app_package("//:app", packages, "my_app", "", "")
    asserts.equals(env, 2, len(result))
    asserts.equals(env, "transitive", result[0].package_name)
    asserts.equals(env, "my_app", result[1].package_name)
    asserts.equals(env, "", result[1].lib_root)
    return unittest.end(env)

def _synthesize_app_package_roots_at_its_own_package_test_impl(ctx):
    """A nested app is registered at its own directory, not the workspace root.

    The record this writes is what every `package:<self>/…` URI resolves
    against, so hardcoding `""` here is what made a nested app's entrypoint
    resolve to the workspace root's `lib/main.dart`. A library that genuinely
    sits at the workspace root is now a different `lib_root` and survives.
    """
    env = unittest.begin(ctx)
    packages = [
        struct(package_name = "root_lib", lib_root = "", language_version = ""),
        struct(package_name = "custom_boot", lib_root = "custom_boot", language_version = ""),
    ]
    result = synthesize_app_package("//custom_boot:app", packages, "custom_boot", "custom_boot", "")
    asserts.equals(env, 2, len(result))

    # The workspace-root library is not the app's root, so it is kept.
    asserts.equals(env, "root_lib", result[0].package_name)
    asserts.equals(env, "", result[0].lib_root)

    # The app is registered at its own package directory.
    asserts.equals(env, "custom_boot", result[1].package_name)
    asserts.equals(env, "custom_boot", result[1].lib_root)
    return unittest.end(env)

_t0_test = unittest.make(_wrapper_import_depth_4_test_impl)
_t1_test = unittest.make(_wrapper_import_depth_3_test_impl)
_t2_test = unittest.make(_app_main_package_uri_lib_main_test_impl)
_t3_test = unittest.make(_app_main_package_uri_nested_test_impl)
_t4_test = unittest.make(_app_main_package_uri_none_test_impl)
_t5_test = unittest.make(_resolve_wrapper_main_import_prefers_package_uri_test_impl)
_t6_test = unittest.make(_resolve_wrapper_main_import_falls_back_to_relative_test_impl)

def _synthesize_app_package_carries_language_version_test_impl(ctx):
    """The app's entry states the version pub would grant it.

    Left unset the entry has none, and `package_config.json` reads a missing
    `languageVersion` as the *current* SDK's — so an app pinned to an older
    pubspec would be compiled under newer semantics than `flutter build` allows.
    """
    env = unittest.begin(ctx)

    stated = synthesize_app_package("//:app", [], "my_app", "", "3.12")
    asserts.equals(env, "3.12", stated[0].language_version)

    # An app that states none passes `""` explicitly and keeps it — nothing
    # here knows its pubspec, and inventing a version would be worse than
    # omitting one. It has to be stated: were this argument defaultable, a
    # caller that simply forgot would land on this same case unnoticed.
    unset = synthesize_app_package("//:app", [], "my_app", "", "")
    asserts.equals(env, "", unset[0].language_version)

    return unittest.end(env)

_t11_test = unittest.make(_synthesize_app_package_carries_language_version_test_impl)
_t12_test = unittest.make(_check_foreign_root_package_same_name_ok_test_impl)
_t13_test = unittest.make(_check_foreign_root_package_reports_foreign_test_impl)
_t14_test = unittest.make(_check_foreign_root_package_reports_every_offender_test_impl)

_t7_test = unittest.make(_synthesize_app_package_replaces_collision_test_impl)
_t8_test = unittest.make(_app_main_package_uri_answers_only_what_lib_root_backs_test_impl)
_t9_test = unittest.make(_package_lib_prefix_test_impl)
_t10_test = unittest.make(_synthesize_app_package_roots_at_its_own_package_test_impl)

def common_test_suite(name):
    unittest.suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
        _t12_test,
        _t13_test,
        _t14_test,
    )
