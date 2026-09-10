"""Repository rule vendoring the `flutter gen-l10n` generator from flutter_tools.

`flutter gen-l10n` is not a build_runner Builder and not a shipped binary — it
is a command inside `flutter_tools`, which the rules deliberately do not
download (they take engine artifacts plus framework source, never the CLI). Its
generator code is nevertheless ordinary Dart, sitting in the same GitHub tarball
`flutter_sdk_package` already fetches for `package:flutter`.

Importing it as-is is not viable: Dart resolves dependencies by *file import*,
not by call graph, so `gen_l10n.dart` transitively reaches 187 files and 33 pub
packages — the whole tool, including Xcode, CocoaPods, Gradle and device
discovery. Six import edges carry all of that, and every one of them exists for
command-line plumbing the generator itself never needs: an argument parser bound
to `FlutterCommand`, a `dart format` invocation reached through `Artifacts`, an
analytics-consent prompt, and a one-line default that reads `globals`.

Cutting those six drops the closure to the 20 files listed in `_SUBSET_SRCS`
and 7 mundane pub packages. A seventh patch removes the `NetworkInterface`
wrapper from `base/io.dart`: gen-l10n does no networking, so it is dead weight
in the subset for the same reason the analytics prompt is.

**That seventh cut is not a version workaround and must not be reverted.** It
happens also to remove the subset's only use of a `dart:io` API newer than
flutter_tools' own declared `sdk: ^3.10.0-0` — `InterfaceAddress`, added in Dart
3.13. Upstream gets away with that because flutter_tools is only ever compiled
by its own bundled Dart, whereas a `dart_binary` here compiles with rules_dart's
toolchain. Without the cut the generator cannot build against a rules_dart older
than Dart 3.13, and *with* it the subset honestly matches the SDK constraint it
declares. When rules_dart ships a newer Dart, nothing here needs undoing.

The patches under `patches/` are those seven cuts. They are overwhelmingly
deletions (+14/-199 lines), which is deliberate: a deletion that no longer
applies is a loud failure, where a rewrite would quietly drift.

### What a Flutter version bump must re-check

1. **The tarball `sha256`.** Bumping `flutter_version` without bumping
   `sha256` fails the download. That is the intended signal, not a bug.
2. **The patches.** `repository_ctx.patch` refuses to apply a diff whose
   context has moved. Re-derive the cuts against the new release rather than
   forcing them.
3. **Undeclared runtime reads.** The import graph is not the whole story:
   before the cuts, `generateLocalizations` *read `pubspec.yaml` at run time*
   to mirror its line endings, which no static analysis surfaces. That read is
   patched out (output is always LF, because keying build output off a file
   that is not a declared action input makes it host-dependent). A new release
   may introduce another such read — the symptom is a `PathNotFoundException`
   for a file the action never declared.
4. **The pub pins** in `gen_l10n/pubspec.yaml`, against the new release's
   `packages/flutter_tools/pubspec.yaml`.
5. **Newly adopted `dart:io` APIs.** flutter_tools is compiled by its own
   bundled Dart and so may use APIs newer than the Dart a `dart_binary` gets.
   The symptom is a compile error naming a missing `dart:io` type. The fix is
   another dead-code cut, not a toolchain workaround — see the seventh patch.
"""

load("//flutter/private:artifact_urls.bzl", "flutter_source_tarball_url")

# The exact closure of `src/localizations/gen_l10n.dart` once the six import
# edges are cut. Listed explicitly rather than globbed: the subset boundary is
# the whole point of this repository, so it is stated, not inferred. Files the
# tarball carries beyond this list stay on disk and are simply not sources.
_SUBSET_SRCS = [
    "lib/src/base/async_guard.dart",
    "lib/src/base/common.dart",
    "lib/src/base/context.dart",
    "lib/src/base/exit.dart",
    "lib/src/base/file_system.dart",
    "lib/src/base/io.dart",
    "lib/src/base/logger.dart",
    "lib/src/base/platform.dart",
    "lib/src/base/process.dart",
    "lib/src/base/signals.dart",
    "lib/src/base/terminal.dart",
    "lib/src/base/utils.dart",
    "lib/src/convert.dart",
    "lib/src/features.dart",
    "lib/src/localizations/gen_l10n.dart",
    "lib/src/localizations/gen_l10n_templates.dart",
    "lib/src/localizations/gen_l10n_types.dart",
    "lib/src/localizations/language_subtag_registry.dart",
    "lib/src/localizations/localizations_utils.dart",
    "lib/src/localizations/message_parser.dart",
]

# Pub packages the subset imports, in the hub the root module resolves from
# `//flutter/private/gen_l10n:pubspec.lock`.
_SUBSET_DEPS = ["file", "intl", "meta", "path", "process", "stack_trace", "yaml"]

_PATCHES = [
    Label("//flutter/private/gen_l10n/patches:gen_l10n.patch"),
    Label("//flutter/private/gen_l10n/patches:localizations_utils.patch"),
    Label("//flutter/private/gen_l10n/patches:signals.patch"),
    Label("//flutter/private/gen_l10n/patches:process.patch"),
    Label("//flutter/private/gen_l10n/patches:features.patch"),
    Label("//flutter/private/gen_l10n/patches:io.patch"),
]

def _flutter_gen_l10n_repo_impl(repository_ctx):
    version = repository_ctx.attr.flutter_version

    repository_ctx.download_and_extract(
        url = flutter_source_tarball_url(version),
        sha256 = repository_ctx.attr.sha256,
        stripPrefix = "flutter-{version}/packages/flutter_tools".format(version = version),
    )

    # `-p1` strips the leading `a/`, leaving the `lib/src/...` paths the
    # stripped tarball already uses. A patch that no longer applies stops the
    # build — see this file's header on bumping Flutter.
    for patch in _PATCHES:
        repository_ctx.patch(repository_ctx.path(patch), strip = 1)

    srcs = "\n".join(['        "%s",' % s for s in _SUBSET_SRCS])
    deps = "\n".join([
        '        "@%s__%s//:%s",' % (repository_ctx.attr.hub_name, d, d)
        for d in _SUBSET_DEPS
    ])

    repository_ctx.file("BUILD.bazel", """\
load("@rules_dart//dart:defs.bzl", "dart_library")

# The gen-l10n generator carved out of flutter_tools {version}. See
# rules_flutter's flutter_gen_l10n_repo.bzl for what was cut and why, and for
# what a Flutter bump has to re-check.
dart_library(
    name = "gen_l10n",
    srcs = [
{srcs}
    ],
    package_name = "flutter_gen_l10n",
    deps = [
{deps}
    ],
    visibility = ["//visibility:public"],
)
""".format(version = version, srcs = srcs, deps = deps))

flutter_gen_l10n_repo = repository_rule(
    implementation = _flutter_gen_l10n_repo_impl,
    attrs = {
        "flutter_version": attr.string(
            doc = "Flutter release whose flutter_tools the generator is taken from.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "Checksum of the Flutter source tarball — an unpinned " +
                  "fetch would let the generator's code change under a fixed " +
                  "Flutter version. Guaranteed non-empty by the caller: " +
                  "extensions.bzl reads it through `flutter_source_sha256()`, " +
                  "which refuses a version with no recorded checksum.",
            mandatory = True,
        ),
        "hub_name": attr.string(
            doc = "Pub hub supplying the generator's seven dependencies.",
            mandatory = True,
        ),
        "_patches": attr.label_list(
            default = _PATCHES,
            doc = "Declared so a patch edit refetches the repository.",
        ),
    },
    doc = "Vendors the `flutter gen-l10n` generator as a buildable dart_library.",
)
