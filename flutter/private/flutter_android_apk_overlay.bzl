"""Post-link APK assembly for `flutter_android_app`.

`android_binary` feeds its `assets` through aapt2 resource linking and its
Java deps through desugaring and the dex/multidex chain. The Flutter payload —
`libapp.so` (or `kernel_blob.bin` inside `flutter_assets/` in debug builds) —
therefore re-runs resource linking (~78.5 G per debug edit at M), the dex
chain and the second resource link on every Dart edit, even though none of
those steps' outputs change.

`flutter_android_app` instead builds its `android_binary` without the Flutter
payload and finishes the APK here, the way the flutter tool adds Flutter files
after resource linking:

1. `apk-overlay` (the `apk-overlay` subcommand of
   `//flutter/private/tools:android_bundle`) splices the payload — the
   bundle's `native_libs.jar` entries plus its `flutter_assets/` tree — into a
   copy of the base unsigned APK, preserving every pre-existing entry
   byte-for-byte. Native libraries are stored uncompressed so `zipalign` can
   page-align them.
2. The Android SDK `zipalign` (`-P 16`, same as `android_binary`) aligns the
   result.
3. The Android SDK `apksigner` signs it with the same keystore and the same
   v1/v2 scheme selection `android_binary` would have used.

A Dart edit then re-runs only the overlay, align and sign steps (~7 G); the
aapt2 link, desugar, dex, shard and merge steps re-run only when Android
resources, the manifest or Java/Kotlin inputs change. The final APK is
identical in entry content, native-library alignment and signature validity to
an `android_binary` that packaged the payload itself (entry order differs:
payload entries come last).
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_android//providers:providers.bzl", "AndroidFeatureFlagSet", "AndroidInstrumentationInfo", "ApkInfo", "StarlarkApkInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:common.bzl", "resolve_exec_dart_vm")

_ANDROID_SDK_TOOLCHAIN_TYPE = Label("@rules_android//toolchains/android_sdk:toolchain_type")
_ANDROID_TOOLCHAIN_TYPE = Label("@rules_android//toolchains/android:toolchain_type")

# The flags' default targets: "unset" is label identity with these, never an
# empty file list, so a flag pointing at an empty or multi-file target fails
# analysis instead of silently falling back to debug signing.
_RELEASE_KEYSTORE_UNSET = Label("//flutter:_android_release_keystore_none")
_RELEASE_KEYSTORE_PASSWORD_FILE_UNSET = Label("//flutter:_android_release_keystore_password_file_none")

def release_execution_requirements(release):
    """Execution requirements for the `ApkSignerTool` action.

    Public (no leading underscore) so the analysis suite can pin it:
    `analysistest` actions expose argv, inputs, env and outputs but not
    execution requirements.

    The release signer reads the keystore and the password files. Under a
    remote executor Bazel would upload those secrets, and under any remote or
    disk cache their digests would land in the shared action cache — an
    offline brute-force oracle for a human-chosen password. Release signing
    therefore always runs locally. The debug keystore is public, so debug
    signing keeps the default requirements.

    Args:
      release: The resolved release-signing struct, or None for debug signing.

    Returns:
      `{"no-remote": "1"}` when the signer reads release secrets, else `{}`.
    """
    if release == None:
        return {}
    return {"no-remote": "1"}

def _single_secret_file(ctx, files, setting, source):
    """Returns the one file a release-signing setting must name, failing closed.

    Args:
      ctx: Rule context, for the label in the error.
      files: The resolved files behind the setting.
      setting: The user-facing name of the setting (attribute or flag).
      source: The label the setting names.

    Returns:
      The single File.
    """
    if len(files) == 1:
        return files[0]
    fail(
        "flutter_android_apk_overlay %s: %s names %s with %s files; " % (ctx.label, setting, source, len(files)) +
        "it must name a target with exactly one file — never an `allow_empty` glob.",
    )

def _resolve_release_keystore(ctx):
    """Resolves the release keystore file, or None to keep debug signing.

    An explicit `keystore` attribute always wins over the flag. The flag
    counts as unset only while it still names its default target.
    """
    if ctx.attr.keystore != None:
        return _single_secret_file(ctx, ctx.files.keystore, "`keystore`", ctx.attr.keystore.label)
    if ctx.attr._release_keystore.label == _RELEASE_KEYSTORE_UNSET:
        return None
    return _single_secret_file(
        ctx,
        ctx.files._release_keystore,
        "`//flutter:android_release_keystore`",
        ctx.attr._release_keystore.label,
    )

def _resolve_release_keystore_password(ctx):
    """Resolves the keystore password file, or None when neither source names one."""
    if ctx.attr.keystore_password_file != None:
        return _single_secret_file(
            ctx,
            ctx.files.keystore_password_file,
            "`keystore_password_file`",
            ctx.attr.keystore_password_file.label,
        )
    if ctx.attr._release_keystore_password_file.label == _RELEASE_KEYSTORE_PASSWORD_FILE_UNSET:
        return None
    return _single_secret_file(
        ctx,
        ctx.files._release_keystore_password_file,
        "`//flutter:android_release_keystore_password_file`",
        ctx.attr._release_keystore_password_file.label,
    )

def _resolve_release_key_password(ctx):
    """Resolves the key password file, or None when the attribute is unset."""
    if ctx.attr.key_password_file == None:
        return None
    return _single_secret_file(
        ctx,
        ctx.files.key_password_file,
        "`key_password_file`",
        ctx.attr.key_password_file.label,
    )

def _overlay_merged_manifest(ctx, base):
    """Recovers the merged manifest from the base binary's deploy-info group.

    ApkInfo carries no merged manifest; the base binary's android_deploy_info
    output group pairs the base deploy_info.pb with the merged manifest (see
    rules_android's apk_packaging).

    Returns:
      A `(merged_manifest, base_groups)` tuple.
    """
    base_groups = base[OutputGroupInfo] if OutputGroupInfo in base else None
    base_deploy_files = []
    if base_groups:
        base_deploy_group = getattr(base_groups, "android_deploy_info", None)
        if type(base_deploy_group) == "depset":
            base_deploy_files = base_deploy_group.to_list()
    merged_manifests = [
        f
        for f in base_deploy_files
        if not f.basename.endswith(".pb")
    ]
    if len(merged_manifests) != 1:
        fail(
            "flutter_android_apk_overlay %s: expected exactly one merged " % ctx.label +
            "manifest in the base android_deploy_info group, got %s" %
            [f.path for f in base_deploy_files],
        )
    return merged_manifests[0], base_groups

def _run_apk_overlay(ctx, dart_exe, dart_vm_files, base_unsigned, native_libs_jar, flutter_assets):
    """Splices the Flutter payload into a copy of the base unsigned APK."""
    overlay_unsigned = ctx.actions.declare_file(ctx.label.name + "_overlay_unsigned.apk")
    overlay_args = ctx.actions.args()
    overlay_args.add(ctx.executable._overlay_tool.path)
    overlay_args.add("apk-overlay")
    overlay_args.add("--base", base_unsigned.path)
    overlay_args.add("--native-libs-jar", native_libs_jar.path)
    overlay_args.add("--flutter-assets", flutter_assets.path)
    overlay_args.add("--output", overlay_unsigned.path)
    if ctx.attr.nocompress_extensions:
        overlay_args.add_joined("--nocompress-extensions", ctx.attr.nocompress_extensions, join_with = ",")
    ctx.actions.run(
        executable = dart_exe,
        arguments = [overlay_args],
        inputs = depset(
            direct = [ctx.executable._overlay_tool, base_unsigned, native_libs_jar, flutter_assets],
            transitive = [dart_vm_files],
        ),
        outputs = [overlay_unsigned],
        mnemonic = "FlutterApkOverlay",
        progress_message = "Injecting Flutter payload into base APK %s" % ctx.label,
    )
    return overlay_unsigned

def _run_zipalign(ctx, sdk, overlay_unsigned):
    """Aligns the overlaid APK, exactly as android_binary does (`-P 16`)."""
    aligned = ctx.actions.declare_file("zipaligned_" + ctx.label.name + ".apk")
    align_args = ctx.actions.args()
    align_args.add("-P", "16")
    align_args.add(str(ctx.attr.zipalign_alignment))
    align_args.add(overlay_unsigned)
    align_args.add(aligned)
    ctx.actions.run(
        executable = sdk.zip_align,
        arguments = [align_args],
        inputs = [overlay_unsigned],
        outputs = [aligned],
        mnemonic = "AndroidZipAlign",
        progress_message = "Zipaligning APK with Flutter payload %s" % ctx.label,
    )
    return aligned

def _overlay_signing_keys(ctx):
    """Collects the debug signing keys, falling back to the debug keystore."""
    signing_keys = list(ctx.files.debug_signing_keys)
    if not signing_keys and ctx.file.debug_key:
        signing_keys.append(ctx.file.debug_key)
    return signing_keys

def _resolve_release_signing(ctx):
    """Resolves the release keystore, or None to keep debug signing.

    An explicit attribute always wins over its `//flutter:android_release_*`
    flag, so a target that names its keystore signs with it while a target
    that names none takes the secret from the command line (or the debug key
    when no flag is set either). "Unset" is label identity with the flag's
    default target — never an empty file list — so a flag pointing at an
    empty or multi-file target fails analysis naming the flag, the label and
    the file count instead of silently debug-signing. A resolved keystore
    without its password file or alias fails, naming the missing attribute.
    """
    keystore = _resolve_release_keystore(ctx)
    if keystore == None:
        return None
    ks_pass = _resolve_release_keystore_password(ctx)
    if ks_pass == None:
        fail(
            "flutter_android_apk_overlay %s: `keystore` is set but " % ctx.label +
            "`keystore_password_file` is not. Set both to sign with a release keystore.",
        )
    alias = ctx.attr.key_alias or ctx.attr._release_key_alias[BuildSettingInfo].value
    if not alias:
        fail(
            "flutter_android_apk_overlay %s: `keystore` is set but " % ctx.label +
            "`key_alias` is not. Set both to sign with a release keystore.",
        )

    # No `key_password_file` means no `--key-pass`: apksigner then unlocks
    # the key with the keystore password. Repeating the keystore password
    # file here would NOT do the same — apksigner consumes one line per
    # password read, so a second read from the same single-line file fails
    # with "end of file reached".
    return struct(
        keystore = keystore,
        ks_pass = ks_pass,
        alias = alias,
        key_pass = _resolve_release_key_password(ctx),
    )

def _release_sign_args(sign_args, release):
    """Adds the caller's keystore to the apksigner arguments.

    Both passwords travel as `file:` references to password-file inputs, so
    their text never appears on the command line. Without a key password
    file `--key-pass` is omitted and apksigner unlocks the key with the
    keystore password.
    """
    sign_args.add("--ks", release.keystore)
    sign_args.add("--ks-key-alias", release.alias)
    sign_args.add("--ks-pass", "file:" + release.ks_pass.path)
    if release.key_pass:
        sign_args.add("--key-pass", "file:" + release.key_pass.path)

def _run_apksign(ctx, sdk, aligned, signing_keys, lineage, rotation_min_sdk, release):
    """Signs the aligned APK with the keystore and scheme android_binary would use.

    `signing` mirrors `@rules_android//flags:apk_signing_method` (wired by
    the macro via select); v4 (fs-verity) stays with android_binary — route
    it there. With `release` set, apksigner signs with the caller's keystore
    instead of the debug keys; without it every argument below is exactly the
    debug invocation.
    """
    signing = ctx.attr.signing
    if signing == "v4":
        fail(
            "flutter_android_apk_overlay %s: apk_signing_method=v4 is not " % ctx.label +
            "supported for apps whose Flutter payload is injected after " +
            "resource linking. Sign the android_binary directly (Tier 2) instead.",
        )
    v1_enabled = signing in ("v1", "v1_v2")
    v2_enabled = signing in ("v2", "v1_v2")

    signed = ctx.actions.declare_file(ctx.label.name + ".apk")
    sign_args = ctx.actions.args()
    sign_args.add("sign")
    sign_args.add("--alignment-preserved", "true")
    if lineage:
        sign_args.add("--lineage", lineage)
    if release:
        _release_sign_args(sign_args, release)
    else:
        for i, key in enumerate(signing_keys):
            if i > 0:
                sign_args.add("--next-signer")
            sign_args.add("--ks", key)
            sign_args.add("--ks-pass", "pass:android")
    sign_args.add("--v1-signing-enabled", v1_enabled)
    sign_args.add("--v1-signer-name", "CERT")
    sign_args.add("--v2-signing-enabled", v2_enabled)

    # L-4: pass --v4-signing-enabled explicitly so apksigner never writes an
    # undeclared .idsig sidecar next to the APK output. V4 stays unsupported
    # (see the fail() above); the value here is always false.
    sign_args.add("--v4-signing-enabled", False)
    if rotation_min_sdk:
        sign_args.add("--rotation-min-sdk-version", rotation_min_sdk)
    sign_args.add("--out", signed)
    sign_args.add(aligned)
    if release:
        sign_inputs = [aligned, release.keystore, release.ks_pass]
        if release.key_pass:
            sign_inputs.append(release.key_pass)
    else:
        sign_inputs = [aligned] + signing_keys
    ctx.actions.run(
        executable = sdk.apk_signer,
        arguments = [sign_args],
        inputs = sign_inputs + ([lineage] if lineage else []),
        outputs = [signed],
        mnemonic = "ApkSignerTool",
        progress_message = "Signing APK with Flutter payload %s" % ctx.label,
        execution_requirements = release_execution_requirements(release),
    )
    return signed

def _run_overlay_deploy_info(ctx, android_toolchain, merged_manifest, signed):
    """Regenerates deploy info against the overlay's own signed APK and manifest.

    Exactly as android_binary's WriteDeployInfo action does (deploy_info_writer
    from the android toolchain, --manifest/--apk/--deploy_info form), so
    mobile-install/deploy tooling sees the APK this rule actually produced.
    """
    deploy_info = ctx.actions.declare_file(ctx.label.name + ".deploy_info.pb")
    ctx.actions.run(
        executable = android_toolchain.deploy_info_writer.files_to_run,
        arguments = [
            "--manifest",
            merged_manifest.path,
            "--apk",
            signed.path,
            "--deploy_info",
            deploy_info.path,
        ],
        inputs = depset(direct = [merged_manifest, signed]),
        outputs = [deploy_info],
        mnemonic = "WriteDeployInfo",
        progress_message = "Writing deploy info for overlay APK %s" % ctx.label,
    )
    return deploy_info

def _overlay_output_groups(base_groups, deploy_info, merged_manifest):
    """Forwards the base output groups, replacing android_deploy_info.

    The fresh group is overlay-owned: the freshly written deploy_info pointing
    at the overlay signed APK, paired with the merged manifest.
    """
    group_kwargs = {}
    if base_groups:
        for name in dir(base_groups):
            if name in ("android_deploy_info", "to_json", "to_proto"):
                continue
            artifacts = getattr(base_groups, name, None)

            # dir() may also surface non-field members; only depsets can be
            # output group values.
            if type(artifacts) == "depset":
                group_kwargs[name] = artifacts
    group_kwargs["android_deploy_info"] = depset([deploy_info, merged_manifest])
    return group_kwargs

def _flutter_android_apk_overlay_impl(ctx):
    base = ctx.attr.binary
    base_apk_info = base[ApkInfo]
    base_unsigned = base_apk_info.unsigned_apk
    sdk = ctx.toolchains[_ANDROID_SDK_TOOLCHAIN_TYPE].android_sdk_info
    android_toolchain = ctx.toolchains[_ANDROID_TOOLCHAIN_TYPE]

    merged_manifest, base_groups = _overlay_merged_manifest(ctx, base)

    native_libs_jar = ctx.file.native_libs_jar
    flutter_assets = ctx.file.flutter_assets

    # 1. Splice the Flutter payload into a copy of the base unsigned APK.
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    overlay_unsigned = _run_apk_overlay(ctx, dart_exe, dart_vm_files, base_unsigned, native_libs_jar, flutter_assets)

    # 2. Align, exactly as android_binary does (`-P 16`, same alignment).
    aligned = _run_zipalign(ctx, sdk, overlay_unsigned)

    # 3. Sign with the same keystore and scheme selection android_binary
    # would have used — or the caller's release keystore when configured.
    signing_keys = _overlay_signing_keys(ctx)
    lineage = ctx.file.debug_signing_lineage_file
    rotation_min_sdk = ctx.attr.key_rotation_min_sdk
    release = _resolve_release_signing(ctx)
    signed = _run_apksign(ctx, sdk, aligned, signing_keys, lineage, rotation_min_sdk, release)

    # 4. Regenerate deploy info against the overlay's own signed APK and
    # merged manifest.
    deploy_info = _run_overlay_deploy_info(ctx, android_toolchain, merged_manifest, signed)

    # Forward the base output groups verbatim EXCEPT android_deploy_info.
    group_kwargs = _overlay_output_groups(base_groups, deploy_info, merged_manifest)

    keystore = release.keystore if release else (signing_keys[0] if signing_keys else None)
    release_signing_keys = [release.keystore] if release else signing_keys
    providers = [
        DefaultInfo(files = depset([signed])),
        ApkInfo(
            signed_apk = signed,
            unsigned_apk = overlay_unsigned,
            deploy_jar = base_apk_info.deploy_jar,
            coverage_metadata = base_apk_info.coverage_metadata,
            signing_keys = release_signing_keys,
            signing_lineage = base_apk_info.signing_lineage,
            signing_min_v3_rotation_api_version = base_apk_info.signing_min_v3_rotation_api_version,
            keystore = keystore,
        ),
        StarlarkApkInfo(
            keystore = keystore,
            signing_keys = release_signing_keys,
            signing_lineage = base_apk_info.signing_lineage,
            signed_apk = signed,
            unsigned_apk = overlay_unsigned,
        ),
        base[JavaInfo],
        OutputGroupInfo(**group_kwargs),
    ]
    if AndroidFeatureFlagSet in base:
        providers.append(base[AndroidFeatureFlagSet])
    if AndroidInstrumentationInfo in base:
        providers.append(base[AndroidInstrumentationInfo])
    return providers

flutter_android_apk_overlay = rule(
    implementation = _flutter_android_apk_overlay_impl,
    attrs = {
        "binary": attr.label(
            doc = "The payload-free android_binary whose unsigned APK is the overlay base.",
            mandatory = True,
            providers = [ApkInfo],
        ),
        "native_libs_jar": attr.label(
            doc = "The bundle's native_libs.jar; its lib/<abi>/*.so entries are stored into the APK.",
            mandatory = True,
            allow_single_file = True,
        ),
        "flutter_assets": attr.label(
            doc = "The bundle's flutter_assets directory; archived as assets/flutter_assets/ in the APK.",
            mandatory = True,
            allow_single_file = True,
        ),
        "signing": attr.string(
            doc = "APK signature schemes, mirroring @rules_android//flags:apk_signing_method. One of v1, v1_v2, v2.",
            default = "v1_v2",
            values = ["v1", "v1_v2", "v2", "v4"],
        ),
        "zipalign_alignment": attr.int(
            doc = "Alignment in bytes, matching android_binary's zipalign_alignment.",
            default = 4,
        ),
        "nocompress_extensions": attr.string_list(
            doc = "Extra asset extensions stored uncompressed in the overlaid APK, " +
                  "on top of the aapt2 defaults, matching android_binary's " +
                  "nocompress_extensions. Matched case-sensitively by suffix.",
        ),
        "debug_key": attr.label(
            doc = "Debug keystore, matching android_binary's debug_key.",
            cfg = "exec",
            default = Label("@rules_android//tools/android:debug_keystore"),
            allow_single_file = True,
        ),
        "debug_signing_keys": attr.label_list(
            doc = "Debug keystores, matching android_binary's debug_signing_keys.",
            allow_files = True,
        ),
        "debug_signing_lineage_file": attr.label(
            doc = "Signing lineage, matching android_binary's debug_signing_lineage_file.",
            allow_single_file = True,
        ),
        "key_rotation_min_sdk": attr.string(
            doc = "Rotation minimum SDK, matching android_binary's key_rotation_min_sdk.",
            default = "",
        ),
        "keystore": attr.label(
            doc = "Release keystore (.jks or PKCS#12 .p12) signing this APK instead of the debug keystore. " +
                  "Needs `keystore_password_file` and `key_alias`; without them analysis fails. " +
                  "Must name a target with exactly one file: an empty or multi-file target fails analysis " +
                  "instead of falling back to debug signing. " +
                  "When unset (with the `//flutter:android_release_keystore` flag unset) the APK signs " +
                  "with the debug keystore exactly as before. An explicit keystore always wins over the flag.",
            allow_files = True,
        ),
        "keystore_password_file": attr.label(
            doc = "File holding the release keystore's password, read by apksigner at execution time " +
                  "through `--ks-pass file:<path>`. Mandatory with `keystore`; the password text never " +
                  "appears on the command line. Only the first line is read; end the file with a newline. " +
                  "Must name a target with exactly one file. " +
                  "Falls back to the `//flutter:android_release_keystore_password_file` flag.",
            allow_files = True,
        ),
        "key_alias": attr.string(
            doc = "Alias of the signing key inside `keystore`. Mandatory with `keystore`. " +
                  "Falls back to the `//flutter:android_release_key_alias` flag.",
            default = "",
        ),
        "key_password_file": attr.label(
            doc = "File holding the signing key's own password, read through `--key-pass file:<path>`. " +
                  "When unset `--key-pass` is omitted and apksigner unlocks the key with the keystore " +
                  "password. Only the first line is read; end the file with a newline. " +
                  "When set it must name a target with exactly one file.",
            allow_files = True,
        ),
        "_release_keystore": attr.label(
            default = Label("//flutter:android_release_keystore"),
            doc = "Release keystore flag (a label_flag BuildSettingInfo).",
        ),
        "_release_keystore_password_file": attr.label(
            default = Label("//flutter:android_release_keystore_password_file"),
            doc = "Release keystore password-file flag (a label_flag BuildSettingInfo).",
        ),
        "_release_key_alias": attr.label(
            default = Label("//flutter:android_release_key_alias"),
            doc = "Release key alias flag (a string BuildSettingInfo).",
        ),
        "_overlay_tool": attr.label(
            default = Label("//flutter/private/tools:android_bundle"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
        "@rules_android//toolchains/android_sdk:toolchain_type",
        "@rules_android//toolchains/android:toolchain_type",
    ],
    doc = """Finishes a payload-free android_binary into a signed APK by injecting the Flutter payload after resource linking.

Takes the base unsigned APK, splices the bundle's native libraries and
flutter_assets into it, then zipaligns and signs with the Android SDK tools —
the same steps android_binary would have run. Created by the
`flutter_android_app` macro; use directly only when assembling an
`android_binary` by hand without the macro.
""",
)
