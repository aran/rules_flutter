"""Unit and analysis tests for validation.bzl dart-define and Swift module name helpers."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:runner_module.bzl", "runner_module_name")
load("//flutter/private:validation.bzl", "is_valid_dart_define", "is_valid_swift_module_name")

def _accepts_simple_define_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, is_valid_dart_define("FOO=bar"))
    return unittest.end(env)

def _accepts_comma_in_value_test_impl(ctx):
    """Values may contain commas (JSON blobs, lists) — the repeatable flag must not care."""
    env = unittest.begin(ctx)
    asserts.true(env, is_valid_dart_define("FOO=a,b"))
    return unittest.end(env)

def _accepts_equals_in_value_test_impl(ctx):
    """Only the first '=' separates key from value."""
    env = unittest.begin(ctx)
    asserts.true(env, is_valid_dart_define("FOO=a=b"))
    return unittest.end(env)

def _rejects_reserved_namespaces_test_impl(ctx):
    """Reserved namespaces (dart.vm.*, dart.library.*, dart.tool.*, flutter.*) are rejected."""
    env = unittest.begin(ctx)
    asserts.false(env, is_valid_dart_define("dart.vm.other=x"))
    asserts.false(env, is_valid_dart_define("dart.library.io=true"))
    asserts.false(env, is_valid_dart_define("dart.tool.package_config=x"))
    asserts.false(env, is_valid_dart_define("flutter.inspector.structuredErrors=true"))
    asserts.false(env, is_valid_dart_define("=value"))
    return unittest.end(env)

def _rejects_reserved_profile_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, is_valid_dart_define("dart.vm.profile=true"))
    asserts.false(env, is_valid_dart_define("dart.vm.profile=false"))
    return unittest.end(env)

def _rejects_reserved_product_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, is_valid_dart_define("dart.vm.product=true"))
    asserts.false(env, is_valid_dart_define("dart.vm.product=false"))
    return unittest.end(env)

def _rejects_bare_reserved_key_test_impl(ctx):
    """A define without '=' is still a key; reserved keys stay rejected."""
    env = unittest.begin(ctx)
    asserts.false(env, is_valid_dart_define("dart.vm.product"))
    asserts.false(env, is_valid_dart_define("dart.vm.profile"))
    asserts.false(env, is_valid_dart_define("dart.library.html"))
    asserts.false(env, is_valid_dart_define("dart.tool.foo"))
    asserts.false(env, is_valid_dart_define("flutter.bar"))
    return unittest.end(env)

def _rejects_registrant_define_test_impl(ctx):
    """flutter.dart_plugin_registrant is a reserved key.

    The build sets -Dflutter.dart_plugin_registrant itself (engine
    plugin-registrant hook); a user value would break plugin registration.
    """
    env = unittest.begin(ctx)
    asserts.false(env, is_valid_dart_define("flutter.dart_plugin_registrant=file:///x.dart"))
    asserts.false(env, is_valid_dart_define("flutter.dart_plugin_registrant"))
    return unittest.end(env)

def _rejects_empty_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, is_valid_dart_define(""))
    return unittest.end(env)

def _accepts_swift_identifier_test_impl(ctx):
    """Names `flutter create` produces are lower_snake_case identifiers."""
    env = unittest.begin(ctx)
    for name in ["app", "hello_world", "_private", "App2", "a"]:
        asserts.true(env, is_valid_swift_module_name(name), "Expected %r to be valid" % name)
    return unittest.end(env)

def _rejects_non_identifier_test_impl(ctx):
    """Anything Swift cannot spell as a bare module name is rejected loudly.

    Sanitizing instead (my-app -> my_app) would silently reintroduce the
    collision this naming exists to prevent: `my-app` and `my.app` in one
    package would land on the same module.
    """
    env = unittest.begin(ctx)
    for name in ["", "my-app", "my.app", "1app", "my app", "my/app", "my+app"]:
        asserts.false(env, is_valid_swift_module_name(name), "Expected %r to be invalid" % name)
    return unittest.end(env)

def _rejects_swift_keyword_test_impl(ctx):
    """`import class` does not parse, so a target named `class` cannot work."""
    env = unittest.begin(ctx)
    for name in ["class", "import", "func", "self", "Any"]:
        asserts.false(env, is_valid_swift_module_name(name), "Expected %r to be invalid" % name)
    return unittest.end(env)

def _runner_module_is_distinct_test_impl(ctx):
    """The runner module must differ from the app target's own name.

    rules_apple names the linked-storyboard dir `storyboards/<parent>/<module>`
    and falls back to the target name for resources it cannot attribute to a
    module — so an equal module collides with the launch storyboard.
    """
    env = unittest.begin(ctx)
    for name in ["app", "hello_world"]:
        module = runner_module_name("flutter_macos_app", name)
        asserts.false(env, module == name, "Module %r must differ from target %r" % (module, name))
        asserts.true(env, is_valid_swift_module_name(module), "Module %r must stay a valid identifier" % module)
    return unittest.end(env)

def _runner_module_is_injective_test_impl(ctx):
    """Distinct targets must get distinct modules, or the original bug returns."""
    env = unittest.begin(ctx)
    modules = [runner_module_name("flutter_ios_app", n) for n in ["a", "b", "app", "app_b"]]
    asserts.equals(env, len(modules), len({m: None for m in modules}))
    return unittest.end(env)

def _reserved_extra_dart_define_fails_test_impl(ctx):
    """A reserved define in `//flutter:extra_dart_defines` fails analysis with the named error."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Invalid Dart define")
    asserts.expect_failure(env, "extra_dart_defines")
    asserts.expect_failure(env, "reserved defines")
    asserts.expect_failure(env, ctx.attr.expected_define)
    return analysistest.end(env)

def _make_reserved_extra_define_test(define):
    return analysistest.make(
        _reserved_extra_dart_define_fails_test_impl,
        expect_failure = True,
        attrs = {"expected_define": attr.string(default = define)},
        config_settings = {str(Label("//flutter:extra_dart_defines")): [define]},
    )

_reserved_dart_vm_define_fails_test = _make_reserved_extra_define_test("dart.vm.other=1")
_reserved_dart_library_define_fails_test = _make_reserved_extra_define_test("dart.library.io=false")
_reserved_dart_tool_define_fails_test = _make_reserved_extra_define_test("dart.tool.package_config=x")
_reserved_flutter_define_fails_test = _make_reserved_extra_define_test("flutter.custom=1")

_t0_test = unittest.make(_accepts_simple_define_test_impl)
_t1_test = unittest.make(_accepts_comma_in_value_test_impl)
_t2_test = unittest.make(_accepts_equals_in_value_test_impl)
_t3_test = unittest.make(_rejects_reserved_namespaces_test_impl)
_t4_test = unittest.make(_rejects_reserved_profile_test_impl)
_t5_test = unittest.make(_rejects_reserved_product_test_impl)
_t6_test = unittest.make(_rejects_bare_reserved_key_test_impl)
_t7_test = unittest.make(_rejects_empty_test_impl)
_t8_test = unittest.make(_rejects_registrant_define_test_impl)
_t9_test = unittest.make(_accepts_swift_identifier_test_impl)
_t10_test = unittest.make(_rejects_non_identifier_test_impl)
_t11_test = unittest.make(_rejects_swift_keyword_test_impl)
_t12_test = unittest.make(_runner_module_is_distinct_test_impl)
_t13_test = unittest.make(_runner_module_is_injective_test_impl)

def validation_test_suite(name):
    """Defines unit and analysis tests for `validation.bzl` and `extra_dart_defines`.

    Args:
      name: The test_suite target name.
    """
    _reserved_dart_vm_define_fails_test(
        name = name + "_reserved_dart_vm_extra_define_fails",
        target_under_test = "//flutter:extra_dart_defines",
    )
    _reserved_dart_library_define_fails_test(
        name = name + "_reserved_dart_library_extra_define_fails",
        target_under_test = "//flutter:extra_dart_defines",
    )
    _reserved_dart_tool_define_fails_test(
        name = name + "_reserved_dart_tool_extra_define_fails",
        target_under_test = "//flutter:extra_dart_defines",
    )
    _reserved_flutter_define_fails_test(
        name = name + "_reserved_flutter_extra_define_fails",
        target_under_test = "//flutter:extra_dart_defines",
    )
    unittest.suite(
        name + "_unit",
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
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_reserved_dart_vm_extra_define_fails",
            ":" + name + "_reserved_dart_library_extra_define_fails",
            ":" + name + "_reserved_dart_tool_extra_define_fails",
            ":" + name + "_reserved_flutter_extra_define_fails",
        ],
    )
