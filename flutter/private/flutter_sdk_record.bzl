"""What an app records of the Flutter SDK it was built with, and the check behind it.

An app built with a framework or an engine other than the release's carries
`flutter_assets/flutter_sdk.json`: where each piece came from, and the
fingerprints the engine's VM checks (the snapshot hash, the kernel format). The
record is the output of the check that those pieces belong together
(`tools/sdk_check.dart`), so an app that bundles the record has been checked,
and an app of the release carries neither: its pieces are the official ones,
and the app is as it has always been.

The check is one action for each SDK, target and mode, shared by every app of
that combination. A mismatch fails the build naming each artifact.
"""

load("//flutter:engine.bzl", "FlutterWebSdkInfo")
load("//flutter:providers.bzl", "FlutterSdkRecordInfo")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:sdk_origin.bzl", "RELEASE_ORIGIN", "is_release_engine")

visibility("//flutter/...")

_TOOLCHAIN_TYPE = "@rules_flutter//flutter:toolchain_type"

def _public(provenance):
    """A slice's provenance without what names the machine it was read on."""
    return {
        key: value
        for key, value in provenance.items()
        if key != "path" and not _is_absolute_path(value)
    }

def _is_absolute_path(value):
    """Whether a value is an absolute path on any host: POSIX, a Windows drive, or a UNC share."""
    return (
        value.startswith("/") or
        value.startswith("\\\\") or
        (len(value) > 2 and value[0].isalpha() and value[1] == ":" and value[2] in "/\\")
    )

def _flutter_sdk_record_impl(ctx):
    sdk = ctx.toolchains[_TOOLCHAIN_TYPE].flutter_sdk_info
    engine = sdk.engine
    engine_label = sdk.slice_labels.get("engine", "")
    info = FlutterSdkRecordInfo(
        record = None,
        engine_label = engine_label,
        engine_cpus = engine.cpus if engine else [],
        engine_xcframework_slices = engine.xcframework_slices if engine else [],
    )

    # The release's pieces are the official ones and agree by construction.
    custom = sdk.framework_json != None or not is_release_engine(sdk.host_tools)
    if not custom and not ctx.attr.always:
        return [DefaultInfo(), info]
    if not engine:
        fail("%s: the \"%s\" Flutter SDK has no engine for this platform to check." % (ctx.label, sdk.sdk))

    mode = ctx.attr.mode
    release = mode == "release"
    kernel = sdk.kernel_release if release else sdk.kernel_debug
    if kernel == None:
        fail("%s: the \"%s\" Flutter SDK has no %s platform kernel." % (ctx.label, sdk.sdk, "release" if release else "debug"))
    tools = portable_tools(ctx)

    pieces = {
        sdk.slice_labels["host_tools"]: _public(sdk.host_tools.provenance),
        sdk.slice_labels["platform_kernel"]: _public(kernel.provenance),
        engine_label: _public(engine.provenance),
    }
    if sdk.gen_snapshot_info:
        pieces[sdk.slice_labels["gen_snapshot"]] = _public(sdk.gen_snapshot_info.provenance)
    record_in = ctx.actions.declare_file(ctx.label.name + "_in.json")
    ctx.actions.write(record_in, json.encode_indent({
        "sdk": sdk.sdk,
        "framework": {"origin": "release", "version": sdk.version},
        "engine": pieces,
    }) + "\n")

    record = ctx.actions.declare_file(ctx.label.name + "/flutter_sdk.json")
    script = ctx.file._tool
    args = ctx.actions.args()
    args.add(script)
    args.add("--mode=" + mode)
    args.add(engine.binary, format = "--engine-binary=%s")
    if engine.binary_entry:
        args.add("--engine-binary-entry=" + engine.binary_entry)
    args.add("--engine-label=" + engine_label)
    inputs = [script, record_in, engine.binary, kernel.platform_dill, sdk.host_tools.dart_platform_dill, sdk.host_tools.dartaotruntime]
    if mode != "debug":
        if not sdk.gen_snapshot_info:
            fail("%s: the \"%s\" Flutter SDK has no gen_snapshot to check a %s build against." % (ctx.label, sdk.sdk, mode))
        args.add(sdk.gen_snapshot_info.binary, format = "--gen-snapshot=%s")
        args.add("--gen-snapshot-label=" + sdk.slice_labels["gen_snapshot"])
        inputs.append(sdk.gen_snapshot_info.binary)
    args.add(kernel.platform_dill, format = "--engine-platform-dill=%s")
    args.add("--engine-platform-dill-label=" + sdk.slice_labels["platform_kernel"])
    args.add(sdk.host_tools.dart_platform_dill, format = "--dart-platform-dill=%s")
    args.add("--dart-platform-dill-label=" + sdk.slice_labels["host_tools"])
    args.add(sdk.host_tools.dartaotruntime, format = "--dartaotruntime=%s")
    args.add("--dartaotruntime-label=" + sdk.slice_labels["host_tools"])
    if sdk.framework_json:
        args.add(sdk.framework_json, format = "--framework=%s")
        inputs.append(sdk.framework_json)
    args.add(record_in, format = "--record-in=%s")
    args.add(record, format = "--record-out=%s")
    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(inputs, transitive = [tools.sdk_files.run]),
        outputs = [record],
        mnemonic = "FlutterSdkCheck",
        progress_message = "Checking the Flutter SDK \"%s\" for %s" % (sdk.sdk, mode),
        exec_group = "portable",
    )
    return [
        DefaultInfo(files = depset([record])),
        FlutterSdkRecordInfo(
            record = record,
            engine_label = engine_label,
            engine_cpus = engine.cpus,
            engine_xcframework_slices = engine.xcframework_slices,
        ),
    ]

flutter_sdk_record = rule(
    implementation = _flutter_sdk_record_impl,
    attrs = {
        "mode": attr.string(
            doc = "The build mode, which decides what the check compares: `debug` has no gen_snapshot.",
            mandatory = True,
            values = ["debug", "profile", "release"],
        ),
        "always": attr.bool(
            doc = "Record, and so check, the release SDK too. For the test that holds the stock artifacts to the check.",
        ),
        "_tool": attr.label(
            default = "//flutter/private/tools:sdk_check.dart",
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = [_TOOLCHAIN_TYPE],
    doc = "The record of the SDK an app is built with, checked: `flutter_sdk.json`, or nothing for the release.",
)

def _flutter_web_sdk_record_impl(ctx):
    sdk = ctx.toolchains[_TOOLCHAIN_TYPE].flutter_sdk_info
    web = ctx.attr.web_sdk[FlutterWebSdkInfo]
    web_label = str(ctx.attr.web_sdk.label)
    info = FlutterSdkRecordInfo(record = None, engine_label = web_label, engine_cpus = [], engine_xcframework_slices = [])

    # The release's pieces are the official ones and agree by construction.
    custom = sdk.framework_json != None or not is_release_engine(sdk.host_tools) or web.provenance.get("origin") != RELEASE_ORIGIN
    if not custom and not ctx.attr.always:
        return [DefaultInfo(), info]
    if not web.has_canvaskit:
        fail(("%s: the \"%s\" Flutter SDK's web SDK %s has no canvaskit/. A web app of an engine that is not the " +
              "release's loads its renderer from the web SDK, as the CDN has none for it: build the web SDK " +
              "with its renderers (ninja -C out/wasm_release flutter/web_sdk).") % (ctx.label, sdk.sdk, web_label))
    tools = portable_tools(ctx)

    pieces = {
        sdk.slice_labels["host_tools"]: _public(sdk.host_tools.provenance),
        web_label: _public(web.provenance),
    }
    record_in = ctx.actions.declare_file(ctx.label.name + "_in.json")
    ctx.actions.write(record_in, json.encode_indent({
        "sdk": sdk.sdk,
        "framework": {"origin": "release", "version": sdk.version},
        "engine": pieces,
    }) + "\n")

    record = ctx.actions.declare_file(ctx.label.name + "/flutter_sdk.json")
    script = ctx.file._tool
    args = ctx.actions.args()
    args.add(script)
    args.add("--mode=web")
    inputs = [script, record_in, sdk.host_tools.dart_platform_dill]
    for dill, name in [
        (web.dart2js_platform_dill, "dart2js_platform.dill"),
        (web.dart2wasm_platform_dill, "dart2wasm_platform.dill"),
        (web.ddc_outline_dill, "ddc_outline.dill"),
    ]:
        args.add(dill, format = "--web-platform-dill=%s")
        args.add("--web-platform-dill-label=%s:%s" % (web_label, name))
        inputs.append(dill)
    args.add(sdk.host_tools.dart_platform_dill, format = "--dart-platform-dill=%s")
    args.add("--dart-platform-dill-label=" + sdk.slice_labels["host_tools"])
    if sdk.framework_json:
        args.add(sdk.framework_json, format = "--framework=%s")
        inputs.append(sdk.framework_json)
    args.add(record_in, format = "--record-in=%s")
    args.add(record, format = "--record-out=%s")
    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(inputs, transitive = [tools.sdk_files.run]),
        outputs = [record],
        mnemonic = "FlutterSdkCheck",
        progress_message = "Checking the Flutter SDK \"%s\" for web" % sdk.sdk,
        exec_group = "portable",
    )
    return [
        DefaultInfo(files = depset([record])),
        FlutterSdkRecordInfo(record = record, engine_label = web_label, engine_cpus = [], engine_xcframework_slices = []),
    ]

flutter_web_sdk_record = rule(
    implementation = _flutter_web_sdk_record_impl,
    attrs = {
        "web_sdk": attr.label(
            doc = "The web SDK slice of the selected SDK.",
            mandatory = True,
            providers = [FlutterWebSdkInfo],
        ),
        "always": attr.bool(
            doc = "Record, and so check, the release SDK too. For the test that holds the stock artifacts to the check.",
        ),
        "_tool": attr.label(
            default = "//flutter/private/tools:sdk_check.dart",
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = [_TOOLCHAIN_TYPE],
    doc = "The record of the web SDK an app is built with, checked: `flutter_sdk.json`, or nothing for the release.",
)
