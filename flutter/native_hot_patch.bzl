"""Collects every `flutter_native_library.hot_patch` a launch target bundles.

The dev tool needs the patch builders in the configuration the running app was
built in — an Android app's libraries are arm64 ELF, and the host build of the
same `flutter_application` produces a macOS dylib that nothing is running. No
flag selects a configured target from the command line, and the launch targets
are other rule sets' rules (`macos_application`, `android_binary`, ...), so no
output group of ours can be added to them.

An aspect reaches through all of that. Applied to the launch target, it follows
every label edge, transitions included, and meets each wrapper in the
configuration the bundle really used. Building only its output group builds only
what the patch builders need: measured on an Android app, a C edit rebuilt the
library and nothing of the APK.

    bazel build <launch target> \\
        --aspects=@rules_flutter//flutter:native_hot_patch.bzl%flutter_native_hot_patch_aspect \\
        --output_groups=flutter_native_hot_patch

The group can hold one library in more than one configuration: a platform rule
can reach `native_deps` both at the top level and through its own transition.
Only the copy the bundle carries is the one the app loaded, and the dev tool picks
it by content — never by position in this list.
"""

load("//flutter:providers.bzl", "FlutterNativeLibraryInfo")

HOT_PATCH_OUTPUT_GROUP = "flutter_native_hot_patch"

_HotPatchFilesInfo = provider(
    doc = "Every `hot_patch` target's files at or below this node.",
    fields = {"files": "depset[File]"},
)

def _dependencies(rule_attr):
    """The collected files of every dependency, whatever attribute shape holds it.

    Label dicts included: `macos_application` takes its frameworks through a
    `label_keyed_string_dict`, and a walk over lists alone would stop there.
    """
    deps = []
    for name in dir(rule_attr):
        value = getattr(rule_attr, name)
        if type(value) == "list":
            items = value
        elif type(value) == "dict":
            items = list(value.keys()) + list(value.values())
        else:
            items = [value]
        for item in items:
            if type(item) == "Target" and _HotPatchFilesInfo in item:
                deps.append(item[_HotPatchFilesInfo].files)
    return deps

def _flutter_native_hot_patch_aspect_impl(target, ctx):
    direct = []
    if FlutterNativeLibraryInfo in target:
        hot_patch = target[FlutterNativeLibraryInfo].hot_patch
        if hot_patch:
            direct.append(hot_patch.files)
    files = depset(transitive = direct + _dependencies(ctx.rule.attr))
    return [
        _HotPatchFilesInfo(files = files),
        OutputGroupInfo(**{HOT_PATCH_OUTPUT_GROUP: files}),
    ]

flutter_native_hot_patch_aspect = aspect(
    implementation = _flutter_native_hot_patch_aspect_impl,
    attr_aspects = ["*"],
    doc = "Collects the `hot_patch` manifests and files of every `flutter_native_library` below a launch target, in the configuration each was built in.",
)
