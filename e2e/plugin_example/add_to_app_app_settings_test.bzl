"""Add-to-app builds a plugin whose Package.swift reads the app, for the module.

audio_session 0.1.x reads `AUDIO_SESSION_MICROPHONE` from its manifest's
environment. An app evaluates the manifest with its `swift_package_environment`,
and so does a module, through the same attribute of `flutter_ios_xcframeworks`
and `flutter_macos_xcframeworks`. An aspect over the target under test finds
the evaluation and the environment it runs with.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_EvaluationsInfo = provider(
    doc = "The Package.swift evaluations under a target.",
    fields = {"evaluations": "depset of structs of `label` and `environment` (`(name, value)` pairs)"},
)

_EVALUATION_MNEMONIC = "FlutterSwiftPMAppManifest"

def _evaluations_aspect_impl(target, ctx):
    direct = []
    for action in target.actions:
        if action.mnemonic != _EVALUATION_MNEMONIC:
            continue
        direct.append(struct(
            label = str(target.label),
            environment = tuple(sorted(action.env.items())),
        ))
    transitive = []
    for name in ("xcframeworks", "_app_settings_libraries", "deps"):
        value = getattr(ctx.rule.attr, name, None)
        if value == None:
            continue
        for dep in (value if type(value) == "list" else [value]):
            if _EvaluationsInfo in dep:
                transitive.append(dep[_EvaluationsInfo].evaluations)
    return [_EvaluationsInfo(evaluations = depset(direct, transitive = transitive))]

_evaluations_aspect = aspect(
    implementation = _evaluations_aspect_impl,
    attr_aspects = ["xcframeworks", "_app_settings_libraries", "deps"],
)

def _audio_session(env):
    evaluations = [
        e
        for e in analysistest.target_under_test(env)[_EvaluationsInfo].evaluations.to_list()
        if "audio_session" in e.label
    ]
    asserts.true(env, len(evaluations) > 0, "no evaluation of audio_session's Package.swift")
    return evaluations

def _module_settings_test_impl(ctx):
    env = analysistest.begin(ctx)
    for evaluation in _audio_session(env):
        # The module sets no variable, so the manifest takes its own default.
        asserts.false(env, "AUDIO_SESSION_MICROPHONE" in dict(evaluation.environment), evaluation)
    return analysistest.end(env)

def _module_environment_test_impl(ctx):
    env = analysistest.begin(ctx)
    for evaluation in _audio_session(env):
        asserts.equals(env, "0", dict(evaluation.environment).get("AUDIO_SESSION_MICROPHONE"), evaluation)
    return analysistest.end(env)

# A module that sets no `swift_package_environment`: the manifest takes its
# own default.
add_to_app_module_settings_test = analysistest.make(
    _module_settings_test_impl,
    extra_target_under_test_aspects = [_evaluations_aspect],
)

# A module whose `swift_package_environment` sets AUDIO_SESSION_MICROPHONE=0.
add_to_app_module_environment_test = analysistest.make(
    _module_environment_test_impl,
    extra_target_under_test_aspects = [_evaluations_aspect],
)
