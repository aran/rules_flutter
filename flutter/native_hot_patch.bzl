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
it by content — never by position in this list. Exec configurations are left
out: a tool that links a hot-patched library runs in the build, not in the app.

The group holds each patched library as well as what its `hot_patch` builds,
because the dev tool reads the library's identity; under build without the
bytes, an output is on this machine only if something top-level names it. It
holds no source files, which the command reads from the execution root where
they already are.
"""

load("//flutter:providers.bzl", "FlutterNativeLibraryInfo")
load("//flutter/private:host_transition.bzl", _host_transition = "host_transition")

HOT_PATCH_OUTPUT_GROUP = "flutter_native_hot_patch"

# The configuration for a `hot_patch` builder's program, which the dev tool runs
# beside the app: `cfg = host_transition` builds it for the machine running
# Bazel, whatever the app targets and wherever build actions run.
host_transition = _host_transition

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
    # A tool's configuration builds programs the build runs, never the app: a
    # code generator that links the library is not where a patch could go.
    # Collecting there would build the library and its builder for the
    # execution platform, every launch, for nothing — on a remote executor, for
    # another OS. Everything below a tool is a tool too, so this ends the walk's
    # yield at the first exec edge.
    if ctx.configuration.is_tool_configuration():
        files = depset()
        return [
            _HotPatchFilesInfo(files = files),
            OutputGroupInfo(**{HOT_PATCH_OUTPUT_GROUP: files}),
        ]
    direct = []
    if FlutterNativeLibraryInfo in target:
        info = target[FlutterNativeLibraryInfo]
        if info.hot_patch:
            # The libraries too: the dev tool reads each one's linker identity
            # to find the build the app bundled, and a build that keeps outputs
            # remote downloads only what the group names. Built files only: a
            # source is never built or downloaded, and the build event stream
            # names one by its path within its own repository, which does not
            # place it in the execution root.
            direct.append(depset([
                f
                for f in info.hot_patch.files.to_list() + info.libraries.to_list()
                if not f.is_source
            ]))
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
