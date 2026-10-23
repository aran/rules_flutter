"""Analysis tests for the post-link APK overlay in `flutter_android_app`.

`flutter_android_app` builds a payload-free `android_binary` (no Flutter
assets, no `libapp.so` java_import) and injects the Flutter payload after
resource linking via `flutter_android_apk_overlay`. These tests pin that
split, the property perf hypotheses H18/H20 rely on:

- the base binary's resource-linking, desugaring and dexing actions never see
  the Flutter payload, so a Dart edit cannot re-run them;
- the overlay consumes the payload (the bundle's `native_libs.jar` and
  `flutter_assets` tree) and produces the signed APK through the stock
  zipalign/sign steps.

Soundness in the other direction — an Android resource, manifest or
Java/Kotlin edit still re-runs the steps that need it — holds because those
files remain inputs of the base binary; it is verified by rebuilding
e2e/hello_world after touching them (see the H18 commit).
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

# Actions whose outputs must not change on a Dart edit. Each is checked when
# present; PackageAndroidResources and ApkBuilder are additionally required so
# the test is not vacuous. These are the mnemonics rules_android 0.8.0 actually
# registers on the base android_binary (verified by aquery on
# :__hello_world_android_binary): the app link step is PackageAndroidResources,
# not LinkAndroidResources, and dexing is Desugar/DexBuilder/DexShardsToMerge/
# DexMerger/ShardForMultidex/AppendDesugarDexes/MergeDexZips, not AndroidDexer/
# ShardClassesToDex.
_LINK_DEX_MNEMONICS = [
    "PackageAndroidResources",
    "MergeManifests",
    "StarlarkRClassGenerator",
    "KotlinCompile",
    "Desugar",
    "DexBuilder",
    "DexShardsToMerge",
    "DexMerger",
    "ShardForMultidex",
    "AppendDesugarDexes",
    "MergeDexZips",
    "JavaDeployJar",
    "ResourceExtractor",
    "ApkBuilder",
]

# Path substrings identifying the Flutter payload. The engine's libflutter.so
# and the runner/registrant jars never match these.
_PAYLOAD_SUBSTRINGS = [
    "flutter_assets",
    "kernel_blob",
    "libapp",
    "bundle_native_libs",
]

def _payload_inputs(action):
    matches = []
    for f in action.inputs.to_list():
        for sub in _PAYLOAD_SUBSTRINGS:
            if sub in f.path:
                matches.append(f.path)
                break
    return matches

def _base_binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    by_mnemonic = {}
    for a in actions:
        by_mnemonic.setdefault(a.mnemonic, []).append(a)

    for mnemonic in ("PackageAndroidResources", "ApkBuilder"):
        asserts.true(
            env,
            mnemonic in by_mnemonic,
            "expected %s actions on the base android_binary, got %s" %
            (mnemonic, sorted(by_mnemonic.keys())),
        )

    for mnemonic in _LINK_DEX_MNEMONICS:
        for action in by_mnemonic.get(mnemonic, []):
            asserts.equals(
                env,
                [],
                _payload_inputs(action)[:5],
                "%s must not take the Flutter payload as input" % mnemonic,
            )
    return analysistest.end(env)

_base_binary_test = analysistest.make(_base_binary_test_impl)

def _overlay_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    by_mnemonic = {}
    for a in actions:
        by_mnemonic.setdefault(a.mnemonic, []).append(a)

    for mnemonic in ("FlutterApkOverlay", "AndroidZipAlign", "ApkSignerTool", "WriteDeployInfo"):
        asserts.equals(
            env,
            1,
            len(by_mnemonic.get(mnemonic, [])),
            "expected exactly one %s action, got %s" %
            (mnemonic, sorted(by_mnemonic.keys())),
        )

    overlay = by_mnemonic["FlutterApkOverlay"][0]
    input_paths = [f.path for f in overlay.inputs.to_list()]
    asserts.true(
        env,
        any(["bundle_native_libs.jar" in p for p in input_paths]),
        "FlutterApkOverlay must consume native_libs.jar, inputs: %s" % input_paths,
    )
    asserts.true(
        env,
        any(["flutter_assets" in p for p in input_paths]),
        "FlutterApkOverlay must consume flutter_assets, inputs: %s" % input_paths,
    )
    overlay_outputs = [f.basename for f in overlay.outputs.to_list()]
    asserts.equals(env, 1, len(overlay_outputs))
    asserts.true(
        env,
        overlay_outputs[0].endswith("_overlay_unsigned.apk"),
        "unexpected overlay output: %s" % overlay_outputs,
    )

    target = analysistest.target_under_test(env)
    default_outputs = [f.basename for f in target[DefaultInfo].files.to_list()]
    asserts.equals(env, 1, len(default_outputs))
    asserts.true(
        env,
        default_outputs[0].endswith(".apk"),
        "overlay must expose the signed APK, got %s" % default_outputs,
    )

    # The overlay regenerates deploy info against its own signed APK (the
    # android toolchain's deploy_info_writer, same --manifest/--apk/
    # --deploy_info form android_binary uses), so mobile-install tooling
    # resolves the APK this rule produced rather than the payload-free base.
    deploy_action = by_mnemonic["WriteDeployInfo"][0]
    deploy_inputs = [f.path for f in deploy_action.inputs.to_list()]
    asserts.true(
        env,
        any(["overlay" in p and p.endswith(".apk") for p in deploy_inputs]),
        "deploy-info writer must read the overlay signed APK, inputs: %s" % deploy_inputs,
    )
    asserts.true(
        env,
        any([p.endswith(".xml") for p in deploy_inputs]),
        "deploy-info writer must read the merged manifest, inputs: %s" % deploy_inputs,
    )
    deploy_outputs = [f.basename for f in deploy_action.outputs.to_list()]
    asserts.equals(env, 1, len(deploy_outputs))
    asserts.true(
        env,
        deploy_outputs[0].endswith(".deploy_info.pb"),
        "unexpected deploy-info output: %s" % deploy_outputs,
    )

    # The android_deploy_info output group is overlay-owned: the freshly
    # written .pb plus the merged manifest. Every other group is forwarded
    # from the base binary, so actions over them keep resolving the base.
    deploy_group = target[OutputGroupInfo].android_deploy_info.to_list()
    pb = [f for f in deploy_group if f.basename.endswith(".deploy_info.pb")]
    asserts.equals(
        env,
        1,
        len(pb),
        "android_deploy_info must hold exactly one overlay-written .pb, got %s" %
        [f.path for f in deploy_group],
    )
    asserts.true(
        env,
        "overlay" in pb[0].path,
        "deploy_info.pb must be written by the overlay, got %s" % pb[0].path,
    )
    asserts.true(
        env,
        any([f.basename.endswith(".xml") for f in deploy_group]),
        "android_deploy_info must also carry the merged manifest, got %s" %
        [f.path for f in deploy_group],
    )
    return analysistest.end(env)

_overlay_test = analysistest.make(_overlay_test_impl)

def android_apk_overlay_test_suite(name, app_name, tags = []):
    """Defines the APK overlay analysis tests for one `flutter_android_app`.

    Args:
      name: Prefix for the test targets.
      app_name: The `flutter_android_app` name; its `__<app>_binary` and
        `__<app>_overlay` targets are analyzed.
      tags: Tags forwarded to each test. Pass `["no-windows-ci"]`: the tests
        analyze the Android app, which is skipped on the Windows CI runner
        (pagefile OOM) via --build_tag_filters/--test_tag_filters.
    """
    _base_binary_test(
        name = name + "_base_binary",
        target_under_test = ":__%s_binary" % app_name,
        tags = tags,
    )
    _overlay_test(
        name = name + "_overlay",
        target_under_test = ":__%s_overlay" % app_name,
        tags = tags,
    )
