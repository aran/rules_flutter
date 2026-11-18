"""Checks that no two jars an Android app links define one class differently,
and that no Maven library reaches it from two repositories.

`android_binary` puts every jar that reaches it into the app's deploy jar,
the classes it dexes, keeping the first copy of each class. When two jars
define a class differently (two versions of one library, or an old androidx
`-ktx` artifact whose classes moved into the main artifact) the app runs a
mix neither version is. Gradle resolves one version of each library and
aligns companion artifacts through their Gradle module metadata;
rules_jvm_external's resolution reads POMs only and does not. So
`flutter_android_app` puts this check on its `android_binary`: building the app
runs it, and a conflict fails the build naming both jars. Two such jars can
also be harmless (two copies of one interface either of which works, or a
class shadowed on purpose), so `--@rules_flutter//flutter:allow_duplicate_classes`
lets them through, as AGP's `android.enableDuplicateClassesCheck` does.

Each rules_jvm_external repository is a resolution of its own, so a library
(`group:artifact`) that reaches the app from two of them, a target of another
repository where one of `@rules_flutter_maven` belonged, is two copies whose
versions are picked apart. The check fails on that too, naming both targets.
It has no switch: two repositories' copies of one library in one app are
never what Gradle builds, and a target of the other repository can always be
replaced by ours, by its label or, for a module the root does not edit, by a
`maven.override` of that repository.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:android_plugin_maven.bzl", "compare_maven_versions")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:rule_edges.bzl", "rule_attr_targets")

visibility("//flutter/...")

_MavenCoordinatesInfo = provider(
    doc = "The Maven coordinates of the rules_jvm_external targets below a library.",
    fields = {
        "coordinates": "depset of (label string, `group:artifact:version`) tuples.",
    },
)

_TAG = "maven_coordinates="

def _maven_coordinates_aspect_impl(target, ctx):
    own = [
        (str(target.label), tag[len(_TAG):].split("@")[0])
        for tag in getattr(ctx.rule.attr, "tags", [])
        if tag.startswith(_TAG)
    ]
    transitive = [
        dep[_MavenCoordinatesInfo].coordinates
        for dep in rule_attr_targets(ctx.rule.attr, ("deps", "exports", "runtime_deps"))
        if _MavenCoordinatesInfo in dep
    ]
    return [_MavenCoordinatesInfo(coordinates = depset(own, transitive = transitive))]

# rules_jvm_external tags each artifact's target with its coordinates, which a
# jar does not carry.
_maven_coordinates_aspect = aspect(
    implementation = _maven_coordinates_aspect_impl,
    attr_aspects = ["deps", "exports", "runtime_deps"],
)

def _origin(jar, coordinates):
    """What the message calls `jar`: its Maven coordinates, or its target."""
    label = str(jar.owner)
    return coordinates.get(label, label)

# `com.google.guava:listenablefuture` 1.0 as rules_jvm_external imports it.
# `@rules_flutter_maven//:com_google_guava_listenablefuture` is rules_flutter's
# compile-only override of it (MODULE.bazel).
LISTENABLEFUTURE_RUNTIME = Label("@rules_flutter_maven//:original_com_google_guava_listenablefuture")

def _guava_brings_listenablefuture(coordinate):
    """Whether `coordinate` is a Guava that Gradle links without listenablefuture.

    From 27.0, Guava's POM asks for `com.google.guava:listenablefuture` at
    `9999.0-empty-to-avoid-conflict-with-guava`, a jar with no classes, and
    Gradle resolves the highest version asked for: the app's ListenableFuture
    is Guava's own.
    """
    parts = coordinate.split(":")
    if len(parts) < 3 or parts[0] != "com.google.guava" or parts[1] != "guava":
        return False
    return compare_maven_versions(parts[-1], "27.0") >= 0

def _flutter_android_listenablefuture_impl(ctx):
    for lib in ctx.attr.libraries:
        for _, coordinate in lib[_MavenCoordinatesInfo].coordinates.to_list():
            if _guava_brings_listenablefuture(coordinate):
                return [CcInfo()]
    return [java_common.merge([dep[JavaInfo] for dep in ctx.attr.runtime_deps])]

flutter_android_listenablefuture = rule(
    implementation = _flutter_android_listenablefuture_impl,
    attrs = {
        "libraries": attr.label_list(
            doc = "The other Java and Android libraries of the app's `android_binary`.",
            aspects = [_maven_coordinates_aspect],
        ),
        "runtime_deps": attr.label_list(
            doc = "The listenablefuture 1.0 jar, which the app links unless `libraries` link a Guava that brings the interface.",
            default = [LISTENABLEFUTURE_RUNTIME],
            providers = [JavaInfo],
        ),
    },
    doc = """Links `com.google.guava:listenablefuture` 1.0 into an Android app when Gradle would.

`@rules_flutter_maven` resolves the jar for every app of the workspace, and
rules_flutter's override of it there leaves it on the compile classpath only.
Gradle resolves each app on its own: an app that links Guava 27.0 or later gets
the empty `9999.0-empty-to-avoid-conflict-with-guava` placeholder Guava asks
for, and Guava's copy of `ListenableFuture`; any other app gets the 1.0 jar
that androidx asks for. A dependency of the app's `android_binary` that links
the jar in the second case and nothing in the first.""",
)

def _flutter_android_class_check_impl(ctx):
    infos = [lib[JavaInfo] for lib in ctx.attr.libraries if JavaInfo in lib]
    if not infos:
        return [CcInfo()]
    jars = java_common.merge(infos).transitive_runtime_jars
    coordinates = {}
    for lib in ctx.attr.libraries:
        for label, coordinate in lib[_MavenCoordinatesInfo].coordinates.to_list():
            coordinates[label] = coordinate

    stamp = ctx.actions.declare_file(ctx.label.name + ".validated")

    # Every path is an argument, so path mapping can rewrite it; the jars go
    # in a params file, since an app links hundreds.
    tool = ctx.actions.args()
    tool.add(ctx.file._tool)
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--app", ctx.attr.app)
    args.add("--report", ctx.attr.report)
    args.add("--stamp", stamp)
    jar_list = jars.to_list()

    # With duplicate classes allowed, no jar is compared, so none is read.
    compared = depset() if ctx.attr._allow_duplicate_classes[BuildSettingInfo].value else jars
    for jar in compared.to_list():
        args.add("--jar", jar)
        args.add(_origin(jar, coordinates))

    # The Maven libraries those jars are, for the check that each comes from
    # one repository.
    for jar in jar_list:
        owner = str(jar.owner)
        if owner in coordinates:
            args.add("--maven", owner)
            args.add(coordinates[owner])
    tools = portable_tools(ctx)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [tool, args],
        inputs = depset(
            direct = [ctx.file._tool],
            transitive = [compared, tools.sdk_files.run],
        ),
        outputs = [stamp],
        mnemonic = "FlutterCheckAndroidClasses",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Checking the classes %{label} links",
    )

    # A dependency of the app's `android_binary` that links nothing: it is
    # there for the validation, which building the app runs.
    return [
        CcInfo(),
        OutputGroupInfo(_validation = depset([stamp])),
    ]

flutter_android_class_check = rule(
    implementation = _flutter_android_class_check_impl,
    attrs = {
        "app": attr.string(
            doc = "The label of the app, for the message.",
            mandatory = True,
        ),
        "libraries": attr.label_list(
            doc = "The Java and Android libraries of the app's `android_binary`.",
            aspects = [_maven_coordinates_aspect],
        ),
        "report": attr.string(
            doc = "The label of the app's `maven_artifacts` target, which the message points to.",
            mandatory = True,
        ),
        "_allow_duplicate_classes": attr.label(
            default = "//flutter:allow_duplicate_classes",
            providers = [BuildSettingInfo],
        ),
        "_tool": attr.label(
            default = "//flutter/private/tools:check_android_classes.dart",
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Fails the build when two jars an Android app links define one class differently, or one Maven library reaches it from two repositories. A dependency of the app's `android_binary` that links nothing.",
)
