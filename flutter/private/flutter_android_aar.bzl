"""Add-to-app for Android: a Flutter module as a local Maven repository.

The Bazel counterpart of `flutter build aar`. A native Android app built with
Gradle depends on the module as `<package>:flutter_<mode>:<build number>`, and
the module's POM brings the Flutter engine (`io.flutter:*`, from
`download.flutter.io`, or from the repository itself for an engine that is not
the release's) and one AAR per plugin, with the Maven artifacts each plugin's
Gradle build declares. The coordinates are upstream's, so a host
moves between a Gradle-built module and this one without changing a line.

Three composable rules, each building the mode of the configuration (`-c dbg`
debug, `-c opt --@rules_flutter//flutter:profile` profile, otherwise
release):

* `flutter_android_module_aar`: the module's AAR (`flutter_<mode>`): the
  generated plugin registrant's classes, `flutter_assets`, and
  `jni/<abi>/libapp.so` and the app's other native libraries for every ABI.
* `flutter_android_plugin_aars`: an AAR for each plugin with Android code the
  application depends on (`<plugin>_<mode>`): the plugin's own classes,
  resources, manifest, consumer R8 rules and native libraries.
* `flutter_android_maven_repo`: the repository of both, with a POM for each
  artifact; `bazel run` of it adds the repository to the one on disk.
"""

load("@rules_android//providers:providers.bzl", "AndroidCcLinkParamsInfo", "AndroidNativeLibsInfo", "StarlarkAndroidResourcesInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING", "runfiles_path")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:common.bzl", "ANDROID_ABIS", "ANDROID_EMBEDDING_MAVEN_DEPS", "BUILD_MODE_ATTR", "android_platform_for_abi", "flutter_build_mode")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_android_plugin_libs.bzl", "FlutterAndroidMavenInfo", "android_shared_libraries")
load("//flutter/private:host_platform_transition.bzl", "host_platform_transition")
load("//flutter/private:program_analysis.bzl", "BundledProgramInfo")
load("//flutter/private:rule_edges.bzl", "rule_attr_targets")
load("//flutter/private:sdk_origin.bzl", "is_release_engine")

visibility("//flutter/...")

# `flutter build aar`'s default `--target-platform`: android-arm, android-arm64
# and android-x64.
DEFAULT_AAR_ABIS = ["armeabi-v7a", "arm64-v8a", "x86_64"]

# The name of an ABI in the engine's Maven artifacts: `io.flutter:<name>_<mode>`.
_MAVEN_ABI = {
    "armeabi-v7a": "armeabi_v7a",
    "arm64-v8a": "arm64_v8a",
    "x86_64": "x86_64",
}

_FLUTTER_TOOLCHAIN_TYPE = "@rules_flutter//flutter:toolchain_type"

FlutterAndroidAarInfo = provider(
    doc = "Maven artifacts of one build mode, for `flutter_android_maven_repo` to publish.",
    fields = {
        "mode": "str: The build mode: `debug`, `profile` or `release`.",
        "artifacts": "list[struct]: Each with `group`, `artifact` (with the `_<mode>` suffix), `aar` (File) and `dependencies`: structs of `group`, `artifact`, `version` (None for an artifact of the same repository, which has its build number) and `scope` (`compile` or `runtime`).",
        "package_name": "str or None: The module's Android package, for the module's artifacts; None for plugins'.",
        "engine": "list[struct]: The engine's artifacts the repository carries, each with `group`, `artifact`, `version`, `jar` (File) and `dependencies` (as `artifacts`'): those of an engine that is not the release's, which no Maven repository publishes. Empty for the release's, and for plugins.",
    },
)

# -- Configurations ------------------------------------------------------------

_PLATFORMS = "//command_line_option:platforms"

# What else the configurations of an APK's native code set: rules_android's
# split clears the APK's ABIs and turns off dynamic linking, and so does a
# `flutter_android_bundle`'s.
_ANDROID_PLATFORMS = "//command_line_option:android_platforms"
_STARLARK_ANDROID_PLATFORMS = str(Label("@rules_android//flags:android_platforms"))
_DYNAMIC_MODE = "//command_line_option:dynamic_mode"
_SETTINGS = [_PLATFORMS, _ANDROID_PLATFORMS, _STARLARK_ANDROID_PLATFORMS, _DYNAMIC_MODE]

def _android_settings(abi):
    """The configuration of an Android app's code for `abi`: the one an APK of that ABI builds it in."""
    return {
        _PLATFORMS: [str(android_platform_for_abi(abi))],
        _ANDROID_PLATFORMS: [],
        _STARLARK_ANDROID_PLATFORMS: [],
        _DYNAMIC_MODE: "off",
    }

# The ABI whose configuration compiles what is the same for every ABI: Java
# and Kotlin, and the AAR's one `flutter_assets`.
_COMPILE_ABI = "arm64-v8a"

def _abi_split_impl(_settings, attr):
    return {abi: _android_settings(abi) for abi in [_COMPILE_ABI] + attr.abis}

# One configuration for each ABI of `abis`, and the one of `_COMPILE_ABI`.
_abi_split = transition(
    implementation = _abi_split_impl,
    inputs = [],
    outputs = _SETTINGS,
)

def _classes_impl(_settings, _attr):
    return _android_settings(_COMPILE_ABI)

# The configuration Java and Kotlin are compiled in. Their classes are the same
# for every ABI, so they are compiled once, in the arm64 configuration of
# `_abi_split`.
_classes_transition = transition(
    implementation = _classes_impl,
    inputs = [],
    outputs = _SETTINGS,
)

def _check_abis(label, abis):
    if not abis:
        fail("%s: `abis` is empty; name at least one of %s." % (label, ", ".join(DEFAULT_AAR_ABIS)))
    for abi in abis:
        if abi not in ANDROID_ABIS:
            fail("%s: `abis` names %r; the ABIs are %s." % (label, abi, ", ".join(DEFAULT_AAR_ABIS)))

# -- A library's own classes ---------------------------------------------------

_OwnLibraryInfo = provider(
    doc = "What an Android library compiles itself: what an AAR of it holds, as Gradle's holds what the library's own sources compile to and not its dependencies.",
    fields = {
        "jars": "depset[File]: The class jars of the library and of the libraries of its own Bazel package it depends on and links (not `neverlink`).",
        "proguard": "depset[File]: The `proguard_specs` of the same libraries: the consumer R8 rules of the AAR.",
        "kotlin": "bool: Whether any of them compiles Kotlin, which needs the Kotlin standard library at run time.",
        "libraries": "depset[struct]: For every library reached (`label`, `jars`, `proguard`, `kotlin`, and `java_package`, its `custom_package` or None), to find a plugin's by its label.",
    },
)

# The rules that compile Java or Kotlin, or import a jar, into a library.
# Others in a library's package (a rule that only links libraries, such as
# `flutter_android_plugin_libs`) compile nothing of their own.
_LIBRARY_KINDS = [
    "android_library",
    "java_import",
    "java_library",
    "kt_android_library",
    "kt_jvm_import",
    "kt_jvm_library",
]

def _same_package(a, b):
    return a.repo_name == b.repo_name and a.package == b.package

def _own_library_aspect_impl(target, ctx):
    edges = [
        dep
        for dep in rule_attr_targets(ctx.rule.attr, ("deps", "exports"))
        if _OwnLibraryInfo in dep
    ]
    own = ctx.rule.kind in _LIBRARY_KINDS and not getattr(ctx.rule.attr, "neverlink", False)
    if not own:
        return [_OwnLibraryInfo(
            jars = depset(),
            proguard = depset(),
            kotlin = False,
            libraries = depset(transitive = [d[_OwnLibraryInfo].libraries for d in edges]),
        )]
    same = [d[_OwnLibraryInfo] for d in edges if _same_package(d.label, target.label)]
    jars = depset(
        [o.class_jar for o in target[JavaInfo].java_outputs if o.class_jar] if JavaInfo in target else [],
        transitive = [d.jars for d in same],
    )
    proguard = depset(
        getattr(ctx.rule.files, "proguard_specs", []),
        transitive = [d.proguard for d in same],
    )
    kotlin = any([f.extension == "kt" for f in getattr(ctx.rule.files, "srcs", [])]) or any([d.kotlin for d in same])
    return [_OwnLibraryInfo(
        jars = jars,
        proguard = proguard,
        kotlin = kotlin,
        libraries = depset(
            [struct(
                label = target.label,
                jars = jars,
                proguard = proguard,
                kotlin = kotlin,
                java_package = getattr(ctx.rule.attr, "custom_package", None) or None,
            )],
            transitive = [d[_OwnLibraryInfo].libraries for d in edges],
        ),
    )]

# Follows `deps` and `exports`, as rules_android's dex aspect does from an app
# to the Android libraries of its plugins.
_own_library_aspect = aspect(
    implementation = _own_library_aspect_impl,
    attr_aspects = ["deps", "exports"],
)

# -- Assembling an AAR ---------------------------------------------------------

_AAR_ATTRS = {
    "_tool": attr.label(
        default = "//flutter/private/tools:android_aar.dart",
        allow_single_file = True,
    ),
    "_zip_archive": attr.label(
        default = "//flutter/private/tools:zip_archive.dart",
        allow_single_file = True,
    ),
    "_native_assets_manifests": attr.label(
        default = "//flutter/private/tools:native_assets_manifests.dart",
        allow_single_file = True,
    ),
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
}

def _assemble_aar(ctx, out, args, inputs, what):
    """Runs `android_aar.dart` with `args` (from `_params`), writing `out`."""
    tools = portable_tools(ctx)
    command = ctx.actions.args()
    command.add(ctx.file._tool)
    args.add("--output", out)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [command, args],
        inputs = depset(
            direct = [ctx.file._tool, ctx.file._zip_archive, ctx.file._native_assets_manifests],
            transitive = [inputs, tools.sdk_files.run],
        ),
        outputs = [out],
        mnemonic = "FlutterAndroidAar",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Assembling %s %%{label}" % what,
    )

def _params(ctx):
    """An `Args` the AAR tool reads from its params file."""
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    return args

def _jni_args(args, abi, libs):
    for lib in libs:
        args.add("--jni", abi)
        args.add(lib)

# -- flutter_android_module_aar ------------------------------------------------

def _single(target, group, label):
    files = target[OutputGroupInfo][group].to_list() if group in target[OutputGroupInfo] else []
    if len(files) != 1:
        fail("%s: expected one `%s` from %s, found %s" % (label, group, target.label, files))
    return files[0]

def _engine_artifacts(ctx, mode, version):
    """The Maven artifacts of an engine that is not the release's, for the repository to carry.

    Google publishes the release engine's artifacts, and the module's POM names
    them for the host to fetch. Another engine's are nowhere to fetch from, so
    the repository holds them, as `flutter build aar --local-engine` copies a
    local engine's into its repository: `io.flutter:flutter_embedding_<mode>`,
    the embedding's classes, whose POM names the Maven artifacts the embedding
    needs, and `io.flutter:<abi>_<mode>` for each ABI, a jar of `lib/<abi>/`
    with `libflutter.so`. Both are taken from the engine's `flutter.jar`, its
    libraries stripped as an APK's are; at the engine's version.
    """
    resolved = ctx.attr._maven[FlutterAndroidMavenInfo].data["resolved"]
    embedding_deps = []
    for coordinate in ANDROID_EMBEDDING_MAVEN_DEPS:
        if coordinate not in resolved:
            fail(("%s: the engine's POM names `%s`, which the embedding needs, and " +
                  "@rules_flutter_maven does not resolve it.") % (ctx.label, coordinate))
        group, artifact = coordinate.split(":")
        embedding_deps.append(struct(group = group, artifact = artifact, version = resolved[coordinate], scope = "compile"))

    def engine_of(abi):
        target = ctx.split_attr._engine[abi]
        if AndroidNativeLibsInfo not in target:
            fail("%s: the \"%s\" Flutter SDK's engine is not the release's and %s carries no %s engine for the module's repository." %
                 (ctx.label, ctx.toolchains[_FLUTTER_TOOLCHAIN_TYPE].flutter_sdk_info.sdk, target.label, abi))
        return target

    classes = engine_of(_COMPILE_ABI)[DefaultInfo].files.to_list()
    if len(classes) != 1:
        fail("%s: expected one jar of the engine's classes, found %s" % (ctx.label, classes))
    artifacts = [struct(
        group = "io.flutter",
        artifact = "flutter_embedding_" + mode,
        version = version,
        jar = classes[0],
        dependencies = embedding_deps,
    )]
    for abi in DEFAULT_AAR_ABIS:
        if abi not in ctx.attr.abis:
            continue
        libs = engine_of(abi)[AndroidNativeLibsInfo].native_libs.to_list()
        if len(libs) != 1:
            fail("%s: expected one zip of the %s engine's libraries, found %s" % (ctx.label, abi, libs))
        artifacts.append(struct(
            group = "io.flutter",
            artifact = "%s_%s" % (_MAVEN_ABI[abi], mode),
            version = version,
            jar = libs[0],
            dependencies = [],
        ))
    return artifacts

def _flutter_android_module_aar_impl(ctx):
    _check_abis(ctx.label, ctx.attr.abis)
    mode = flutter_build_mode(ctx)
    sdk = ctx.toolchains[_FLUTTER_TOOLCHAIN_TYPE].flutter_sdk_info

    # The engine's Maven version, as the engine's build writes its POMs.
    version = "1.0.0-" + sdk.engine_revision
    engine = [] if is_release_engine(sdk.host_tools) else _engine_artifacts(ctx, mode, version)

    # What the manifest of upstream's module template (`.android/Flutter/src/
    # main/AndroidManifest.xml`) declares, in every mode: the Dart VM service
    # of a debug build listens on a socket, which needs INTERNET.
    manifest = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")
    ctx.actions.write(manifest, (
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
        "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"\n" +
        "    xmlns:tools=\"http://schemas.android.com/tools\"\n" +
        "    package=\"{package}\">\n\n" +
        "    <uses-sdk android:minSdkVersion=\"{min_sdk}\" />\n\n" +
        "    <uses-permission android:name=\"android.permission.INTERNET\" />\n\n" +
        "    <application tools:node=\"merge\">\n" +
        "        <meta-data\n" +
        "            android:name=\"flutterProjectType\"\n" +
        "            android:value=\"module\" />\n" +
        "        <meta-data\n" +
        "            android:name=\"flutterEmbedding\"\n" +
        "            android:value=\"2\" />\n" +
        "    </application>\n\n" +
        "</manifest>\n"
    ).format(package = ctx.attr.package_name, min_sdk = ctx.attr.min_sdk_version))

    own = ctx.attr.library[0][_OwnLibraryInfo]
    args = _params(ctx)
    args.add("--manifest", manifest)
    args.add_all(own.jars, before_each = "--classes")
    args.add_all(own.proguard, before_each = "--proguard")
    inputs = [manifest]

    # The AAR's `flutter_assets` are those of the configuration that compiles
    # Java, and each ABI's must be the same.
    for abi in [_COMPILE_ABI] + [a for a in ctx.attr.abis if a != _COMPILE_ABI]:
        assets = _single(ctx.split_attr.bundle[abi], "flutter_assets", ctx.label)
        args.add("--flutter-assets", abi)
        args.add_all([assets], expand_directories = False)
        inputs.append(assets)
    for abi in ctx.attr.abis:
        libs = _single(ctx.split_attr.bundle[abi], "native_libs", ctx.label)
        args.add("--jni-zip", abi)
        args.add(libs)
        inputs.append(libs)

    artifact = "flutter_" + mode
    aar = ctx.actions.declare_file("%s/%s.aar" % (ctx.label.name, artifact))
    _assemble_aar(ctx, aar, args, depset(inputs, transitive = [own.jars, own.proguard]), "the Flutter module's AAR")

    dependencies = [struct(group = "io.flutter", artifact = "flutter_embedding_" + mode, version = version, scope = "compile")] + [
        struct(group = "io.flutter", artifact = "%s_%s" % (_MAVEN_ABI[abi], mode), version = version, scope = "compile")
        for abi in DEFAULT_AAR_ABIS
        if abi in ctx.attr.abis
    ]
    return [
        DefaultInfo(files = depset([aar])),
        # The `.symbols` of each ABI's `libapp.so` in `jni/<abi>/`, from the
        # bundle built for that ABI.
        OutputGroupInfo(debug_info = depset(transitive = [
            ctx.split_attr.bundle[abi][BundledProgramInfo].debug_info
            for abi in ctx.attr.abis
        ])),
        FlutterAndroidAarInfo(
            mode = mode,
            package_name = ctx.attr.package_name,
            artifacts = [struct(
                group = ctx.attr.package_name,
                artifact = artifact,
                aar = aar,
                dependencies = dependencies,
            )],
            engine = engine,
        ),
    ]

flutter_android_module_aar = rule(
    implementation = _flutter_android_module_aar_impl,
    doc = """The AAR of a Flutter module, `flutter_<mode>`, as `flutter build aar` assembles it.

It holds `classes.jar` (the classes `library` compiles: the generated
`io.flutter.plugins.GeneratedPluginRegistrant`), an `AndroidManifest.xml`
whose package is `package_name`, `assets/flutter_assets/` and, for each ABI of
`abis`, `jni/<abi>/` with the app's `libapp.so` (profile and release) and its
other native libraries. A debug module's `flutter_assets` hold the kernel and
VM snapshots instead of `libapp.so`. The mode is the configuration's.

The engine is not in it: `FlutterAndroidAarInfo` names the engine's Maven
artifacts for `flutter_android_maven_repo` to list in the POM, as Gradle does.
When the selected SDK's engine is not the release's, whose artifacts no Maven
repository publishes, it also hands over that engine's artifacts for the
repository to carry, as `flutter build aar --local-engine` does: the
embedding's classes and each ABI's `libflutter.so`, from the engine's
`flutter.jar`.""",
    attrs = {
        "bundle": attr.label(
            doc = "The `flutter_android_bundle` of the module's `flutter_application`, built for each ABI of `abis`: its native libraries are the AAR's `jni/<abi>/`. Its `flutter_assets` are the same for every ABI, and the AAR's are those of the arm64 build, in which Java is compiled too.",
            cfg = _abi_split,
            mandatory = True,
        ),
        "library": attr.label(
            doc = "The Android library whose classes `classes.jar` holds: the plugin registrant (`flutter_android_registrant`) compiled by a `kt_android_library`, with a `neverlink` engine. Its own classes and those of the libraries of its package it links, not its dependencies'.",
            cfg = _classes_transition,
            aspects = [_own_library_aspect],
            mandatory = True,
            providers = [JavaInfo],
        ),
        "package_name": attr.string(
            doc = "The module's Android package, as `flutter create --template module` sets `module.androidPackage`: the Maven group of `flutter_<mode>` and the package of its manifest.",
            mandatory = True,
        ),
        "abis": attr.string_list(
            doc = "The ABIs whose native libraries the AAR holds and whose engine its POM names, as `flutter build aar --target-platform`.",
            default = DEFAULT_AAR_ABIS,
        ),
        "min_sdk_version": attr.string(
            doc = "The manifest's `minSdkVersion`.",
            mandatory = True,
        ),
        # The selected SDK's engine for each ABI, stripped, when it is not the
        # release's; nothing when it is.
        "_engine": attr.label(
            default = "//flutter/private:aar_engine",
            cfg = _abi_split,
        ),
        # The versions of the Maven artifacts the engine's POM names.
        "_maven": attr.label(
            default = "@flutter_pub_android_maven//:requirements",
            providers = [FlutterAndroidMavenInfo],
        ),
    } | _AAR_ATTRS | BUILD_MODE_ATTR,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = [_FLUTTER_TOOLCHAIN_TYPE],
)

# -- flutter_android_plugin_aars -----------------------------------------------

def _relative_to(f, marker):
    """The part of `f`'s path after its last `marker` directory, or None."""
    parts = f.short_path.split("/")
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == marker:
            return "/".join(parts[i + 1:])
    return None

def _resources_node(lib):
    if StarlarkAndroidResourcesInfo not in lib:
        return None
    for node in lib[StarlarkAndroidResourcesInfo].direct_resources_nodes.to_list():
        if node.label == lib.label:
            return node
    return None

def _maven_dependencies(label, package, data, kotlin):
    """The POM dependencies of plugin `package`: what its Gradle build declares."""
    resolved = data["resolved"]
    declared = [p for p in data["packages"] if p["package"] == package]
    out = []
    for p in declared:
        for d in p["deps"]:
            if not d["checked"] or d["kind"] == "compile_only":
                continue
            version = d["version"] or resolved.get(d["coordinate"])
            if not version:
                fail(("%s: plugin `%s` declares `%s` (%s) with no version this build knows, " +
                      "and @rules_flutter_maven does not resolve it, so its POM cannot name one.") %
                     (label, package, d["coordinate"], d["line"]))
            group, artifact = d["coordinate"].split(":")[:2]
            out.append(struct(
                group = group,
                artifact = artifact,
                version = version,
                # Gradle publishes `api` at compile scope and `implementation`
                # and `runtimeOnly` at runtime scope.
                scope = "compile" if d.get("configuration") in ("api", "compile") else "runtime",
            ))
    if kotlin:
        # The Kotlin Gradle plugin adds the standard library to a Kotlin
        # library's `api`, so Gradle's POM lists it.
        stdlib = "org.jetbrains.kotlin:kotlin-stdlib"
        if stdlib not in resolved:
            fail(("%s: plugin `%s` is written in Kotlin, and its POM must name the Kotlin standard " +
                  "library at the version the app uses, but @rules_flutter_maven does not resolve " +
                  "`%s`. Add it to the root module's `maven.install(name = \"rules_flutter_maven\")`.") %
                 (label, package, stdlib))
        if stdlib not in [d.group + ":" + d.artifact for d in out]:
            out.append(struct(group = "org.jetbrains.kotlin", artifact = "kotlin-stdlib", version = resolved[stdlib], scope = "compile"))
    return out

def _flutter_android_plugin_aars_impl(ctx):
    _check_abis(ctx.label, ctx.attr.abis)
    mode = flutter_build_mode(ctx)
    app = ctx.attr.application[0]
    data = ctx.attr.maven[FlutterAndroidMavenInfo].data
    own_by_label = {lib.label: lib for lib in app[_OwnLibraryInfo].libraries.to_list()}

    # The plugins' native libraries, from each ABI's build of the application.
    native = {}
    for abi in ctx.attr.abis:
        for entry in ctx.split_attr.application_abis[abi][FlutterApplicationInfo].android_libs.to_list():
            if AndroidCcLinkParamsInfo not in entry.lib:
                continue
            own = [
                f
                for f in android_shared_libraries(entry.lib[AndroidCcLinkParamsInfo])
                if _same_package(f.owner, entry.lib.label)
            ]
            native.setdefault(entry.lib.label, {})[abi] = own

    artifacts = []
    outputs = []
    seen = {}
    for entry in app[FlutterApplicationInfo].android_libs.to_list():
        lib = entry.lib
        if lib.label in seen:
            continue
        seen[lib.label] = True
        package = entry.package
        group = entry.group
        if not group:
            fail(("%s: plugin `%s` has no Maven group to publish its AAR under. Set `group` on its " +
                  "Android `flutter_plugin_platform`, e.g. `group = \"com.example.%s\"`. A plugin " +
                  "from a `flutter_pub` hub takes it from `group` in its android/build.gradle, " +
                  "which this one does not set.") % (ctx.label, package, package))
        own = own_by_label.get(lib.label)
        if own == None:
            fail("%s: no classes found for %s, the Android library of plugin `%s`." % (ctx.label, lib.label, package))

        args = _params(ctx)
        inputs = []
        node = _resources_node(lib)
        if node:
            manifest = node.manifest
            if node.r_txt:
                args.add("--r-txt", node.r_txt)
                inputs.append(node.r_txt)
            resource_files = node.resource_files.to_list()
            assets = node.assets.to_list()
        else:
            # A library with no manifest and no resources has no resources
            # node; an AAR's manifest names the library's package all the same.
            if not own.java_package:
                fail("%s: %s, the Android library of plugin `%s`, has no manifest and no `custom_package` to write one for." % (ctx.label, lib.label, package))
            manifest = ctx.actions.declare_file("%s/%s/AndroidManifest.xml" % (ctx.label.name, package))
            ctx.actions.write(manifest, (
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"\n" +
                "    package=\"%s\">\n</manifest>\n"
            ) % own.java_package)
            resource_files = []
            assets = []
        args.add("--manifest", manifest)
        inputs.append(manifest)
        for f in resource_files:
            relative = _relative_to(f, "res")
            if relative == None:
                fail("%s: resource %s of plugin `%s` is not under a `res` directory." % (ctx.label, f.short_path, package))
            args.add("--entry", "res/" + relative)
            args.add(f)
            inputs.append(f)
        for f in assets:
            relative = f.path.removeprefix(node.assets_dir + "/")
            if relative == f.path:
                fail("%s: asset %s of plugin `%s` is not under its assets directory %s." % (ctx.label, f.path, package, node.assets_dir))
            args.add("--entry", "assets/" + relative)
            args.add(f)
            inputs.append(f)
        args.add_all(own.jars, before_each = "--classes")
        args.add_all(own.proguard, before_each = "--proguard")
        for abi in ctx.attr.abis:
            libs = native.get(lib.label, {}).get(abi, [])
            _jni_args(args, abi, libs)
            inputs.extend(libs)

        artifact = "%s_%s" % (package, mode)
        aar = ctx.actions.declare_file("%s/%s.aar" % (ctx.label.name, artifact))
        _assemble_aar(ctx, aar, args, depset(inputs, transitive = [own.jars, own.proguard]), "the AAR of plugin " + package)
        outputs.append(aar)
        artifacts.append(struct(
            group = group,
            artifact = artifact,
            aar = aar,
            dependencies = _maven_dependencies(ctx.label, package, data, own.kotlin),
        ))
    return [
        DefaultInfo(files = depset(outputs)),
        FlutterAndroidAarInfo(mode = mode, artifacts = artifacts, package_name = None, engine = []),
    ]

_flutter_android_plugin_aars = rule(
    implementation = _flutter_android_plugin_aars_impl,
    attrs = {
        "application": attr.label(
            doc = "The `flutter_application` whose plugins to publish: those it depends on that have Android code.",
            cfg = _classes_transition,
            aspects = [_own_library_aspect],
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "application_abis": attr.label(
            doc = "`application` again, built for each ABI of `abis`, for the plugins' native libraries.",
            cfg = _abi_split,
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "abis": attr.string_list(
            doc = "The ABIs whose native libraries the AARs hold.",
            default = DEFAULT_AAR_ABIS,
        ),
        "maven": attr.label(
            doc = "The build's Android Maven requirements: the artifacts each plugin's Gradle build declares.",
            mandatory = True,
            providers = [FlutterAndroidMavenInfo],
        ),
    } | _AAR_ATTRS | BUILD_MODE_ATTR,
    exec_groups = PORTABLE_EXEC_GROUPS,
)

def flutter_android_plugin_aars(
        name,
        application,
        abis = DEFAULT_AAR_ABIS,
        maven = Label("@flutter_pub_android_maven//:requirements"),
        **kwargs):
    """An AAR for each plugin with Android code that `application` depends on.

    `<plugin>_<mode>`, as `flutter build aar` publishes each plugin of a
    module: the classes the plugin's library compiles itself (with its
    generated `BuildConfig`, not its dependencies'), its resources, `R.txt`,
    manifest, consumer R8 rules (`proguard_specs`), and the shared libraries
    of its own package under `jni/<abi>/`. Each is published under the `group`
    of the plugin's Android `flutter_plugin_platform` (a pub plugin's is the
    group its `android/build.gradle` sets), and its POM lists the Maven
    artifacts a pub plugin's Gradle build declares (and the Kotlin standard
    library, for a plugin in Kotlin). A plugin with no group fails the build,
    naming it.

    Args:
        name: Target name.
        application: The `flutter_application`.
        abis: The ABIs whose native libraries the AARs hold.
        maven: The build's Android Maven requirements. The default, every
            pub hub's, is what a build with `flutter_pub` hubs uses.
        **kwargs: Common attributes (`tags`, `visibility`, `testonly`).
    """
    _flutter_android_plugin_aars(
        name = name,
        application = application,
        application_abis = application,
        abis = abis,
        maven = maven,
        **kwargs
    )

# -- flutter_android_maven_repo ------------------------------------------------

def _check_build_number(label, build_number):
    if not build_number or "/" in build_number or "\\" in build_number or build_number.startswith(".") or " " in build_number:
        fail("%s: `build_number` %r is not a Maven version: give one like `1.0`." % (label, build_number))

def _flutter_android_maven_repo_impl(ctx):
    _check_build_number(ctx.label, ctx.attr.build_number)
    module = ctx.attr.module[FlutterAndroidAarInfo]
    if not module.package_name:
        fail("%s: `module` %s is not a `flutter_android_module_aar`." % (ctx.label, ctx.attr.module.label))
    plugins = ctx.attr.plugins[FlutterAndroidAarInfo] if ctx.attr.plugins else FlutterAndroidAarInfo(mode = module.mode, artifacts = [], package_name = None, engine = [])
    if plugins.mode != module.mode:
        fail("%s: the module is built in %s mode and the plugins in %s mode." % (ctx.label, module.mode, plugins.mode))

    version = ctx.attr.build_number
    plugin_dependencies = [
        struct(group = a.group, artifact = a.artifact, version = None, scope = "compile")
        for a in plugins.artifacts
    ]

    # Every artifact the repository holds: the module's and the plugins' AARs
    # at the build number, and a custom engine's jars at the engine's version.
    artifacts = [
        struct(
            group = a.group,
            artifact = a.artifact,
            version = version,
            packaging = "aar",
            file = a.aar,
            dependencies = a.dependencies + plugin_dependencies,
        )
        for a in module.artifacts
    ] + [
        struct(
            group = a.group,
            artifact = a.artifact,
            version = version,
            packaging = "aar",
            file = a.aar,
            dependencies = a.dependencies,
        )
        for a in plugins.artifacts
    ] + [
        struct(
            group = a.group,
            artifact = a.artifact,
            version = a.version,
            packaging = "jar",
            file = a.jar,
            dependencies = a.dependencies,
        )
        for a in module.engine
    ]

    coordinates = {}
    for a in artifacts:
        key = a.group + ":" + a.artifact
        if key in coordinates:
            fail("%s: two artifacts are %s." % (ctx.label, key))
        coordinates[key] = True

    spec = ctx.actions.declare_file(ctx.label.name + ".maven_repo.json")
    ctx.actions.write(spec, json.encode_indent({"artifacts": [
        {
            "group": a.group,
            "artifact": a.artifact,
            "version": a.version,
            "packaging": a.packaging,
            "dependencies": [
                {
                    "group": d.group,
                    "artifact": d.artifact,
                    "version": d.version or version,
                    "scope": d.scope,
                }
                for d in a.dependencies
            ],
        }
        for a in artifacts
    ]}))

    repo = ctx.actions.declare_directory(ctx.label.name + "_repo")
    tools = portable_tools(ctx)
    args = ctx.actions.args()
    args.add(ctx.file._repo_tool)
    args.add("--spec", spec)
    args.add("--output", repo.path)
    args.add_all([a.file for a in artifacts], before_each = "--file")
    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(
            [ctx.file._repo_tool, ctx.file._maven_repo, spec] + [a.file for a in artifacts],
            transitive = [tools.sdk_files.run],
        ),
        outputs = [repo],
        mnemonic = "FlutterAndroidMavenRepo",
        exec_group = PORTABLE,
        progress_message = "Laying out the Maven repository %{label}",
    )

    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    workspace = ctx.workspace_name
    config = ctx.actions.declare_file(ctx.label.name + ".android_aar.json")
    ctx.actions.write(config, json.encode_indent({
        "artifacts": [{"group": a.group, "artifact": a.artifact, "version": a.version} for a in artifacts],
        "buildNumber": version,
        "label": "//%s:%s" % (ctx.label.package, ctx.label.name) if not ctx.label.repo_name else str(ctx.label),
        "mode": module.mode,
        "package": ctx.label.package,
        "packageName": module.package_name,
        "repo": runfiles_path(repo, workspace),
    }))
    tool = ctx.attr._install
    executable = ctx.actions.declare_file(ctx.label.name + (".exe" if is_windows else ""))
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [config, repo]).merge(tool[DefaultInfo].default_runfiles)
    groups = ctx.attr.module[OutputGroupInfo]
    return [
        DefaultInfo(files = depset([repo]), executable = executable, runfiles = runfiles),
        OutputGroupInfo(debug_info = groups.debug_info if "debug_info" in groups else depset()),
        RunEnvironmentInfo(environment = {
            "RULES_FLUTTER_ANDROID_AAR_CONFIG": runfiles_path(config, workspace),
        }),
    ]

flutter_android_maven_repo = rule(
    implementation = _flutter_android_maven_repo_impl,
    executable = True,
    # `bazel run` starts the program on this machine.
    cfg = host_platform_transition,
    doc = """A local Maven repository of a Flutter module and its plugins, as `flutter build aar` writes one.

`bazel build` of it makes the repository of the configuration's mode, a
directory (`<name>_repo`) laid out as Gradle's `maven-publish` lays one out:

    <package as path>/flutter_<mode>/<build_number>/flutter_<mode>-<build_number>.{aar,pom}
    <plugin group as path>/<plugin>_<mode>/<build_number>/<plugin>_<mode>-<build_number>.{aar,pom}

with a `.sha1` and `.md5` beside each file. The module's POM depends on the
engine's artifacts (`io.flutter:flutter_embedding_<mode>` and
`io.flutter:<abi>_<mode>`, version `1.0.0-<engine revision>`, from
`https://storage.googleapis.com/download.flutter.io`) and on every plugin's;
each plugin's lists the Maven artifacts its Gradle build declares. When the
selected SDK's engine is not the release's, the repository holds that
engine's artifacts too, as `flutter build aar --local-engine` copies a local
engine's in, since Google publishes only the release's:

    io/flutter/flutter_embedding_<mode>/1.0.0-<engine revision>/flutter_embedding_<mode>-1.0.0-<engine revision>.{jar,pom}
    io/flutter/<abi>_<mode>/1.0.0-<engine revision>/<abi>_<mode>-1.0.0-<engine revision>.{jar,pom}

The first is the embedding's classes, its POM naming the AndroidX artifacts
the embedding needs; each of the others holds `lib/<abi>/libflutter.so`,
stripped. There are no Gradle `.module` files and no sources or javadoc jars. Its `debug_info`
output group is the module's: the `.symbols` of each ABI's `libapp.so` with
`--@rules_dart//dart:split_debug_info`.

`bazel run` of it writes the repository to `build/host/outputs/repo/` under
the package (or `-- --output=<dir>`), where `flutter build aar` writes it,
keeping the artifacts of other modes and build numbers earlier runs wrote
there and recording each in the artifact's `maven-metadata.xml`. It then
prints the host app's steps, as `flutter build aar` does. Run it once per
mode the host needs:

    bazel run -c dbg //:module_aar
    bazel run -c opt --@rules_flutter//flutter:profile //:module_aar
    bazel run -c opt //:module_aar""",
    attrs = {
        "module": attr.label(
            doc = "The module's `flutter_android_module_aar`.",
            mandatory = True,
            providers = [FlutterAndroidAarInfo],
        ),
        "plugins": attr.label(
            doc = "The plugins' `flutter_android_plugin_aars`, which the module's POM depends on.",
            providers = [FlutterAndroidAarInfo],
        ),
        "build_number": attr.string(
            doc = "The version of every artifact, as `flutter build aar --build-number`.",
            default = "1.0",
        ),
        "_repo_tool": attr.label(
            default = "//flutter/private/tools:android_maven_repo.dart",
            allow_single_file = True,
        ),
        "_maven_repo": attr.label(
            default = "//flutter/private/tools:maven_repo.dart",
            allow_single_file = True,
        ),
        "_install": attr.label(
            default = Label("//flutter/private/tools:android_aar_install"),
            executable = True,
            cfg = "target",
        ),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
)
