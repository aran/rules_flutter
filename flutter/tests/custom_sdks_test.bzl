"""Tests for which SDKs the root module's custom-SDK tags declare."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:custom_sdks.bzl", "CUSTOM_SDK_TAGS", "checkout_repo_names", "custom_sdks")
load("//flutter/private:toolchains_repo.bzl", "machine_hosts", "toolchains_build_content")

def _module(name, is_root, use_sdk = [], **tags):
    """A module whose tags are, for each kind given, the names it declares, and the names `use_sdk` gives."""
    kinds = {
        kind: [struct(name = n) for n in tags.get(kind, [])]
        for kind in CUSTOM_SDK_TAGS
    }
    return struct(name = name, is_root = is_root, tags = struct(
        use_sdk = [struct(name = n) for n in use_sdk],
        **kinds
    ))

def _sdks(*modules):
    return custom_sdks(list(modules), ["flutter"], "flutter")

def _root_declares_each_form_test_impl(ctx):
    env = unittest.begin(ctx)
    result = _sdks(
        _module("app", True, checkout = ["local"], custom_sdk = ["fork"], custom_engine = ["patched"], custom_framework = ["ours"]),
        _module("lib", False),
    )
    asserts.equals(env, None, result.error)
    asserts.equals(env, ["fork", "local", "ours", "patched"], sorted(result.sdks.keys()))
    asserts.equals(env, "custom_engine", result.sdks["patched"].kind)
    asserts.equals(env, "local", result.sdks["local"].tag.name)
    return unittest.end(env)

def _dependency_may_not_declare_test_impl(ctx):
    env = unittest.begin(ctx)
    result = _sdks(_module("app", True), _module("lib", False, custom_engine = ["patched"]))
    asserts.equals(env, {}, result.sdks)
    asserts.true(env, "flutter.custom_engine(name = \"patched\") in module lib" in result.error, result.error)
    asserts.true(env, "Only the root module may" in result.error, result.error)
    return unittest.end(env)

def _default_name_is_the_release_test_impl(ctx):
    env = unittest.begin(ctx)
    result = _sdks(_module("app", True, custom_sdk = ["flutter"]))
    asserts.true(env, "flutter.custom_sdk(name = \"flutter\") takes the name of the release" in result.error, result.error)
    asserts.true(env, "flutter.use_sdk(name = ...)" in result.error, result.error)
    return unittest.end(env)

def _name_declared_twice_test_impl(ctx):
    env = unittest.begin(ctx)
    result = _sdks(_module("app", True, checkout = ["local"], custom_sdk = ["local"]))
    asserts.equals(env, "\"local\" is declared twice: by flutter.custom_sdk() and by flutter.checkout().", result.error)
    return unittest.end(env)

def _name_of_a_release_test_impl(ctx):
    env = unittest.begin(ctx)
    result = custom_sdks([_module("app", True, checkout = ["beta"])], ["flutter", "beta"], "flutter")
    asserts.true(env, "both flutter.checkout(name = \"beta\") and flutter.toolchain(name = \"beta\")" in result.error, result.error)
    return unittest.end(env)

def _repositories_are_the_checkouts_own_test_impl(ctx):
    env = unittest.begin(ctx)
    repos = checkout_repo_names("local")
    asserts.equals(env, "local_checkout_framework", repos.framework)
    asserts.equals(env, "local_checkout_engine", repos.engine)
    return unittest.end(env)

def _refused(env, result, *fragments):
    asserts.true(env, result.error != None, "expected a refusal")
    for fragment in fragments:
        asserts.true(env, fragment in result.error, "expected {} in:\n{}".format(repr(fragment), result.error))

def _without_use_sdk_the_release_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, _sdks(_module("app", True, checkout = ["local"])).use)
    return unittest.end(env)

def _use_sdk_chooses_a_declared_sdk_test_impl(ctx):
    env = unittest.begin(ctx)
    result = _sdks(_module("app", True, checkout = ["local"], use_sdk = ["local"]))
    asserts.equals(env, None, result.error)
    asserts.equals(env, "local", result.use)
    asserts.equals(env, "flutter", _sdks(_module("app", True, use_sdk = ["flutter"])).use)
    return unittest.end(env)

def _use_sdk_of_an_undeclared_name_test_impl(ctx):
    env = unittest.begin(ctx)
    _refused(
        env,
        _sdks(_module("app", True, checkout = ["local"], use_sdk = ["nope"])),
        'flutter.use_sdk(name = "nope") names no declared Flutter SDK',
        "The declared SDKs are: flutter, local.",
    )
    return unittest.end(env)

def _use_sdk_outside_the_root_test_impl(ctx):
    env = unittest.begin(ctx)
    _refused(
        env,
        _sdks(_module("app", True, checkout = ["local"]), _module("lib", False, use_sdk = ["flutter"])),
        'flutter.use_sdk(name = "flutter") in module lib',
        "Only the root module may",
    )
    return unittest.end(env)

def _use_sdk_twice_test_impl(ctx):
    env = unittest.begin(ctx)
    _refused(env, _sdks(_module("app", True, checkout = ["local"], use_sdk = ["local", "flutter"])), "two Flutter SDKs")
    return unittest.end(env)

def _setting(build, sdk):
    """The targets that make `sdk_<sdk>`: from its first `config_setting` to the toolchains after it."""
    named = build.index('name = "sdk_{}"'.format(sdk))
    start = build.rfind("config_setting(", 0, named)
    return build[start:build.index("toolchain(", named)]

def _settings_follow_the_choice_test_impl(ctx):
    env = unittest.begin(ctx)
    build = toolchains_build_content(["flutter", "local", "other"], "local")

    # Unset, the flag means the root module's choice, and only that SDK.
    asserts.true(env, '"@rules_flutter//flutter:sdk": ""' in build, build)
    chosen = _setting(build, "local")
    asserts.true(env, '"@rules_flutter//flutter:sdk": "local"' in chosen, chosen)
    asserts.true(env, "selects.config_setting_group(" in chosen, chosen)
    asserts.true(env, '":flag_unset"' in chosen, chosen)
    for sdk in ["flutter", "other"]:
        setting = _setting(build, sdk)
        asserts.true(env, '"@rules_flutter//flutter:sdk": "{}"'.format(sdk) in setting, setting)
        asserts.false(env, "flag_unset" in setting, setting)

    # A name no tag declares resolves the toolchain that fails listing those
    # that are; unset or naming one, it resolves no such toolchain.
    undeclared = build[build.index('name = "uses_undeclared_sdk"'):build.index('name = "undeclared_sdk"')]
    for setting in ["flag_unset", "flag_is_flutter", "flag_is_local", "flag_is_other"]:
        asserts.true(env, '":{}": "@rules_flutter//flutter/private:never"'.format(setting) in undeclared, undeclared)
    asserts.true(env, '"//conditions:default": "@rules_flutter//flutter/private:always"' in undeclared, undeclared)
    asserts.true(env, "The declared SDKs are: flutter, local, other." in build, build)
    for toolchain_type in ["toolchain_type", "exec_tools_toolchain_type"]:
        asserts.true(env, 'name = "undeclared_sdk_{}"'.format(toolchain_type) in build, build)

    # The release's toolchains keep their names whichever SDK is chosen.
    asserts.true(env, 'name = "darwin-arm64_toolchain"' in build, build)
    asserts.true(env, 'name = "local__darwin-arm64_toolchain"' in build, build)
    return unittest.end(env)

def _without_a_choice_the_release_test_impl(ctx):
    env = unittest.begin(ctx)
    build = toolchains_build_content(["flutter", "local"], "flutter")
    asserts.true(env, '":flag_unset"' in _setting(build, "flutter"), build)
    asserts.false(env, "flag_unset" in _setting(build, "local"), build)
    return unittest.end(env)

def _a_checkout_runs_on_the_machine_alone_test_impl(ctx):
    """An SDK's toolchains are registered for the hosts its engine serves alone."""
    env = unittest.begin(ctx)
    build = toolchains_build_content(["flutter", "local"], "local", {"local": ["darwin-arm64"]})
    for name in [
        "local__darwin-arm64_toolchain",
        "local__darwin-arm64_exec_tools_toolchain",
        "local__darwin-arm64_to_android-arm64_toolchain",
        "local__darwin-arm64_to_linux-x64_desktop_toolchain",
        # The release serves every host.
        "linux-x64_toolchain",
        "linux-x64_exec_tools_toolchain",
        "linux-x64_to_android-arm64_toolchain",
    ]:
        asserts.true(env, 'name = "{}"'.format(name) in build, name)
    for name in [
        "local__linux-x64_toolchain",
        "local__linux-x64_exec_tools_toolchain",
        "local__darwin-x64_toolchain",
        "local__linux-x64_to_android-arm64_toolchain",
        "local__windows-x64_to_linux-x64_desktop_toolchain",
    ]:
        asserts.false(env, 'name = "{}"'.format(name) in build, name)

    # On a machine no engine is built for, it serves no host, and its
    # toolchains there fail saying why, not "no matching toolchains".
    nowhere = toolchains_build_content(["flutter", "local"], "local", {"local": []}, {"local": "not this machine"})
    asserts.false(env, 'name = "local__darwin-arm64_toolchain"' in nowhere, nowhere)
    for toolchain_type in ["toolchain_type", "exec_tools_toolchain_type"]:
        asserts.true(env, 'name = "local__unknown_machine_{}"'.format(toolchain_type) in nowhere, nowhere)
    asserts.true(env, "exec_compatible_with = HOST_CONSTRAINTS" in nowhere, nowhere)
    asserts.true(env, 'message = "not this machine"' in nowhere, nowhere)
    asserts.false(env, "unknown_machine" in build, build)
    asserts.false(env, "HOST_CONSTRAINTS" in build, build)
    return unittest.end(env)

def _host_is_the_machine_that_fetches_test_impl(ctx):
    """`host` in an SDK's hosts is read when the toolchains repository is fetched, not by the extension."""
    env = unittest.begin(ctx)
    hosts = {"local": ["host"], "remote": ["linux-x64", "host"]}

    arm = machine_hosts(hosts, struct(name = "linux", arch = "aarch64"))
    asserts.equals(env, {"local": ["linux-arm64"], "remote": ["linux-arm64", "linux-x64"]}, arm.hosts)
    asserts.equals(env, {}, arm.unknown_machine)

    mac = machine_hosts(hosts, struct(name = "mac os x", arch = "aarch64"))
    asserts.equals(env, {"local": ["darwin-arm64"], "remote": ["darwin-arm64", "linux-x64"]}, mac.hosts)

    # A machine no engine is built for serves no `host`, and the SDKs that
    # serve it say why.
    unknown = machine_hosts(hosts, struct(name = "freebsd", arch = "amd64"))
    asserts.equals(env, {"local": [], "remote": ["linux-x64"]}, unknown.hosts)
    asserts.equals(env, ["local", "remote"], sorted(unknown.unknown_machine.keys()))
    asserts.true(env, "freebsd on amd64" in unknown.unknown_machine["local"], unknown.unknown_machine["local"])

    # An SDK that names hosts alone does not depend on the machine.
    fixed = machine_hosts({"local": ["darwin-arm64"]}, struct(name = "freebsd", arch = "amd64"))
    asserts.equals(env, {"local": ["darwin-arm64"]}, fixed.hosts)
    asserts.equals(env, {}, fixed.unknown_machine)
    return unittest.end(env)

_a_checkout_runs_on_the_machine_alone_test = unittest.make(_a_checkout_runs_on_the_machine_alone_test_impl)
_host_is_the_machine_that_fetches_test = unittest.make(_host_is_the_machine_that_fetches_test_impl)
_without_use_sdk_the_release_test = unittest.make(_without_use_sdk_the_release_test_impl)
_use_sdk_chooses_a_declared_sdk_test = unittest.make(_use_sdk_chooses_a_declared_sdk_test_impl)
_use_sdk_of_an_undeclared_name_test = unittest.make(_use_sdk_of_an_undeclared_name_test_impl)
_use_sdk_outside_the_root_test = unittest.make(_use_sdk_outside_the_root_test_impl)
_use_sdk_twice_test = unittest.make(_use_sdk_twice_test_impl)
_settings_follow_the_choice_test = unittest.make(_settings_follow_the_choice_test_impl)
_without_a_choice_the_release_test = unittest.make(_without_a_choice_the_release_test_impl)
_root_declares_each_form_test = unittest.make(_root_declares_each_form_test_impl)
_dependency_may_not_declare_test = unittest.make(_dependency_may_not_declare_test_impl)
_default_name_is_the_release_test = unittest.make(_default_name_is_the_release_test_impl)
_name_declared_twice_test = unittest.make(_name_declared_twice_test_impl)
_name_of_a_release_test = unittest.make(_name_of_a_release_test_impl)
_repositories_are_the_checkouts_own_test = unittest.make(_repositories_are_the_checkouts_own_test_impl)

def custom_sdks_test_suite(name):
    unittest.suite(
        name,
        _a_checkout_runs_on_the_machine_alone_test,
        _host_is_the_machine_that_fetches_test,
        _root_declares_each_form_test,
        _dependency_may_not_declare_test,
        _default_name_is_the_release_test,
        _name_declared_twice_test,
        _name_of_a_release_test,
        _repositories_are_the_checkouts_own_test,
        _without_use_sdk_the_release_test,
        _use_sdk_chooses_a_declared_sdk_test,
        _use_sdk_of_an_undeclared_name_test,
        _use_sdk_outside_the_root_test,
        _use_sdk_twice_test,
        _settings_follow_the_choice_test,
        _without_a_choice_the_release_test,
    )
