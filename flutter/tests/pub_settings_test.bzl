"""Unit tests for `root_only_settings`: the statements only the root module may make."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:pub_settings.bzl", "root_annotations", "root_only_settings", "unknown_annotation")

def _module(name, is_root = False, settings = [], ignore_hooks = []):
    return struct(
        name = name,
        is_root = is_root,
        tags = struct(
            settings = settings,
            from_lock = [struct(ignore_hooks = ignore_hooks)],
        ),
    )

def _the_root_states_its_settings_and_hooks_test_impl(ctx):
    env = unittest.begin(ctx)

    s = root_only_settings([_module("root", is_root = True), _module("dep")])
    asserts.equals(env, None, s.error)
    asserts.equals(env, "warning", s.check)
    asserts.equals(env, {}, s.ignore_hooks)

    s = root_only_settings([
        _module("root", is_root = True, settings = [struct(check_direct_dependencies = "error")], ignore_hooks = ["objective_c"]),
        _module("dep"),
    ])
    asserts.equals(env, None, s.error)
    asserts.equals(env, "error", s.check)
    asserts.equals(env, {"objective_c": True}, s.ignore_hooks)

    return unittest.end(env)

the_root_states_its_settings_and_hooks_test = unittest.make(_the_root_states_its_settings_and_hooks_test_impl)

def _another_module_may_not_test_impl(ctx):
    env = unittest.begin(ctx)

    s = root_only_settings([_module("root", is_root = True), _module("dep", settings = [struct(check_direct_dependencies = "off")])])
    asserts.true(env, "Module `dep` uses `flutter_pub.settings`" in s.error, s.error)

    # A dependency's ignored hook would silence the root's programs, so it fails.
    s = root_only_settings([_module("root", is_root = True), _module("dep", ignore_hooks = ["objective_c"])])
    asserts.true(env, "Module `dep` ignores the build hooks of `objective_c`" in s.error, s.error)
    asserts.equals(env, {}, s.ignore_hooks)

    tag = struct(check_direct_dependencies = "off")
    s = root_only_settings([_module("root", is_root = True, settings = [tag, tag])])
    asserts.true(env, "uses `flutter_pub.settings` 2 times" in s.error, s.error)

    return unittest.end(env)

another_module_may_not_test = unittest.make(_another_module_may_not_test_impl)

_MAVEN = "@@maven//:"

def _annotating_module(name, is_root, *tags):
    return struct(name = name, is_root = is_root, tags = struct(annotation = list(tags)))

def _tag(package, android_deps = [], build_config_fields = {}):
    return struct(package = package, android_deps = [_MAVEN + d for d in android_deps], build_config_fields = build_config_fields)

def _the_root_annotates_packages_test_impl(ctx):
    env = unittest.begin(ctx)

    a = root_annotations([
        _annotating_module("root", True, _tag("p", ["x", "y"]), _tag("q", build_config_fields = {"LIBRARY_VERSION": '"1.0"'})),
        _annotating_module("dep", False),
    ], _MAVEN)
    asserts.equals(env, None, a.error)
    asserts.equals(env, {"p": {"android_deps": ["@@maven//:x", "@@maven//:y"], "build_config_fields": {}}, "q": {"android_deps": [], "build_config_fields": {"LIBRARY_VERSION": '"1.0"'}}}, a.by_package)

    asserts.equals(env, None, unknown_annotation(a.by_package, ["p", "q"]))
    message = unknown_annotation(a.by_package, ["q"])
    asserts.true(env, '"p"' in message and "no `flutter_pub.from_lock` lock lists" in message, message)

    return unittest.end(env)

the_root_annotates_packages_test = unittest.make(_the_root_annotates_packages_test_impl)

def _annotation_refusals_test_impl(ctx):
    env = unittest.begin(ctx)

    a = root_annotations([_annotating_module("root", True), _annotating_module("dep", False, _tag("p"))], _MAVEN)
    asserts.true(env, "Module `dep` uses `flutter_pub.annotation`" in a.error, a.error)

    a = root_annotations([_annotating_module("root", True, _tag("p"), _tag("p"))], _MAVEN)
    asserts.true(env, "annotates the package `p` more than once" in a.error, a.error)

    a = root_annotations([_annotating_module("root", True, struct(package = "p", android_deps = ["@@other//:x"]))], _MAVEN)
    asserts.true(env, "not an artifact of `@rules_flutter_maven`" in a.error, a.error)

    return unittest.end(env)

annotation_refusals_test = unittest.make(_annotation_refusals_test_impl)

def pub_settings_test_suite(name):
    unittest.suite(
        name,
        the_root_states_its_settings_and_hooks_test,
        another_module_may_not_test,
        the_root_annotates_packages_test,
        annotation_refusals_test,
    )
