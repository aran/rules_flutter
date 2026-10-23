"""Analysis test proving the smoke `extra_roots` entry is not a no-op.

`consumer_import` (in `BUILD.bazel`) points `extra_roots` at
`consumer_ghost`, a package with no sources. A root found from the files
wins, so an entry for a package that has no files can only come from
`extra_roots`: if the entry regressed to a no-op the ghost would vanish from
the emitted `package_config.json` and this test would fail. (Pointing
`extra_roots` at `consumer_dep` instead would prove nothing — its sources
already determine its root.)
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_flutter//flutter/tests:action_content.bzl", "package_entry", "written_json")

def _ghost_roots_test_impl(ctx):
    env = analysistest.begin(ctx)
    config = written_json(env, ".package_config.json")
    entry = package_entry(config, "consumer_ghost")
    asserts.true(
        env,
        entry != None,
        "expected a `consumer_ghost` entry in .package_config.json: only extra_roots can put it there, the package has no sources",
    )
    if entry != None:
        asserts.true(
            env,
            entry.get("rootUri", "").endswith("e2e/smoke"),
            "the ghost rootUri must name the extra root, got %r" % (entry,),
        )
        asserts.equals(env, "lib/", entry.get("packageUri"))
    asserts.true(
        env,
        package_entry(config, "consumer_dep") != None,
        "the file-derived `consumer_dep` entry is still present",
    )
    return analysistest.end(env)

_ghost_roots_test = analysistest.make(_ghost_roots_test_impl)

def consumer_extra_roots_test_suite(name):
    """Extra-roots smoke test.

    Args:
      name: The test_suite target name.
    """
    _ghost_roots_test(
        name = name + "_ghost",
        target_under_test = ":consumer_import",
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_ghost"],
    )
