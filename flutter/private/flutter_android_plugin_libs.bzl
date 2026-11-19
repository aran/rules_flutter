"""The Android libraries of the plugins an application depends on.

`flutter_android_plugin_libs(deps = [application])` is what `flutter_android_app`
puts on its `android_binary` and its plugin registrant, in place of a library
for every package of the lock. An application's plugins are known only after
analysis has read its dependency graph (`FlutterApplicationInfo.android_libs`),
and a BUILD file cannot name them, so this rule links them: it returns what a
`kt_android_library` listing those libraries in `exports` would, so that
`android_binary` and the registrant compile and package them as ordinary
dependencies.

In an Android configuration it hands those libraries' native libraries over
stripped, as a Gradle build strips every library it packages
(android_strip.bzl): the shared libraries a plugin links, and those of the
Maven AARs the plugins depend on, which `aar_import` takes out as they are.

It also checks the Maven artifacts the linked plugins' Gradle builds declare
against what `@rules_flutter_maven` resolved, for those plugins only: an app
that does not link a plugin never needs its artifacts. And it checks that a
device of the ABI can load the native libraries the plugins bring, prebuilt
ones inside their AARs included: on a 64-bit ABI, that they are aligned for
16 KB pages.

`flutter_android_plugin_native_libs` gives each plugin's own native libraries,
stripped, to the AAR of the plugin.
"""

load("@rules_android//providers:providers.bzl", "AndroidCcLinkParamsInfo", "AndroidLibraryResourceClassJarProvider", "AndroidNativeLibsInfo", "StarlarkAndroidResourcesInfo")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("@rules_java//java/common:proguard_spec_info.bzl", "ProguardSpecInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:android_plugin_maven.bzl", "maven_app_report", "maven_check_message", "maven_warning_message")
load("//flutter/private:android_strip.bzl", "STRIP_ATTRS", "STRIP_EXEC_GROUPS", "android_strip_tool", "run_strip_native_libs", "strip_native_library")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_android_application.bzl", "ANDROID_NATIVE_LIBS_ATTRS", "android_abi", "validate_android_native_libs")
load("//flutter/private:native_libraries.bzl", "plugin_native_libraries")

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

def link_android_libs(libs, strip = None):
    """The providers of a `kt_android_library` that exports `libs`.

    Args:
        libs: List of Targets: Android libraries (`JavaInfo`, and the rest of
            what `android_library` provides).
        strip: None, or a struct of `ctx` (that of a rule with `STRIP_ATTRS`,
            `STRIP_EXEC_GROUPS` and the `cpp` fragment) and `abi` (the Android
            ABI it is built for), to hand the libraries' native libraries over
            stripped (`_strip_aar_libs`, `_strip_linked_libs`).

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
        merged = AndroidNativeLibsInfo(
            native_libs = depset(transitive = [p.native_libs for p in native_libs], order = "preorder"),
        )
        providers.append(_strip_aar_libs(strip.ctx, strip.abi, merged) if strip else merged)

    link_params = _providers_of(libs, AndroidCcLinkParamsInfo)
    if link_params:
        merged = AndroidCcLinkParamsInfo(
            link_params = cc_common.merge_cc_infos(cc_infos = [p.link_params for p in link_params]),
        )
        tool = android_strip_tool(strip.ctx) if strip else None

        # With no C++ toolchain for the platform there is no strip tool, and
        # the libraries an APK links are left as they are: the app's own fail
        # to strip and say so (android_strip.bzl), so the build stops there.
        providers.append(_strip_linked_libs(strip.ctx, strip.abi, tool, merged) if tool else merged)

    proguard = _providers_of(libs, ProguardSpecInfo)
    if proguard:
        providers.append(ProguardSpecInfo(
            specs = depset(transitive = [p.specs for p in proguard], order = "preorder"),
        ))
    return providers

def _is_shared_only(lib):
    """Whether `lib`, a `LibraryToLink`, is a shared library an APK packages as it is."""
    return not lib.static_library and not lib.pic_static_library and lib.dynamic_library

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
        if _is_shared_only(lib)
    ]

def _strip_aar_libs(ctx, abi, info):
    """`info`, an `AndroidNativeLibsInfo`, with each zip of libraries stripped, in one action."""
    zips = info.native_libs.to_list()
    stripped = [
        ctx.actions.declare_file("%s_native_libs/%d/%s" % (ctx.label.name, i, z.basename))
        for i, z in enumerate(zips)
    ]
    run_strip_native_libs(
        ctx,
        inputs = zips,
        libs = stripped,
        mnemonic = "FlutterStripPluginNativeLibs",
        progress_message = "Stripping the %s native libraries of the AARs of %%{label}" % abi,
    )
    return AndroidNativeLibsInfo(native_libs = depset(stripped))

def _strip_linked_libs(ctx, abi, tool, info):
    """`info`, an `AndroidCcLinkParamsInfo`, with each shared library an APK packages as it is stripped.

    The library keeps its name, and so its place in the APK, and links as it
    did: `--strip-unneeded` keeps the dynamic symbol table. A static library
    is linked into the APK's own and is left as it is.
    """
    linker_inputs = []
    count = 0
    for linker_input in info.link_params.linking_context.linker_inputs.to_list():
        libraries = []
        for lib in linker_input.libraries:
            if not _is_shared_only(lib):
                libraries.append(lib)
                continue
            source = lib.resolved_symlink_dynamic_library or lib.dynamic_library
            stripped = ctx.actions.declare_file("%s_stripped/%d/%s" % (ctx.label.name, count, source.basename))
            count += 1
            strip_native_library(
                ctx,
                source,
                stripped,
                mnemonic = "FlutterStripPluginNativeLib",
                progress_message = "Stripping %s %s for %%{label}" % (abi, source.short_path),
            )
            libraries.append(cc_common.create_library_to_link(
                actions = ctx.actions,
                feature_configuration = tool.feature_configuration,
                cc_toolchain = tool.cc_toolchain,
                dynamic_library = stripped,
            ))
        linker_inputs.append(cc_common.create_linker_input(
            owner = linker_input.owner,
            libraries = depset(libraries),
            user_link_flags = linker_input.user_link_flags,
            additional_inputs = depset(linker_input.additional_inputs),
            linkstamps = depset(linker_input.linkstamps),
        ))
    return AndroidCcLinkParamsInfo(link_params = CcInfo(
        linking_context = cc_common.create_linking_context(
            linker_inputs = depset(linker_inputs, order = "topological"),
        ),
    ))

def _native_libs_validation(ctx, abi, libs):
    """The validation of the native libraries `libs` bring, or None.

    Stripping changes no more than a library's symbols and debug info, so the
    libraries are checked as the plugins bring them.
    """
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

    # The libraries an APK packages are those of each ABI's build, so outside
    # an Android configuration there is nothing to strip or check.
    abi = android_abi(ctx)
    providers = link_android_libs(libs, strip = struct(ctx = ctx, abi = abi) if abi else None)
    validation = _native_libs_validation(ctx, abi, libs) if abi else None
    return [
        DefaultInfo(),
        OutputGroupInfo(_validation = depset([validation] if validation else [])),
    ] + providers

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
    } | ANDROID_NATIVE_LIBS_ATTRS | STRIP_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS | STRIP_EXEC_GROUPS,
    fragments = ["cpp"],
    doc = "Links the Android libraries of the plugins an application depends on, as a library exporting them would, with their native libraries stripped, and fails when `@rules_flutter_maven` lacks what their Gradle builds declare.",
)

FlutterAndroidPluginNativeLibsInfo = provider(
    doc = "The native libraries of each plugin of an application, stripped, built for one Android ABI.",
    fields = {
        "libraries": "dict[Label, list[File]]: For the label of each plugin's Android library (`FlutterApplicationInfo.android_libs`), the native libraries that are the plugin's own: the shared libraries its library links, but for those it links through another plugin's Android library, and those of its `native_deps`. Empty outside an Android configuration.",
    },
)

def plugin_android_libraries(label, app_info):
    """The Android library of each plugin of an application that has one, for its AAR.

    A plugin's AAR is one Gradle module, as `flutter build aar` publishes
    each plugin, built from the libraries of the Bazel package of its
    Android library. So a plugin has one Android library among its
    `exports`, which may depend on the others of its package; with two, which
    of them is the module is not known, and the build fails naming them.

    Args:
        label: The label of the rule asking, for the message.
        app_info: The application's `FlutterApplicationInfo`.

    Returns:
        The `FlutterApplicationInfo.android_libs` entries, one for each plugin.
    """
    by_package = {}
    for entry in app_info.android_libs.to_list():
        by_package.setdefault(entry.package, {})[entry.lib.label] = entry
    entries = []
    for package, libs in by_package.items():
        if len(libs) > 1:
            fail((
                "{label}: plugin `{package}` exports {count} Android libraries ({libs}). A plugin's " +
                "AAR is one Gradle module, as `flutter build aar` publishes it: export one Android " +
                "library, which may depend on the others of its package, and its AAR carries them all."
            ).format(
                label = label,
                package = package,
                count = len(libs),
                libs = ", ".join([str(lib) for lib in sorted(libs.keys())]),
            ))
        entries.extend(libs.values())
    return entries

def _flutter_android_plugin_native_libs_impl(ctx):
    abi = android_abi(ctx)
    if not abi:
        return [FlutterAndroidPluginNativeLibsInfo(libraries = {})]
    app_info = ctx.attr.application[FlutterApplicationInfo]
    by_package = {}
    for record in plugin_native_libraries(app_info):
        by_package.setdefault(record.package, []).append(record.library)
    entries = plugin_android_libraries(ctx.label, app_info)

    def shared(lib):
        return android_shared_libraries(lib[AndroidCcLinkParamsInfo]) if AndroidCcLinkParamsInfo in lib else []

    def class_jars(lib):
        return [o.class_jar for o in lib[JavaInfo].java_outputs if o.class_jar] if JavaInfo in lib else []

    # A shared library one plugin's Android library links through another
    # plugin's, one it depends on (Gradle's `api project(":other")`), is that
    # plugin's, and goes in its AAR. Every other is the plugin's own, from
    # whichever Bazel package it is built in.
    shared_by_lib = {entry.lib.label: shared(entry.lib) for entry in entries}
    libraries = {}
    for entry in entries:
        lib = entry.lib
        runtime = {j: None for j in lib[JavaInfo].transitive_runtime_jars.to_list()} if JavaInfo in lib else {}
        through = {
            f: None
            for other in entries
            if other.lib.label != lib.label and [j for j in class_jars(other.lib) if j in runtime]
            for f in shared_by_lib[other.lib.label]
        }
        own = [f for f in shared_by_lib[lib.label] if f not in through]
        stripped = []
        for f in {f: None for f in own + by_package.get(entry.package, [])}.keys():
            out = ctx.actions.declare_file("%s/%s/%s" % (ctx.label.name, entry.package, f.basename))
            strip_native_library(
                ctx,
                f,
                out,
                mnemonic = "FlutterStripPluginNativeLib",
                progress_message = "Stripping %s %s for %%{label}" % (abi, f.short_path),
            )
            stripped.append(out)
        libraries[lib.label] = stripped
    return [FlutterAndroidPluginNativeLibsInfo(libraries = libraries)]

flutter_android_plugin_native_libs = rule(
    implementation = _flutter_android_plugin_native_libs_impl,
    attrs = {
        "application": attr.label(
            doc = "The `flutter_application` whose plugins' native libraries to strip.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
    } | ANDROID_NATIVE_LIBS_ATTRS | STRIP_ATTRS,
    exec_groups = STRIP_EXEC_GROUPS,
    fragments = ["cpp"],
    doc = "The native libraries of each plugin of an application, stripped as a Gradle build strips them, for the plugin's AAR (`flutter_android_plugin_aars`), in the Android configuration it is built in.",
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
