"""A module's Maven repository carries an engine that is not the release's.

Google publishes the release engine's Maven artifacts and no other's, so under
the checkout's SDK the repository holds the checkout engine's own, as
`flutter build aar --local-engine` copies a local engine's in: the embedding's
classes and each ABI's `libflutter.so`, from the checkout's `flutter.jar`, at
the version of the embedding's own POM from the out dir, which the module's
POM names them at, as `flutter build aar --local-engine` reads it. Under the
release, the repository holds no engine and the POM names Google's, at
`1.0.0-<engine revision>`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_ENGINE_ARTIFACTS = ["flutter_embedding_release", "arm64_v8a_release"]

def _spec(env):
    """The spec the repository's layout action is given: its `engineVersion` and its artifacts, by `group:artifact`."""
    writes = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and a.outputs.to_list()[0].basename.endswith(".maven_repo.json")
    ]
    asserts.equals(env, 1, len(writes), "one spec of the repository")
    spec = json.decode(writes[0].content)
    return spec["engineVersion"], {
        a["group"] + ":" + a["artifact"]: a
        for a in spec["artifacts"]
    }

def _layout_inputs(env):
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterAndroidMavenRepo"]
    asserts.equals(env, 1, len(actions), "one layout action")
    return actions[0].inputs.to_list()

def _carried_impl(ctx):
    env = analysistest.begin(ctx)
    engine_version, spec = _spec(env)

    # The engine's version is its embedding POM's, which the layout reads.
    asserts.equals(env, {"pom": "io.flutter:flutter_embedding_release"}, engine_version)
    module = spec["com.example.customengine.module:flutter_release"]
    for name in _ENGINE_ARTIFACTS:
        engine = spec.get("io.flutter:" + name)
        asserts.true(env, engine != None, "the repository carries io.flutter:%s: %s" % (name, spec.keys()))
        if not engine:
            continue
        asserts.equals(env, "jar", engine["packaging"])
        asserts.equals(env, True, engine.get("engine"), "io.flutter:%s is at the engine's version" % name)

        # The module's POM names the engine at the version the repository has.
        named = [d for d in module["dependencies"] if d["group"] == "io.flutter" and d["artifact"] == name]
        asserts.equals(env, [True], [d.get("engine") for d in named])

    # The embedding's POM is the engine's own, from its out dir, as `flutter
    # build aar --local-engine` links it; the ABI's is written, naming nothing.
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterAndroidMavenRepo"]
    argv = actions[0].argv if actions else []
    poms = [
        (argv[i + 1], argv[i + 2].split("/")[-1])
        for i in range(len(argv) - 2)
        if argv[i] == "--pom"
    ]
    asserts.equals(env, [("io.flutter:flutter_embedding_release", "flutter_embedding_release.pom")], poms)
    asserts.true(
        env,
        "flutter_embedding_release.pom" in [f.basename for f in _layout_inputs(env)],
        "the engine's POM is an input of the layout",
    )
    asserts.equals(env, [], spec.get("io.flutter:arm64_v8a_release", {"dependencies": []})["dependencies"])

    # The jars are the checkout engine's, the `local` SDK's, stripped: its
    # classes and its libraries.
    inputs = [f for f in _layout_inputs(env) if f.owner and f.owner.workspace_name.endswith("flutter_android_engine_arm64")]
    asserts.equals(
        env,
        ["local_release_stripped.jar", "local_release_stripped_native_libs.zip"],
        sorted([f.basename for f in inputs]),
    )
    return analysistest.end(env)

aar_carries_local_engine_test = analysistest.make(
    _carried_impl,
    config_settings = {str(Label("@rules_flutter//flutter:sdk")): "local"},
)

def _release_impl(ctx):
    env = analysistest.begin(ctx)
    engine_version, spec = _spec(env)
    asserts.true(env, engine_version.get("version", "").startswith("1.0.0-"), engine_version)
    asserts.equals(env, [], [k for k in spec if k.startswith("io.flutter:")])
    module = spec["com.example.customengine.module:flutter_release"]
    asserts.equals(
        env,
        sorted(_ENGINE_ARTIFACTS),
        sorted([d["artifact"] for d in module["dependencies"] if d["group"] == "io.flutter" and d.get("engine")]),
    )
    asserts.equals(
        env,
        [],
        [f for f in _layout_inputs(env) if f.owner and "flutter_android_engine" in f.owner.workspace_name],
    )
    return analysistest.end(env)

aar_of_release_names_google_engine_test = analysistest.make(
    _release_impl,
    config_settings = {str(Label("@rules_flutter//flutter:sdk")): "flutter"},
)
