"""The Android libraries of the plugins an application depends on.

`flutter_android_plugin_libs(deps = [application])` is what `flutter_android_app`
puts on its `android_binary` and its plugin registrant, in place of a library
for every package of the lock. An application's plugins are known only after
analysis has read its dependency graph (`FlutterApplicationInfo.android_libs`),
and a BUILD file cannot name them, so this rule links them: it returns what a
`kt_android_library` listing those libraries in `exports` would, so that
`android_binary` and the registrant compile and package them as ordinary
dependencies.

It also checks the Maven artifacts the linked plugins' Gradle builds declare
against what `@rules_flutter_maven` resolved, for those plugins only: an app
that does not link a plugin never needs its artifacts. And it checks that a
device of the ABI can load the native libraries the plugins bring, prebuilt
ones inside their AARs included: on a 64-bit ABI, that they are aligned for
16 KB pages.
"""

load("@rules_android//providers:providers.bzl", "AndroidCcLinkParamsInfo", "AndroidLibraryResourceClassJarProvider", "AndroidNativeLibsInfo", "StarlarkAndroidResourcesInfo")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("@rules_java//java/common:proguard_spec_info.bzl", "ProguardSpecInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:android_plugin_maven.bzl", "maven_app_report", "maven_check_message", "maven_warning_message")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_android_application.bzl", "ANDROID_NATIVE_LIBS_ATTRS", "android_abi", "validate_android_native_libs")

visibility("//flutter/...")

FlutterAndroidMavenInfo = provider(
    doc = "What a pub hub's Android plugins declare in their Gradle builds, and what `@rules_flutter_maven` resolved.",
    fields = {
        "data": "dict: `resolved` (dict of `group:artifact` to version), `boms` (the install's BoMs, likewise), `locked` (whether the install has a lock file), `listed` (the artifacts its `artifacts` list), `repositories` (the install's Maven repositories) and `packages` (list of dicts with `package`, `version`, `script`, `deps`, `boms`, `unread` and `annotated`), as `maven_check_message` reads it.",
    },
)

def _flutter_android_maven_requirements_impl(ctx):
    return [FlutterAndroidMavenInfo(data = json.decode(ctx.attr.data))]

flutter_android_maven_requirements = rule(
    implementation = _flutter_android_maven_requirements_impl,
    attrs = {
        "data": attr.string(
            doc = "The JSON the pub hub's Android Maven repository writes.",
            mandatory = True,
        ),
    },
    doc = "Carries a pub hub's Android Maven requirements to the `flutter_android_plugin_libs` that checks them.",
)

def _merge_resources(infos):
    """One `StarlarkAndroidResourcesInfo` for all of `infos`.

    As rules_android merges the resources of a library's `exports`: every
    depset is the union of the inputs', and the R.txt files of one Java package
    stay together. The merged target defines no resources of its own, so it
    names no package.
    """
    packages = {}
    for info in infos:
        for package, r_txts in info.packages_to_r_txts.items():
            packages.setdefault(package, []).append(r_txts)

    def union(field):
        return depset(
            transitive = [getattr(info, field) for info in infos],
            order = "preorder",
        )

    return StarlarkAndroidResourcesInfo(
        direct_resources_nodes = union("direct_resources_nodes"),
        transitive_resources_nodes = union("transitive_resources_nodes"),
        transitive_assets = union("transitive_assets"),
        transitive_assets_symbols = union("transitive_assets_symbols"),
        transitive_compiled_assets = union("transitive_compiled_assets"),
        direct_compiled_resources = union("direct_compiled_resources"),
        transitive_compiled_resources = union("transitive_compiled_resources"),
        transitive_compiled_resources_with_public_xml = union("transitive_compiled_resources_with_public_xml"),
        transitive_manifests = union("transitive_manifests"),
        transitive_r_txts = union("transitive_r_txts"),
        transitive_resource_files = union("transitive_resource_files"),
        packages_to_r_txts = {
            package: depset(transitive = r_txts, order = "preorder")
            for package, r_txts in packages.items()
        },
        transitive_resource_apks = union("transitive_resource_apks"),
        package = "",
    )

def _providers_of(libs, provider_type):
    return [lib[provider_type] for lib in libs if provider_type in lib]

def link_android_libs(libs):
    """The providers of a `kt_android_library` that exports `libs`.

    Args:
        libs: List of Targets: Android libraries (`JavaInfo`, and the rest of
            what `android_library` provides).

    Returns:
        A list of providers: `JavaInfo`, and for each of the others a library
        provides, the merge of the libraries'. For no libraries, an empty
        `JavaInfo`: a library that exports nothing is still a library.
    """
    providers = [java_common.merge([lib[JavaInfo] for lib in libs])]

    resources = _providers_of(libs, StarlarkAndroidResourcesInfo)
    if resources:
        providers.append(_merge_resources(resources))

    jars = _providers_of(libs, AndroidLibraryResourceClassJarProvider)
    if jars:
        providers.append(AndroidLibraryResourceClassJarProvider(
            jars = depset(transitive = [p.jars for p in jars], order = "preorder"),
        ))

    native_libs = _providers_of(libs, AndroidNativeLibsInfo)
    if native_libs:
        providers.append(AndroidNativeLibsInfo(
            native_libs = depset(transitive = [p.native_libs for p in native_libs], order = "preorder"),
        ))

    link_params = _providers_of(libs, AndroidCcLinkParamsInfo)
    if link_params:
        providers.append(AndroidCcLinkParamsInfo(
            link_params = cc_common.merge_cc_infos(cc_infos = [p.link_params for p in link_params]),
        ))

    proguard = _providers_of(libs, ProguardSpecInfo)
    if proguard:
        providers.append(ProguardSpecInfo(
            specs = depset(transitive = [p.specs for p in proguard], order = "preorder"),
        ))
    return providers

def android_shared_libraries(link_params):
    """The shared libraries an `AndroidCcLinkParamsInfo` brings the APK.

    Args:
        link_params: An `AndroidCcLinkParamsInfo`.

    Returns:
        A list of Files: the dynamic libraries of its linker inputs that have no
        static library, which an APK packages as they are.
    """
    return [
        lib.resolved_symlink_dynamic_library or lib.dynamic_library
        for linker_input in link_params.link_params.linking_context.linker_inputs.to_list()
        for lib in linker_input.libraries
        if not lib.static_library and not lib.pic_static_library and lib.dynamic_library
    ]

def _native_libs_validation(ctx, libs):
    """The validation of the native libraries `libs` bring, or None.

    The libraries an APK packages are those of each ABI's build, so outside an
    Android configuration there is nothing to check.
    """
    abi = android_abi(ctx)
    if not abi:
        return None
    native = []
    for lib in libs:
        if AndroidNativeLibsInfo in lib:
            native.extend(lib[AndroidNativeLibsInfo].native_libs.to_list())
        if AndroidCcLinkParamsInfo in lib:
            native.extend(android_shared_libraries(lib[AndroidCcLinkParamsInfo]))
    native = {f: None for f in native}.keys()
    if not native:
        return None
    return validate_android_native_libs(
        ctx,
        portable_tools(ctx),
        abi,
        native,
        ctx.label.name + "_native_libs.validated",
    )

def _flutter_android_plugin_libs_impl(ctx):
    if len(ctx.attr.deps) != 1:
        fail("`deps` of %s lists %d targets; it takes one `flutter_application`, the app whose plugins to link" % (ctx.label, len(ctx.attr.deps)))
    application = ctx.attr.deps[0]
    entries = application[FlutterApplicationInfo].android_libs.to_list()
    if ctx.attr.maven:
        data = ctx.attr.maven[FlutterAndroidMavenInfo].data
        linked = {entry.package: True for entry in entries}
        message = maven_check_message(data, linked, ctx.attr.report or None)
        if message:
            fail(message)

        # Gradle lines the reader did not check: a reader of Gradle's language
        # that is not Gradle can be wrong about them, so they warn.
        app = application.label
        warning = maven_warning_message(
            data,
            linked,
            str(app) if app.repo_name else "//%s:%s" % (app.package, app.name),
        )
        if warning:
            # buildifier: disable=print
            print("WARNING: " + warning)

    libs = []
    for entry in entries:
        if entry.lib not in libs:
            libs.append(entry.lib)
    validation = _native_libs_validation(ctx, libs)
    return [
        DefaultInfo(),
        OutputGroupInfo(_validation = depset([validation] if validation else [])),
    ] + link_android_libs(libs)

flutter_android_plugin_libs = rule(
    implementation = _flutter_android_plugin_libs_impl,
    attrs = {
        "deps": attr.label_list(
            doc = "The `flutter_application` whose plugins' Android libraries to link, as a list of one: those of the plugins it depends on, and no others. A list named `deps`, as everywhere in Bazel, so that rules_android's aspects walk it as they walk any library's: the dex aspect, which follows `deps`, `exports` and `runtime_deps`, goes from here through the application's `deps` and each library's `exports` to the plugins' Android libraries and dexes them one at a time, and `bazel mobile-install`'s aspect iterates it.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "maven": attr.label(
            doc = "The build's Android Maven requirements (any hub's `//android:maven_requirements`), to check those of the linked plugins against `@rules_flutter_maven`. Leave unset when no linked plugin comes from `flutter_pub.from_lock`.",
            providers = [FlutterAndroidMavenInfo],
        ),
        "report": attr.string(
            doc = "The label of the application's `maven_artifacts` target, which a failure message points to in place of the hub's.",
        ),
    } | ANDROID_NATIVE_LIBS_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Links the Android libraries of the plugins an application depends on, as a library exporting them would, and fails when `@rules_flutter_maven` lacks what their Gradle builds declare.",
)

# A plugin's Android library is among an application's `android_libs` only in
# an Android configuration, so the report reads the application as one. The
# plugins are the same for every ABI.
def _android_transition_impl(_settings, _attr):
    return {"//command_line_option:platforms": [str(Label("@rules_android//:arm64-v8a"))]}

_android_transition = transition(
    implementation = _android_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _flutter_android_maven_report_impl(ctx):
    # A target reached through a transition on `platforms` arrives as a list
    # of one.
    entries = ctx.attr.application[0][FlutterApplicationInfo].android_libs.to_list()
    out = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(out, maven_app_report(
        ctx.attr.maven[FlutterAndroidMavenInfo].data,
        {entry.package: True for entry in entries},
        ctx.attr.app_label,
    ))
    return [DefaultInfo(files = depset([out]))]

flutter_android_maven_report = rule(
    implementation = _flutter_android_maven_report_impl,
    attrs = {
        "application": attr.label(
            doc = "The `flutter_application` whose plugins to report on, built for Android.",
            cfg = _android_transition,
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "maven": attr.label(
            doc = "The build's Android Maven requirements (any hub's `//android:maven_requirements`).",
            mandatory = True,
            providers = [FlutterAndroidMavenInfo],
        ),
        "app_label": attr.string(
            doc = "How the report's header names the application.",
            mandatory = True,
        ),
    },
    doc = "Writes what the `maven_artifacts` program of an application reads: the Maven artifacts the plugins it links declare, and what `@rules_flutter_maven` resolves. Unlike `flutter_android_plugin_libs` it never fails for what is missing: it is how to find out.",
)
