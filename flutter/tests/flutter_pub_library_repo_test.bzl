"""Unit tests for the library repository of a built pub package.

A package's library is its dependency cycle built as one target (Bazel has no
cycles; pub does). What is decided here, away from a fetch: which repository
and target another package depends on, what the library's BUILD file says,
and that an overlay cannot be part of a cycle.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_pub_index.bzl", "INDEX_REPO", "MEMBER_DART", "MEMBER_FLUTTER", "MEMBER_OVERLAY", "library_label", "library_repo", "source_repo")
load("//flutter/private:flutter_pub_library_repo.bzl", "is_flutter_library", "make_alias_build_content", "make_library_build_content", "overlay_in_cycle_error")

def _repositories_are_named_by_their_part_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "flutter_pub__dio", source_repo("dio"))
    asserts.equals(env, "flutter_pub_lib__dio", library_repo("dio"))
    asserts.equals(env, "flutter_pub_index", INDEX_REPO)

    # A built package is depended on through its library; the lock's other
    # entries (package:flutter, a stub) are their own.
    index = struct(built = {"dio": True}, other = {"flutter": True}, sdk_packages = {"flutter": True}, main_prefix = "flutter_pub", sdk_prefix = "flutter_pub", via_hub = False, sdk_hubs = {})
    asserts.equals(env, "@flutter_pub_lib__dio//:dio", library_label(index, "dio"))
    asserts.equals(env, "@flutter_pub__flutter//:flutter", library_label(index, "flutter"))

    # An SDK package of another SDK's framework is in that framework's
    # repositories; a package of any other kind stays the build's. When the
    # SDKs' frameworks differ, a package depending on an SDK package reaches the
    # hub's alias, which follows the selected SDK.
    other_sdk = struct(built = {"dio": True}, other = {"flutter": True}, sdk_packages = {"flutter": True}, main_prefix = "flutter_pub", sdk_prefix = "flutter_pub-local", via_hub = False, sdk_hubs = {})
    asserts.equals(env, "@flutter_pub-local__flutter//:flutter", library_label(other_sdk, "flutter"))
    asserts.equals(env, "@flutter_pub_lib__dio//:dio", library_label(other_sdk, "dio"))
    through_hub = struct(built = {"dio": True}, other = {"flutter": True}, sdk_packages = {"flutter": True}, main_prefix = "flutter_pub", sdk_prefix = "flutter_pub", via_hub = True, sdk_hubs = {"flutter": "deps"})
    asserts.equals(env, "@deps//:flutter", library_label(through_hub, "flutter"))
    asserts.equals(env, "@flutter_pub_lib__dio//:dio", library_label(through_hub, "dio"))

    return unittest.end(env)

repositories_are_named_by_their_part_test = unittest.make(_repositories_are_named_by_their_part_test_impl)

def _a_cycle_is_one_library_over_its_members_test_impl(ctx):
    env = unittest.begin(ctx)

    flutter = make_library_build_content(
        name = "dio",
        members = ["@flutter_pub__dio//:dio", "@flutter_pub__dio_web_adapter//:dio_web_adapter"],
        deps = ["@flutter_pub_lib__path//:path"],
        flutter = True,
        member_dependencies = {"dio_web_adapter": ["dio"], "dio": ["path", "dio_web_adapter"]},
    )
    asserts.true(env, 'load("@rules_flutter//flutter/private:flutter_pub_library.bzl", "flutter_pub_library")' in flutter, flutter)
    asserts.true(env, '\nflutter_pub_library(\n    name = "dio",' in flutter, flutter)
    asserts.true(env, '    members = ["@flutter_pub__dio//:dio", "@flutter_pub__dio_web_adapter//:dio_web_adapter"],' in flutter, flutter)
    asserts.true(env, '    deps = ["@flutter_pub_lib__path//:path"],' in flutter, flutter)

    # Each member's own dependencies, which its plugin's are read from.
    asserts.true(env, '    member_dependencies = {"dio": ["dio_web_adapter", "path"], "dio_web_adapter": ["dio"]},\n' in flutter, flutter)

    # A cycle with nothing of Flutter's is rules_dart's own library.
    dart = make_library_build_content(
        name = "path",
        members = ["@flutter_pub__path//:path"],
        deps = [],
        flutter = False,
    )
    asserts.true(env, 'load("@rules_dart//dart/pub:pub_library.bzl", "pub_library")' in dart, dart)
    asserts.true(env, "\npub_library(\n" in dart, dart)
    asserts.true(env, "    deps = [],\n" in dart, dart)

    return unittest.end(env)

a_cycle_is_one_library_over_its_members_test = unittest.make(_a_cycle_is_one_library_over_its_members_test_impl)

def _a_library_exports_its_members_android_libraries_on_android_test_impl(ctx):
    """A library lists its members' Android libraries under `exports`, on Android only.

    `exports` is the one attribute rules_android's dex aspect follows from the
    library to them, so an APK that depends on the library dexes them.
    """
    env = unittest.begin(ctx)

    content = make_library_build_content(
        name = "dio",
        members = ["@flutter_pub__dio//:dio"],
        deps = [],
        flutter = True,
        android_libs = ["@flutter_pub__dio//android:lib"],
    )
    asserts.true(
        env,
        '    exports = select({\n        "@platforms//os:android": ["@flutter_pub__dio//android:lib"],\n        "//conditions:default": [],\n    }),\n' in content,
        content,
    )

    # No Android library, no attribute: nothing loads an `android/` package.
    asserts.false(env, "exports" in make_library_build_content("dio", ["@flutter_pub__dio//:dio"], [], True), "exports without a library")

    return unittest.end(env)

a_library_exports_its_members_android_libraries_on_android_test = unittest.make(_a_library_exports_its_members_android_libraries_on_android_test_impl)

def _package_test_carries_the_runner_test_impl(ctx):
    """`dart_test` runs tests through the runner on its direct `package:test`."""
    env = unittest.begin(ctx)

    content = make_library_build_content(
        name = "test",
        members = ["@flutter_pub__test//:test"],
        deps = ["@flutter_pub_lib__test_api//:test_api"],
        flutter = False,
    )
    asserts.true(env, '\npub_test_runner(\n    name = "test",' in content, content)
    asserts.true(env, '    library = ":test_library",' in content, content)
    asserts.true(env, '\npub_library(\n    name = "test_library",' in content, content)
    asserts.true(env, '    members = ["@flutter_pub__test//:test"],' in content, content)

    # Reaching a package that makes a library Flutter's (one `resolve` maps)
    # still leaves `package:test` its runner.
    reaching = make_library_build_content("test", ["@flutter_pub__test//:test"], ["@flutter_pub__analyzer//:analyzer"], True)
    asserts.true(env, '\npub_test_runner(\n    name = "test",' in reaching, reaching)

    # Any other package is its library alone.
    asserts.false(env, "pub_test_runner" in make_library_build_content("test_api", ["@flutter_pub__test_api//:test_api"], [], False))

    return unittest.end(env)

package_test_carries_the_runner_test = unittest.make(_package_test_carries_the_runner_test_impl)

def _the_others_of_a_cycle_alias_its_library_test_impl(ctx):
    env = unittest.begin(ctx)

    content = make_alias_build_content("dio_web_adapter", "@flutter_pub_lib__dio//:dio")
    asserts.true(env, 'name = "dio_web_adapter",' in content, content)
    asserts.true(env, 'actual = "@flutter_pub_lib__dio//:dio",' in content, content)

    return unittest.end(env)

the_others_of_a_cycle_alias_its_library_test = unittest.make(_the_others_of_a_cycle_alias_its_library_test_impl)

def _an_overlay_in_a_cycle_is_refused_naming_it_and_the_cycle_test_impl(ctx):
    env = unittest.begin(ctx)

    message = overlay_in_cycle_error("jni", ["jni", "jni_helper", "jni_other"])
    asserts.true(env, "package `jni` is built from a plugin overlay" in message, message)
    asserts.true(env, "`jni_helper`, `jni_other`" in message, message)
    asserts.false(env, "with `jni`" in message, message)

    return unittest.end(env)

an_overlay_in_a_cycle_is_refused_naming_it_and_the_cycle_test = unittest.make(
    _an_overlay_in_a_cycle_is_refused_naming_it_and_the_cycle_test_impl,
)

def _a_library_reaching_a_plugin_is_flutters_test_impl(ctx):
    """A pure-Dart package that reaches a Flutter package is built as Flutter's.

    rules_dart's `pub_library` forwards no `FlutterInfo`, so a plugin reached
    only through such a package would be dropped from every app above it,
    unregistered and unlinked, with nothing failing.
    """
    env = unittest.begin(ctx)

    asserts.true(env, is_flutter_library([MEMBER_FLUTTER], []), "a plugin's own library")
    asserts.true(env, is_flutter_library([MEMBER_DART], [MEMBER_DART, MEMBER_FLUTTER]), "a Dart package reaching a plugin")
    asserts.true(env, is_flutter_library([MEMBER_DART], [MEMBER_OVERLAY]), "a Dart package reaching an overlay")
    asserts.true(env, is_flutter_library([MEMBER_DART], [], reaches_mapped = True), "a Dart package reaching a mapped package")

    # Dart all the way down stays rules_dart's.
    asserts.false(env, is_flutter_library([MEMBER_DART], [MEMBER_DART]), "a Dart package reaching only Dart")
    asserts.false(env, is_flutter_library([MEMBER_DART], []), "a Dart package reaching nothing")

    return unittest.end(env)

a_library_reaching_a_plugin_is_flutters_test = unittest.make(_a_library_reaching_a_plugin_is_flutters_test_impl)

def flutter_pub_library_repo_test_suite(name):
    unittest.suite(
        name,
        repositories_are_named_by_their_part_test,
        a_cycle_is_one_library_over_its_members_test,
        a_library_exports_its_members_android_libraries_on_android_test,
        package_test_carries_the_runner_test,
        the_others_of_a_cycle_alias_its_library_test,
        an_overlay_in_a_cycle_is_refused_naming_it_and_the_cycle_test,
        a_library_reaching_a_plugin_is_flutters_test,
    )
