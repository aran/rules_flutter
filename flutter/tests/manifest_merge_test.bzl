"""Analysis tests for flutter_android_manifest_merge.

Asserts the rule registers exactly one strict-merger action over the base
and overlay manifests and exposes the merged AndroidManifest.xml as its
only output — the contract flutter_android_app's debug-variant select()
arm relies on.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//providers:providers.bzl", "StarlarkAndroidResourcesInfo")
load("//flutter:android.bzl", "flutter_android_manifest_merge")

def _merge_action_test_impl(ctx):
    env = analysistest.begin(ctx)

    actions = analysistest.target_actions(env)
    merge_actions = [a for a in actions if a.mnemonic == "FlutterManifestMerge"]
    asserts.equals(env, 1, len(merge_actions), "expected exactly one FlutterManifestMerge action")
    action = merge_actions[0]

    argv = action.argv
    asserts.true(env, "--base" in argv, "argv must pass --base")
    asserts.true(env, "--overlay" in argv, "argv must pass --overlay")
    asserts.true(env, "--output" in argv, "argv must pass --output")
    base_arg = argv[argv.index("--base") + 1]
    overlay_arg = argv[argv.index("--overlay") + 1]
    asserts.true(
        env,
        base_arg.endswith("manifest_merge/AndroidManifest.xml"),
        "--base must be the base manifest, got %s" % base_arg,
    )
    asserts.true(
        env,
        overlay_arg.endswith("manifest_merge/DebugAndroidManifest.xml"),
        "--overlay must be the variant manifest, got %s" % overlay_arg,
    )

    input_basenames = [f.basename for f in action.inputs.to_list()]
    asserts.true(
        env,
        "merge_android_manifests" in input_basenames or "merge_android_manifests.exe" in input_basenames,
        "the merger tool must be an action input",
    )

    outputs = action.outputs.to_list()
    asserts.equals(env, 1, len(outputs))
    asserts.equals(env, "AndroidManifest.xml", outputs[0].basename)

    target = analysistest.target_under_test(env)
    default_outputs = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(default_outputs), "rule must expose exactly the merged manifest")
    asserts.equals(env, "AndroidManifest.xml", default_outputs[0].basename)

    return analysistest.end(env)

_merge_action_test = analysistest.make(_merge_action_test_impl)

def _mock_android_lib_impl(ctx):
    node = struct(
        manifest = ctx.file.manifest,
        exports_manifest = True,
    )
    return [
        StarlarkAndroidResourcesInfo(
            direct_resources_nodes = depset([node]),
            transitive_resources_nodes = depset(),
        ),
    ]

_mock_android_lib = rule(
    implementation = _mock_android_lib_impl,
    attrs = {
        "manifest": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
)

def _manifest_content_test_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + "_check.sh")
    manifest = ctx.file.manifest
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'FILE="%s"' % manifest.short_path,
    ]
    for s in ctx.attr.expected_substrings:
        lines.append('grep -Fq -- %r "$FILE" || { echo "Missing expected substring: %s"; cat "$FILE"; exit 1; }' % (s, s))
    for s in ctx.attr.forbidden_substrings:
        lines.append('if grep -Fq -- %r "$FILE"; then echo "Found forbidden substring: %s"; cat "$FILE"; exit 1; fi' % (s, s))
    for s in ctx.attr.expected_once:
        lines.append('count=$(grep -Fo -- %r "$FILE" | wc -l | tr -d " ")' % s)
        lines.append('if [ "$count" -ne 1 ]; then echo "Expected %s exactly once, got $count"; cat "$FILE"; exit 1; fi' % s)

    ctx.actions.write(
        output = script,
        content = "\n".join(lines) + "\n",
        is_executable = True,
    )
    return [
        DefaultInfo(
            executable = script,
            runfiles = ctx.runfiles(files = [manifest]),
        ),
    ]

_manifest_content_test = rule(
    implementation = _manifest_content_test_impl,
    test = True,
    attrs = {
        "manifest": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "expected_substrings": attr.string_list(),
        "forbidden_substrings": attr.string_list(),
        "expected_once": attr.string_list(),
    },
)

def manifest_merge_test_suite(name):
    """Defines the analysis and execution tests for flutter_android_manifest_merge.

    Args:
      name: The test_suite target name.
    """
    flutter_android_manifest_merge(
        name = "_manifest_merge_under_test",
        base = "manifest_merge/AndroidManifest.xml",
        overlay = "manifest_merge/DebugAndroidManifest.xml",
        tags = ["manual"],
    )

    _merge_action_test(
        name = name + "_action",
        target_under_test = ":_manifest_merge_under_test",
    )

    # 1. Regression test: leading BOM, whitespace, and comments before <?xml ...?>
    write_file(
        name = "_prologue_base_manifest",
        out = "_prologue_base/AndroidManifest.xml",
        content = [
            "﻿  ",
            "<!-- Leading license header before XML declaration -->",
            '<?xml version="1.0" encoding="utf-8"?>',
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
            '    <application android:label="example"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    write_file(
        name = "_prologue_overlay_manifest",
        out = "_prologue_overlay/AndroidManifest.xml",
        content = [
            "",
            "<!-- Leading comment in overlay before XML declaration -->",
            '<?xml version="1.0" encoding="utf-8"?>',
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
            '    <uses-permission android:name="android.permission.INTERNET"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    flutter_android_manifest_merge(
        name = "_prologue_merged",
        base = ":_prologue_base_manifest",
        overlay = ":_prologue_overlay_manifest",
        tags = ["manual"],
    )

    _manifest_content_test(
        name = name + "_prologue_before_xml_decl",
        manifest = ":_prologue_merged",
        expected_substrings = [
            '<uses-permission android:name="android.permission.INTERNET"/>',
        ],
        expected_once = [
            "android.permission.INTERNET",
        ],
    )

    # 2. Regression test: chained merges (variant overlay -> permissions overlay -> library)
    #    and AGP priority for tools:node="remove" in base, overlay, and library manifests.
    write_file(
        name = "_remove_base_manifest",
        out = "_remove_base/AndroidManifest.xml",
        content = [
            '<?xml version="1.0" encoding="utf-8"?>',
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android"',
            '    xmlns:tools="http://schemas.android.com/tools">',
            '    <uses-permission android:name="android.permission.READ_PHONE_STATE" tools:node="remove"/>',
            '    <uses-permission android:name="android.permission.CAMERA"/>',
            '    <application android:label="example"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    write_file(
        name = "_remove_variant_overlay_manifest",
        out = "_remove_variant_overlay/AndroidManifest.xml",
        content = [
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android"',
            '    xmlns:tools="http://schemas.android.com/tools">',
            '    <uses-permission android:name="android.permission.CAMERA" tools:node="remove"/>',
            '    <uses-permission android:name="android.permission.VIBRATE"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    write_file(
        name = "_remove_permissions_overlay_manifest",
        out = "_remove_permissions_overlay/AndroidManifest.xml",
        content = [
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
            '    <uses-permission android:name="android.permission.INTERNET"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    write_file(
        name = "_remove_lib1_manifest",
        out = "_remove_lib1/AndroidManifest.xml",
        content = [
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android"',
            '    xmlns:tools="http://schemas.android.com/tools">',
            '    <uses-permission android:name="android.permission.READ_PHONE_STATE"/>',
            '    <uses-permission android:name="android.permission.RECORD_AUDIO"/>',
            '    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" tools:node="remove"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    write_file(
        name = "_remove_lib2_manifest",
        out = "_remove_lib2/AndroidManifest.xml",
        content = [
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android"',
            '    xmlns:tools="http://schemas.android.com/tools">',
            '    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>',
            '    <uses-permission android:name="android.permission.RECORD_AUDIO" tools:node="remove"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    _mock_android_lib(
        name = "_remove_lib1",
        manifest = ":_remove_lib1_manifest",
        tags = ["manual"],
    )

    _mock_android_lib(
        name = "_remove_lib2",
        manifest = ":_remove_lib2_manifest",
        tags = ["manual"],
    )

    flutter_android_manifest_merge(
        name = "_remove_variant_merged",
        base = ":_remove_base_manifest",
        overlay = ":_remove_variant_overlay_manifest",
        tags = ["manual"],
    )

    flutter_android_manifest_merge(
        name = "_remove_permissions_merged",
        base = ":_remove_variant_merged",
        overlay = ":_remove_permissions_overlay_manifest",
        tags = ["manual"],
    )

    flutter_android_manifest_merge(
        name = "_remove_merged",
        base = ":_remove_permissions_merged",
        libraries = [":_remove_lib1", ":_remove_lib2"],
        tags = ["manual"],
    )

    _manifest_content_test(
        name = name + "_tools_node_remove",
        manifest = ":_remove_merged",
        expected_substrings = [
            '<uses-permission android:name="android.permission.INTERNET"/>',
            '<uses-permission android:name="android.permission.VIBRATE"/>',
            '<uses-permission android:name="android.permission.RECORD_AUDIO"/>',
        ],
        forbidden_substrings = [
            "READ_PHONE_STATE",
            "CAMERA",
            "ACCESS_FINE_LOCATION",
            "tools:node",
        ],
    )

    # 3. Regression test: android:maxSdkVersion scoping and upgrades across base and libraries
    write_file(
        name = "_maxsdk_base_manifest",
        out = "_maxsdk_base/AndroidManifest.xml",
        content = [
            '<?xml version="1.0" encoding="utf-8"?>',
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
            '    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28" android:usesPermissionFlags="neverForLocation"/>',
            '    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>',
            '    <application android:label="example"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    write_file(
        name = "_maxsdk_lib1_manifest",
        out = "_maxsdk_lib1/AndroidManifest.xml",
        content = [
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
            '    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>',
            '    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="28"/>',
            '    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    write_file(
        name = "_maxsdk_lib2_manifest",
        out = "_maxsdk_lib2/AndroidManifest.xml",
        content = [
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
            '    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    _mock_android_lib(
        name = "_maxsdk_lib1",
        manifest = ":_maxsdk_lib1_manifest",
        tags = ["manual"],
    )

    _mock_android_lib(
        name = "_maxsdk_lib2",
        manifest = ":_maxsdk_lib2_manifest",
        tags = ["manual"],
    )

    flutter_android_manifest_merge(
        name = "_maxsdk_merged",
        base = ":_maxsdk_base_manifest",
        libraries = [":_maxsdk_lib1", ":_maxsdk_lib2"],
        tags = ["manual"],
    )

    _manifest_content_test(
        name = name + "_max_sdk_version_upgrade",
        manifest = ":_maxsdk_merged",
        expected_substrings = [
            '<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28" android:usesPermissionFlags="neverForLocation"/>',
            '<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>',
            '<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>',
        ],
        forbidden_substrings = [
            '<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>',
            '<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>',
        ],
        expected_once = [
            "android.permission.WRITE_EXTERNAL_STORAGE",
            "android.permission.BLUETOOTH",
            "android.permission.READ_EXTERNAL_STORAGE",
        ],
    )

    # 4. Regression test: uses-permission-sdk-23 remove does not suppress plain uses-permission and vice versa
    write_file(
        name = "_sdk23_base_manifest",
        out = "_sdk23_base/AndroidManifest.xml",
        content = [
            '<?xml version="1.0" encoding="utf-8"?>',
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android"',
            '    xmlns:tools="http://schemas.android.com/tools">',
            '    <uses-permission-sdk-23 android:name="android.permission.CAMERA" tools:node="remove"/>',
            '    <uses-permission android:name="android.permission.VIBRATE" tools:node="remove"/>',
            '    <application android:label="example"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    write_file(
        name = "_sdk23_lib_manifest",
        out = "_sdk23_lib/AndroidManifest.xml",
        content = [
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
            '    <uses-permission android:name="android.permission.CAMERA"/>',
            '    <uses-permission-sdk-23 android:name="android.permission.CAMERA"/>',
            '    <uses-permission-sdk-23 android:name="android.permission.VIBRATE"/>',
            '    <uses-permission android:name="android.permission.VIBRATE"/>',
            "</manifest>",
            "",
        ],
        tags = ["manual"],
    )

    _mock_android_lib(
        name = "_sdk23_lib",
        manifest = ":_sdk23_lib_manifest",
        tags = ["manual"],
    )

    flutter_android_manifest_merge(
        name = "_sdk23_merged",
        base = ":_sdk23_base_manifest",
        libraries = [":_sdk23_lib"],
        tags = ["manual"],
    )

    _manifest_content_test(
        name = name + "_sdk23_remove_scoping",
        manifest = ":_sdk23_merged",
        expected_substrings = [
            '<uses-permission android:name="android.permission.CAMERA"/>',
            '<uses-permission-sdk-23 android:name="android.permission.VIBRATE"/>',
        ],
        forbidden_substrings = [
            '<uses-permission-sdk-23 android:name="android.permission.CAMERA"/>',
            '<uses-permission android:name="android.permission.VIBRATE"/>',
            "tools:node",
        ],
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_action",
            ":" + name + "_prologue_before_xml_decl",
            ":" + name + "_tools_node_remove",
            ":" + name + "_max_sdk_version_upgrade",
            ":" + name + "_sdk23_remove_scoping",
        ],
    )
