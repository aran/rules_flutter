"""One Gradle model for a plugin's Android build.

The model is split into cohesive modules; this file is the facade every
consumer loads:

- `gradle_lex.bzl`: the Groovy / Kotlin-DSL lexer;
- `gradle_parse.bzl`: statement-level parsers (`add()`, `apply from:`);
- `gradle_model.bzl`: code/literal segments and the `apply from:`
  script collector every reader folds;
- `gradle_deps.bzl`: the Maven dependency reader;
- `gradle_readers.bzl`: the namespace, native-build and ProGuard
  readers;
- `gradle_plugin.bzl`: the spoke-level resolvers (Maven deps, manifest
  package, label validation).

`flutter_pub_package.bzl` loads this file and re-exports the
long-standing entry points (`maven_labels_for_gradle`,
`parse_gradle_android_namespace`).
"""

load(
    ":gradle_deps.bzl",
    _facade_maven_labels_for_gradle = "maven_labels_for_gradle",
)
load(
    ":gradle_model.bzl",
    _facade_gradle_collect_files = "gradle_collect_files",
)
load(
    ":gradle_plugin.bzl",
    _facade_is_java_package_name = "is_java_package_name",
    _facade_is_maven_dep_label = "is_maven_dep_label",
    _facade_parse_android_manifest_package = "parse_android_manifest_package",
    _facade_resolve_plugin_maven_deps = "resolve_plugin_maven_deps",
)
load(
    ":gradle_readers.bzl",
    _facade_detect_android_namespace = "detect_android_namespace",
    _facade_detect_android_native_build = "detect_android_native_build",
    _facade_detect_consumer_proguard_specs = "detect_consumer_proguard_specs",
    _facade_gradle_android_namespaces = "gradle_android_namespaces",
    _facade_gradle_scan_namespaces = "gradle_scan_namespaces",
    _facade_gradle_scan_native = "gradle_scan_native",
    _facade_gradle_scan_proguard = "gradle_scan_proguard",
    _facade_parse_gradle_android_namespace = "parse_gradle_android_namespace",
)

maven_labels_for_gradle = _facade_maven_labels_for_gradle
gradle_collect_files = _facade_gradle_collect_files
detect_android_namespace = _facade_detect_android_namespace
detect_android_native_build = _facade_detect_android_native_build
detect_consumer_proguard_specs = _facade_detect_consumer_proguard_specs
gradle_android_namespaces = _facade_gradle_android_namespaces
gradle_scan_namespaces = _facade_gradle_scan_namespaces
gradle_scan_native = _facade_gradle_scan_native
gradle_scan_proguard = _facade_gradle_scan_proguard
is_java_package_name = _facade_is_java_package_name
is_maven_dep_label = _facade_is_maven_dep_label
parse_android_manifest_package = _facade_parse_android_manifest_package
parse_gradle_android_namespace = _facade_parse_gradle_android_namespace
resolve_plugin_maven_deps = _facade_resolve_plugin_maven_deps

def gradle_build_file_choice(has_gradle, has_kts):
    """Name the plugin Android build file Gradle would evaluate.

    Gradle builds each project from a single build script (Gradle User
    Manual, Writing Build Scripts): `build.gradle` and
    `build.gradle.kts` are alternatives, never merged. When both files are
    present the Groovy `build.gradle` wins — verified against Gradle
    8.10.0, where a probe project carrying both files evaluated the
    Groovy build and ignored the Kotlin one (the `whoGroovy` task ran,
    the `whoKts` task did not exist).

    Args:
        has_gradle: True when `android/build.gradle` exists.
        has_kts: True when `android/build.gradle.kts` exists.

    Returns:
        The chosen spoke-relative path, or "" when neither file exists.
    """
    if has_gradle:
        return "android/build.gradle"
    if has_kts:
        return "android/build.gradle.kts"
    return ""

def plugin_android_build(ctx):
    """Read the spoke's single Android Gradle build file.

    Makes the one Gradle-consistent choice (see
    `gradle_build_file_choice`) and returns `struct(path, content)`: the
    spoke-relative path and its text, or `("", "")` when the plugin ships
    neither file. Every reader of the plugin's Android build —
    dependencies, namespace, native-build and ProGuard detection — shares
    this one result, so the spoke can never merge `build.gradle`'s
    namespace with `build.gradle.kts`'s dependencies the way Gradle never
    does.

    Args:
        ctx: the spoke repository context (path, exists and read).

    Returns:
        `struct(path, content)`: the spoke-relative path and its text,
        or `("", "")` when the plugin ships neither file.
    """
    gradle_path = ctx.path("android/build.gradle")
    kts_path = ctx.path("android/build.gradle.kts")
    choice = gradle_build_file_choice(gradle_path.exists, kts_path.exists)
    if choice == "android/build.gradle":
        return struct(path = choice, content = ctx.read(gradle_path))
    if choice == "android/build.gradle.kts":
        return struct(path = choice, content = ctx.read(kts_path))
    return struct(path = "", content = "")
