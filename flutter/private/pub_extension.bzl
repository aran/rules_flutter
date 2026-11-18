"""The implementation of the `pub` extension (`@rules_flutter//flutter/pub:extensions.bzl`).

It resolves pub dependencies (including Flutter SDK packages like package:flutter)
from `pubspec.lock` files. It is separate from the `flutter` extension so that a
lock it refuses breaks only the builds that use its repositories, never the
toolchains, and `bazel run @rules_flutter//flutter/pub`, which fixes the lock,
still runs.

The extension itself is defined in `flutter/pub/extensions.bzl`: a module
extension is identified by the file that defines it and its name.
"""

load("@rules_dart//dart/ext:registry.bzl", "curated_code_assets")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "check_pub_archive_sha256", "check_pub_git_resolved_ref", "is_relative_git_url", "pub_archive_files", "pub_files_label", "pub_git_files", "pub_path_identity")
load("@rules_dart//dart/pub:pub_versions.bzl", "CHECK_LEVELS")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_lock")
load("//flutter/private:android_plugin_maven.bzl", "MAVEN_DEPS_FILE", "flutter_android_maven")
load("//flutter/private:apple_app_settings_repo.bzl", "flutter_apple_app_settings")
load("//flutter/private:apple_plugin_repo.bzl", "apple_repo", "flutter_apple_plugin_repo")
load("//flutter/private:flutter_face_repo.bzl", "flutter_face_repo")
load("//flutter/private:flutter_framework_package.bzl", "flutter_framework_package")
load("//flutter/private:flutter_gen_l10n_repo.bzl", "flutter_gen_l10n_repo")
load("//flutter/private:flutter_pub_goldens.bzl", "flutter_pub_goldens")
load("//flutter/private:flutter_pub_index.bzl", "ANDROID_MAVEN_REPO", "APPLE_APP_SETTINGS_REPO", "GOLDENS_REPO", "INDEX_REPO", "SPOKE_PREFIX", "files_repo", "flutter_pub_index", "index_repo", "library_repo", "sdk_prefix", "source_repo")
load("//flutter/private:flutter_pub_library_repo.bzl", "flutter_pub_library_repo")
load("//flutter/private:flutter_pub_lock_hub.bzl", "flutter_pub_lock_hub")
load("//flutter/private:flutter_pub_package.bzl", "flutter_pub_package")
load("//flutter/private:flutter_resolved_package.bzl", "flutter_resolved_package")
load("//flutter/private:flutter_sdks_repo.bzl", "SDKS_FILE", "decode_sdks")
load("//flutter/private:flutter_source_files.bzl", "flutter_source_files")
load("//flutter/private:flutter_unsupported_package.bzl", "flutter_unsupported_package", "ignored_package_message", "unsupported_package_message")
load("//flutter/private:lock_entry_kind.bzl", "ENGINE_PROVIDED", "FLUTTER_FRAMEWORK", "FLUTTER_SOURCE", "GIT", "HOSTED", "IGNORED", "LOCAL", "PATH", "UNSUPPORTED", "lock_entry_kind")
load("//flutter/private:pub_cycles.bzl", "module_cycles", "plan_cycles")
load("//flutter/private:pub_lock_sdks.bzl", "parse_lock_sdk_constraints")
load("//flutter/private:pub_reconcile.bzl", "pub_command", "reconcile_package", "sdk_pin_errors", "unsupported_locks")
load("//flutter/private:pub_resolve.bzl", "lock_directory", "path_package_directory", "resolve_errors", "resolve_failure", "resolved_targets")
load("//flutter/private:pub_settings.bzl", "root_annotations", "root_only_settings", "unknown_annotation")
load("//flutter/private:swift_packages.bzl", "declare_swift_packages")
load("//flutter/private:versions.bzl", "flutter_sdk_exact_pins", "flutter_sdk_packages", "flutter_source_sha256")

# The name of the SDK every build has: the default `flutter.toolchain`.
DEFAULT_SDK_NAME = "flutter"

# The SDKs the `flutter` extension declared, as `flutter_sdks_repo` writes them.
_SDKS = Label("@flutter_sdks//:" + SDKS_FILE)

def framework_json(framework):
    """The label of `flutter_framework.json` in a framework source."""
    return Label("@@{}//:flutter_framework.json".format(framework.repo_name))

pub_from_lock_tag = tag_class(attrs = {
    "name": attr.string(
        doc = """\
Repository name for the resolved packages hub: `@<name>//:<package>` for each
package of the lock. Several tags may share a name, in this or other modules;
the hub then holds the packages of all their locks, each aliased once.

Every package is one repository for the whole build, however many hubs list it,
so a name starting with `flutter_pub` is reserved. The locks that list a package
must agree on its source and, for a git package, its commit. Hosted versions
may differ: each lock's version is a minimum and the build gets the highest any
lock records, in any module (see `flutter_pub.settings`). One version has one
digest in every lock.
""",
        mandatory = True,
    ),
    "lock": attr.label(
        doc = "The pubspec.lock file to parse.",
        mandatory = True,
        allow_single_file = True,
    ),
    "resolve": attr.string_keyed_label_dict(
        doc = """\
Lock packages, each mapped to the target that builds it: a `flutter_library`,
`flutter_plugin` or `dart_library` whose `dart_package_metadata` has the pub
package's name as its `package_name` (a target that declares another name fails
analysis, naming both). Every
hub's `@<hub>//:<package>` for it is that target, and a hosted package that
depends on the package gets it too, for the whole build: another lock's entry
for the package is not fetched, and a package mapped to different targets by two
tags fails.

Every `path` package of the lock must be named in exactly one of `resolve`,
`build_from_pubspec` and `ignored`. Map a `path` package here when a target
builds it: a package of this repository with its own BUILD file, generated
code, or a package pub reads from a sibling checkout and Bazel takes from a
`bazel_dep`. Where the lock's path points is pub's concern only. Only the
package name the target declares is checked, at analysis. A hosted, git or sdk
package may be mapped, to replace it for the whole graph with a fork or a
patched copy, from any repository; the locked package is then not fetched, and
its version is not checked. Naming a package the lock does not list is an
error.

```starlark
flutter_pub.from_lock(
    name = "deps",
    lock = "//apps/greeter:pubspec.lock",
    resolve = {
        "greeting": "//packages/greeting",
        "tagline": "//packages/tagline:tagline_lib",
        "intl": "//third_party/intl",  # replaces the locked hosted package
    },
)
```
""",
        default = {},
    ),
    "build_from_pubspec": attr.string_list(
        doc = """\
`path` packages of the lock that have no Bazel build, to build from their
directory exactly as a package from pub.dev or git is built: its Dart library,
its fonts, assets and shaders, and its plugin code for Android (Kotlin and Java
from `android/src/main`, with the namespace, manifest, resources, Maven
dependencies and ProGuard files its Gradle build declares), iOS, macOS, Linux
and Windows. This is what `flutter build` does with every `path` package. The
package's facts are read from its pubspec and Gradle files, not restated in
Bazel.

The directory is the lock's `path`, relative to the lock's directory, as pub
reads it; it may be outside this repository. Bazel links its `pubspec.yaml`,
`lib/`, `hook/`, license files, platform directories and the directories its
pubspec lists assets, fonts and shaders from, and fetches the package again when
any of them changes; tool output such as `build/`, `.dart_tool/` and
`android/.gradle/` is not read. A directory that holds a Bazel build (a `BUILD`,
`BUILD.bazel`, `MODULE.bazel`, `REPO.bazel` or `WORKSPACE` file) is refused: map
it with `resolve` instead. A directory whose code is generated, or built by
Bazel another way (a Rust library behind an FFI plugin, say), needs `resolve`
too: its pubspec does not say how to build it.

```starlark
flutter_pub.from_lock(
    name = "deps",
    lock = "//:pubspec.lock",
    build_from_pubspec = ["keyboard_android"],
)
```

Naming a package the lock does not list, or lists from another source, is an
error. Two locks that build one package from different directories fail.
""",
        default = [],
    ),
    "ignored": attr.string_dict(
        doc = """\
`path` packages of the lock that no Bazel build may contain, each with the
reason: a package only a tool run outside Bazel uses, say. The hub still has a
label for the package, so the lock loads; any target that depends on it fails
at analysis with ``package `<package>` (in <lock>) is ignored: <reason>``. Nothing that does
not depend on it is affected.

```starlark
flutter_pub.from_lock(
    name = "deps",
    lock = "//:pubspec.lock",
    ignored = {"release_tool": "run with `dart run` outside Bazel"},
)
```

Naming a package the lock does not list, or lists from another source, is an
error.
""",
        default = {},
    ),
    "swift_package_resolved": attr.label(
        doc = """\
The root module's `Package.resolved`: the one its rules_swift_package_manager
`swift_deps.from_package(resolved = ...)` reads, which pins the Swift packages
this lock's Apple plugins depend on (`.package(url:)` in a plugin's
`Package.swift`, as the Firebase plugins' `firebase-ios-sdk`). The root
declares those packages and hands each to this extension with `inject_repo`;
rules_flutter reads the file to check that each pin meets what the plugins'
manifests require. `bazel run @<name>//swift:packages` prints the lines the
root needs. The files of all tags must agree on each package.
""",
        allow_single_file = True,
    ),
    "ignore_hooks": attr.string_list(
        doc = "Pub package names whose `hook/build.dart` is knowingly " +
              "irrelevant to this build (its native code is never reached). " +
              "Suppresses the unreplaced-hook error for them, for the whole " +
              "build: the names of every tag are one set. This is a " +
              "declaration you make deliberately; it is never a default. Only " +
              "the root module may set it: whether a hook matters depends on " +
              "the programs the build makes, which are the root's.",
        default = [],
    ),
})

pub_settings_tag = tag_class(
    attrs = {
        "check_direct_dependencies": attr.string(
            doc = "What to do when one of the root module's own requests (a hosted " +
                  "entry of a lock the root passes to `flutter_pub.from_lock`) is raised " +
                  "by a higher request elsewhere in the build: `warning` (the default) " +
                  "prints the package, both versions, who raised it and the command that " +
                  "raises the root's lock, `error` fails the build with that message, and " +
                  "`off` says nothing. Raising another module's request is what a minimum " +
                  "means and is never reported. Bazel's `--check_direct_dependencies` does " +
                  "the same for `bazel_dep`.",
            default = "warning",
            values = CHECK_LEVELS,
        ),
    },
    doc = "How the extension reports the build's version choices. Every hosted entry " +
          "of every `flutter_pub.from_lock` lock, in any module, is a request for at " +
          "least that version, and the highest is built, as Bazel's minimal version " +
          "selection does for modules. Two requests of one version must pin one digest, " +
          "and all of a package's requests one registry. Only the root module may use " +
          "this tag, at most once.",
)

pub_annotation_tag = tag_class(
    attrs = {
        "package": attr.string(
            doc = "The pub package to annotate. A package one of the build's " +
                  "`flutter_pub.from_lock` locks lists, and built by rules_flutter.",
            mandatory = True,
        ),
        "android_deps": attr.label_list(
            doc = "Artifacts of `@rules_flutter_maven` to add to the package's " +
                  "generated Android library, for a plugin whose Gradle build " +
                  "declares dependencies rules_flutter does not read (`files(...)`, " +
                  "a version catalog). Each is linked, checked against " +
                  "what `@rules_flutter_maven` resolves, and listed by the app's " +
                  "`<app>_maven_artifacts` as the plugin's own Gradle ones are. The " +
                  "package must be a plugin with Android sources that rules_flutter " +
                  "generates the library of: not one with a `plugin_overlays` " +
                  "`android/BUILD.bazel.tpl`, which lists its own dependencies.",
            default = [],
        ),
        "build_config_fields": attr.string_dict(
            doc = "Values of the `buildConfigField`s the package's Gradle build " +
                  "declares, by field name, each the Java expression Gradle's third " +
                  "argument gives: a string keeps its quotes, so a version is " +
                  "`\"\\\"1.2.3\\\"\"` in MODULE.bazel. " +
                  "They replace what rules_flutter reads or recognises, for a field " +
                  "whose value it cannot compute without running Gradle; the type " +
                  "stays the one the Gradle line declares. A field the Gradle build " +
                  "does not declare fails the plugin's Android build, naming it. An " +
                  "annotation names a package, not a version: a value that is a " +
                  "version goes stale when the lock moves the package.",
            default = {},
        ),
    },
    doc = "Adds to one pub package's generated targets what its own files cannot " +
          "say, as `crate.annotation` does for a Rust crate. Only the root module " +
          "may use this tag, once per package. A package no lock lists, or one " +
          "the field cannot apply to, fails the build, naming it.",
)

pub_cycle_tag = tag_class(
    attrs = {
        "packages": attr.string_list(
            doc = "Every package of the cycle. Each must be one a " +
                  "`flutter_pub.from_lock()` lock lists and the build builds, " +
                  "and none may be in another `flutter_pub.cycle()` of the module.",
            mandatory = True,
        ),
    },
    doc = "Pub packages that depend on each other in a cycle, built as one library. " +
          "Pub allows a cycle and Bazel does not, so a cycle builds only where it is " +
          "declared; an undeclared one fails when it is planned, giving the declaration " +
          "to write. Like versions, cycles are build-wide, and the root module decides: " +
          "its declarations must each be exactly a cycle at the versions the build " +
          "fetches, or the build fails (so a declaration cannot outlive its cycle). " +
          "Another module's declarations, and rules_dart's curated ones " +
          "(`curated_cycles()` in `@rules_dart//dart/ext:registry.bzl`, such as " +
          "`dio` and `dio_web_adapter`), apply where they are exactly a cycle and are " +
          "inert where they are not.",
)

pub_plugin_overlays_tag = tag_class(attrs = {
    "roots": attr.label_list(
        doc = "BUILD.bazel anchors for user-supplied overlay trees. Each " +
              "label points at a `flutter/ext/BUILD.bazel` (or equivalent) that " +
              "anchors a directory tree of `<package>/<version>/BUILD.bazel.tpl` " +
              "overrides. flutter_pub_package walks user roots first, then the " +
              "bundled `@rules_flutter//flutter/ext:BUILD.bazel`. A template declares " +
              "its language version and its dependencies by placeholder " +
              "(`{LANGUAGE_VERSION}`, `{DEPS}`), never by hand; see " +
              "docs/TESTING.md \"Native Assets overlay authoring\".",
        allow_files = True,
        default = [],
    ),
})

def _framework_variants(sdks):
    """The prefix of the repositories that hold each SDK's framework packages, by SDK name.

    There is one repository per package for the whole build, so the default
    SDK's framework packages are the build's own (`SPOKE_PREFIX`). Another SDK
    shares them when it has the same framework (the same release, or the same
    framework source); otherwise its framework's packages are repositories of
    their own, one per package, named by `sdk_prefix` of the first SDK to have
    that framework and shared by every SDK that has it.
    """
    key_prefix = {_framework_key(sdks[DEFAULT_SDK_NAME]): SPOKE_PREFIX}
    prefixes = {DEFAULT_SDK_NAME: SPOKE_PREFIX}
    for name in sorted(sdks.keys()):
        key = _framework_key(sdks[name])
        if key not in key_prefix:
            key_prefix[key] = sdk_prefix(name)
        prefixes[name] = key_prefix[key]
    return prefixes

def _framework_representatives(sdks, prefixes):
    """For each prefix that holds framework packages, the first SDK whose they are."""
    reps = {}
    for name in sorted(sdks.keys(), key = lambda n: (n != DEFAULT_SDK_NAME, n)):
        reps.setdefault(prefixes[name], sdks[name])
    return reps

def _framework_key(sdk):
    """What two SDKs must share for them to share their framework's packages."""
    if sdk.framework:
        return "source " + str(sdk.framework)
    return "release " + sdk.version

def pub_extension(module_ctx):
    """The implementation of the `pub` extension: a repository per lock package.

    Args:
        module_ctx: The module extension context.

    Returns:
        The extension metadata.
    """

    # The SDKs, as the `flutter` extension declared them. Read from its
    # repository so that extension never reads a lock: a problem with the
    # locks fails this extension's repositories alone, and the toolchains,
    # with the `@rules_flutter//flutter/pub` runner that fixes the locks, still
    # work.
    sdks = decode_sdks(module_ctx.read(_SDKS))

    # The gen-l10n generator of each SDK, carved out of its flutter_tools, and
    # the fixed name that follows the selected SDK. Here, not in `flutter`,
    # because its dependencies are packages of the locks (rules_flutter's own
    # lock among them). Declared unconditionally because bzlmod repositories
    # are lazy: a workspace that never references them never fetches the
    # tarball.
    for name in sorted(sdks.keys()):
        sdk = sdks[name]
        released = sdk.version and not sdk.framework
        flutter_gen_l10n_repo(
            name = name + "_gen_l10n_src",
            flutter_version = sdk.version or "",
            framework_json = framework_json(sdk.framework) if sdk.framework else None,
            sha256 = flutter_source_sha256(sdk.version) if released else "",
        )
    flutter_face_repo(
        name = "flutter_gen_l10n",
        sdks = {name: "@{}_gen_l10n_src".format(name) for name in sdks},
        targets = {"gen_l10n": "{prefix}//:gen_l10n"},
    )

    # Collect user-supplied overlay roots from
    # `flutter_pub.plugin_overlays(...)` tags. They're applied to every
    # flutter_pub_package invocation in the order seen, then the bundled
    # `@rules_flutter//flutter/ext` root. This makes any pub plugin user-fixable locally
    # — drop a `<workspace>/plugin_overlays/<pkg>/<major>/BUILD.bazel.tpl` and
    # register the root in MODULE.bazel; the next build picks it up.
    user_overlay_roots = []
    for mod in module_ctx.modules:
        for tag in mod.tags.plugin_overlays:
            user_overlay_roots.extend(tag.roots)

    # Handle flutter_pub.from_lock() tags — resolve pubspec.lock with Flutter
    # SDK support. Every tag of every module is read first, because a package is
    # one repository for the whole build: the locks that list it must agree on
    # it (`reconcile_package`), the highest version of a hosted package any
    # lock records is built, and a package any tag maps with `resolve` is
    # that target for every hub.
    # How a raised root lock is reported, and which hooks do not matter, are
    # the root's to say: another module's statement of either fails.
    settings = root_only_settings(module_ctx.modules)
    if settings.error:
        fail(settings.error)

    # What a package is built with beyond its own files is the root's too.
    annotations = root_annotations(
        module_ctx.modules,
        # `@rules_flutter_maven` is only read when an annotation needs it: a
        # build that annotates nothing need not have it.
        str(Label("@rules_flutter_maven//:_"))[:-1] if [m for m in module_ctx.modules if m.tags.annotation] else "",
    )
    if annotations.error:
        fail(annotations.error)

    tags = []
    for mod in module_ctx.modules:
        for pub_tag in mod.tags.from_lock:
            hub_name = pub_tag.name
            if hub_name == SPOKE_PREFIX or hub_name.startswith(SPOKE_PREFIX + "_") or hub_name.startswith(SPOKE_PREFIX + "-"):
                fail((
                    "flutter_pub.from_lock(name = \"{}\") is reserved: hubs may not be named " +
                    "`{}` or start with `{}_` or `{}-`, which name the repositories " +
                    "shared by every hub."
                ).format(hub_name, SPOKE_PREFIX, SPOKE_PREFIX, SPOKE_PREFIX))
            lock_content = module_ctx.read(pub_tag.lock)
            lock_pkgs = parse_pubspec_lock(lock_content, str(pub_tag.lock))

            # Before anything else is checked, so a wrong map is not masked.
            resolve_problems = resolve_errors(pub_tag.lock, lock_pkgs, pub_tag.resolve, pub_tag.build_from_pubspec, pub_tag.ignored)
            if resolve_problems:
                fail(resolve_failure(hub_name, pub_tag.lock, resolve_problems))

            # The lock is checked against each SDK's framework by that SDK's own
            # `package:flutter` spoke, which only the SDK a build selects
            # fetches.
            flutter_constraint = parse_lock_sdk_constraints(lock_content).get("flutter", "")

            # A `path` entry's path is relative to the lock's directory, as pub
            # reads it: the real one, for a lock of a module whose repository
            # links to its source (`local_path_override`).
            lock_dir = str(module_ctx.path(pub_tag.lock).realpath.dirname)
            tags.append(struct(module = mod, tag = pub_tag, packages = lock_pkgs, flutter_constraint = flutter_constraint, lock_dir = lock_dir))

    cycles = [module_cycles(mod) for mod in module_ctx.modules]
    if not tags and annotations.by_package:
        fail(unknown_annotation(annotations.by_package, []))
    if not tags:
        # Nothing is built, so a root declaration names no package of a cycle.
        planned = plan_cycles(cycles, built = {})
        if planned.error:
            fail(planned.error)
    else:
        _declare_pub_packages(tags, settings, annotations.by_package, sdks, user_overlay_roots, cycles)
        declare_swift_packages(module_ctx, [t.tag.swift_package_resolved for t in tags if t.tag.swift_package_resolved])

    return module_ctx.extension_metadata(reproducible = True)

def _hosted_entry(tag, name, info):
    desc = info.get("description", {})
    version = info.get("version", "")
    sha256 = desc.get("sha256", "") if type(desc) == "dict" else ""

    # An empty digest means "do not check" to Bazel's downloader, so a lock
    # entry without one is refused here, where the lock can be named, rather
    # than fetched on trust.
    check_pub_archive_sha256(name, version, sha256, str(tag.lock), rewrite = pub_command("get", lock_directory(tag.lock)))
    return dict(
        kind = HOSTED,
        version = version,
        sha256 = sha256,
        url = desc.get("url", "https://pub.dev") if type(desc) == "dict" else "https://pub.dev",
    )

def _git_entry(tag, name, info):
    # A repository package is fetched at the commit the lock records, laid out
    # as pub lays it out (`fetch_pub_git`), and built as a hosted package is.
    # The lock is checked here, where it can be named: an entry that pins no
    # commit would be whatever the server holds on the day of the fetch.
    desc = info.get("description", {})
    version = info.get("version", "")
    url = desc.get("url", "") if type(desc) == "dict" else ""
    if not url:
        fail("The git package \"%s\" %s (in %s) has no `description.url`. Run `dart pub get` to rewrite the lock." % (name, version, tag.lock))
    resolved_ref = desc.get("resolved-ref", "")
    check_pub_git_resolved_ref(name, version, resolved_ref, str(tag.lock), rewrite = pub_command("get", lock_directory(tag.lock)))
    git_path = desc.get("path", ".")
    return dict(
        kind = GIT,
        version = version,
        git_url = url,
        resolved_ref = resolved_ref,
        git_path = git_path,
        # A relative url is resolved against the lock's directory; any other
        # leaves the lock out, so editing the lock does not refetch the package.
        git_lock = str(tag.lock) if is_relative_git_url(url) else "",
        lock = tag.lock if is_relative_git_url(url) else None,
    )

def _path_entry(t, name, info):
    """A `path` package the tag builds from its pubspec or ignores (a mapped one never gets here)."""
    if name in t.tag.ignored:
        return dict(kind = IGNORED, reason = t.tag.ignored[name])
    desc = info.get("description", {})
    path = desc.get("path", "") if type(desc) == "dict" else ""
    return dict(
        kind = LOCAL,
        version = info.get("version", ""),
        directory = path_package_directory(t.lock_dir, path),
        # What rules_dart's `pub` states it was fetched as for this entry, so
        # a program reaching both fetchers' copies of the directory takes
        # them for one package.
        path_identity = pub_path_identity(t.tag.lock, path),
    )

def _hub_listing(hub_packages, package):
    """A hub that lists a package: its alias follows the selected SDK."""
    return [h for h in sorted(hub_packages.keys()) if package in hub_packages[h]][0]

def _declare_pub_packages(tags, settings, annotations, sdks, user_overlay_roots, cycles):
    """Declares the repositories of every `flutter_pub.from_lock()` tag: one per package.

    Args:
        tags: One `struct(module, tag, packages)` per tag, `packages` being its parsed lock.
        settings: The root's `root_only_settings`: the level for its raised
            requests, and the packages whose hooks it declared irrelevant.
        sdks: The declared SDKs, by name. The default SDK's framework builds the
            build's Flutter SDK packages; another SDK with another framework
            has packages of its own.
        annotations: The root's `flutter_pub.annotation` fields, by package (`root_annotations`).
        user_overlay_roots: The overlay roots every package is built with.
        cycles: Every module's `flutter_pub.cycle()` declarations (`module_cycles`).
    """
    ignore_hooks = settings.ignore_hooks

    mapped = resolved_targets([struct(lock = t.tag.lock, hub = t.tag.name, resolve = t.tag.resolve) for t in tags])
    if mapped.errors:
        fail("\n\n".join(mapped.errors))

    # Every lock's entry for each package, classified by who builds it
    # (`lock_entry_kind`). A mapped package is a workspace target whatever the
    # locks say, so it is not compared, fetched or version-checked.
    entries = {}
    hub_packages = {}

    # The pins each hub's `swift:packages` checks the plugins against.
    hub_resolved = {}
    for t in tags:
        if t.tag.swift_package_resolved:
            hub_resolved.setdefault(t.tag.name, t.tag.swift_package_resolved)
    for t in tags:
        tag = t.tag
        hub = hub_packages.setdefault(tag.name, {})
        for name, info in t.packages.items():
            source = info.get("source", "unknown")
            kind = lock_entry_kind(name, source)
            if name in mapped.targets:
                hub[name] = True
                continue
            if kind == ENGINE_PROVIDED:
                continue
            hub[name] = True
            if kind == HOSTED:
                fields = _hosted_entry(tag, name, info)
            elif kind == GIT:
                fields = _git_entry(tag, name, info)
            elif kind == FLUTTER_SOURCE:
                fields = dict(kind = kind, version = info.get("version", ""))
            elif kind == FLUTTER_FRAMEWORK:
                fields = dict(kind = kind)
            elif kind == PATH:
                fields = _path_entry(t, name, info)
            else:
                # A source rules_flutter has never heard of. The hub still loads, so an app that
                # only lists it builds. Its target fails when something
                # depends on it.
                fields = dict(kind = UNSUPPORTED, source = source)
            entries.setdefault(name, []).append(struct(
                hub = tag.name,
                lock_label = str(tag.lock),
                lock_dir = lock_directory(tag.lock),
                module = t.module.name,
                is_root = t.module.is_root,
                **fields
            ))

    chosen = {}
    problems = []
    for name in sorted(entries.keys()):
        result = reconcile_package(name, entries[name], settings.check)
        problems.extend(result.errors)
        for warning in result.warnings:
            # Bazel warns the same way when a module raises a `bazel_dep` of
            # the root (`--check_direct_dependencies`).
            # buildifier: disable=print
            print(warning)
        chosen[name] = result.entry
    if problems:
        fail("\n\n".join(problems))
    unknown = unknown_annotation(annotations, list(chosen.keys()) + list(mapped.targets.keys()))
    if unknown:
        fail(unknown)

    # A release's packages are held to the pins it records; another framework
    # has its constraints checked against the locks when its spokes are fetched.
    default_sdk = sdks[DEFAULT_SDK_NAME]
    if not default_sdk.framework:
        pin_problems = sdk_pin_errors(default_sdk.version, flutter_sdk_exact_pins(default_sdk.version), chosen, entries)
        if pin_problems:
            fail("\n\n".join(pin_problems))

    built = {name: e for name, e in chosen.items() if e.kind in [HOSTED, GIT, LOCAL, FLUTTER_SOURCE]}
    other = sorted(
        [name for name in chosen if name not in built] +
        [name for name in mapped.targets if name not in chosen],
    )

    why_not_built = {
        FLUTTER_FRAMEWORK: "is `package:flutter`, which depends on no pub package",
        IGNORED: "a lock names in `ignored`",
        UNSUPPORTED: "a lock takes from a source rules_flutter does not build",
    }
    not_built = {name: why_not_built.get(e.kind, "the build does not build") for name, e in chosen.items() if name not in built}
    not_built.update({name: "maps to %s with `resolve`, so a target of yours builds it" % t.target for name, t in mapped.targets.items()})
    for name in sorted(annotations.keys()):
        if name in not_built:
            fail((
                "`flutter_pub.annotation(package = \"%s\")` names a package that %s, " +
                "so it has no Android library to add dependencies to."
            ) % (name, not_built[name]))
    planned = plan_cycles(cycles, built, not_built)
    if planned.error:
        fail(planned.error)

    # What every repository plans against, stated once rather than on each of
    # them: the lock records each repository's attributes, so the package list
    # on every repository would grow it by the square of the package count.
    #
    # The SDKs whose frameworks differ have Flutter SDK packages of their own
    # (a framework's packages are one repository each, shared by every SDK with
    # that framework): an index per prefix, over the same locks. Which package a
    # build uses is chosen by the hubs' aliases, on `--@rules_flutter//flutter:sdk`.
    sdk_packages = sorted([n for n, e in chosen.items() if e.kind in [FLUTTER_FRAMEWORK, FLUTTER_SOURCE]])
    prefixes = _framework_variants(sdks)
    multi = len({p: True for p in prefixes.values()}) > 1
    index_attrs = dict(
        built = sorted(built.keys()),
        other = other,
        sdk_packages = sdk_packages,
        versions = {n: e.version for n, e in chosen.items() if e.kind in [HOSTED, GIT, LOCAL] and e.version},
        locks = sorted({str(t.tag.lock): True for t in tags}.keys()),
        flutter_constraints = {str(t.tag.lock): t.flutter_constraint for t in tags if t.flutter_constraint},
        cycles = [" ".join(c) for c in planned.declared],
        advisory_cycles = [" ".join(c) for c in planned.advisory],
    )
    flutter_pub_index(
        name = INDEX_REPO,
        via_hub = multi,
        sdk_hubs = {n: _hub_listing(hub_packages, n) for n in sdk_packages},
        **index_attrs
    )
    for prefix in sorted({p: True for p in prefixes.values() if p != SPOKE_PREFIX}.keys()):
        flutter_pub_index(
            name = index_repo(prefix),
            main_prefix = SPOKE_PREFIX,
            sdk_prefix = prefix,
            via_hub = False,
            **index_attrs
        )

    for name, target in mapped.targets.items():
        # A mapped package is one repository, the workspace target the user
        # mapped it to, so it sits among the index's `other` packages whatever
        # the locks list it from: a hosted package that depends on it reaches
        # the target, every hub's label for it is the same repository, and the
        # locked package is not fetched.
        flutter_resolved_package(
            name = source_repo(name),
            package_name = name,
            actual = target.target,
            lock = target.lock,
        )

    overlay_roots = user_overlay_roots + ["@rules_flutter//flutter/ext:BUILD.bazel"]

    # Create a source repo and a library repo for each built package. They are
    # all routed through flutter_pub_package — the `flutter pub get` analog —
    # so plugins surface their `flutter.plugin.platforms` metadata via
    # FlutterInfo. Pure-Dart packages are still rules_dart's own member kind;
    # the rule branches internally on whether the pubspec declares anything of
    # Flutter's. The library repo is the package's dependency cycle (usually
    # just itself) as one target: pub allows packages to depend on each other,
    # Bazel does not. Non-Flutter modules using `pub.pub()` keep using
    # rules_dart's `pub_lock_package` directly.
    #
    # Each Flutter SDK package other than `package:flutter` is built from
    # `packages/<name>` of the one pinned Flutter source exactly as a hosted
    # package is built from its archive, `flutter/ext/` overlays (keyed
    # `<package>/0.0.0`) and library repository included. `package:flutter` has
    # a rule of its own (its shaders are declared in no pubspec).
    reps = _framework_representatives(sdks, prefixes)
    apple_repos = {}
    for name, e in sorted(chosen.items()):
        if e.kind == UNSUPPORTED:
            flutter_unsupported_package(
                name = source_repo(name),
                package_name = name,
                message = unsupported_package_message(
                    lock = unsupported_locks(entries[name]),
                    package = name,
                    source = e.source,
                ),
            )
        elif e.kind == IGNORED:
            flutter_unsupported_package(
                name = source_repo(name),
                package_name = name,
                message = ignored_package_message(name, [x for x in entries[name] if x.kind == IGNORED]),
            )
        elif e.kind == FLUTTER_FRAMEWORK:
            for prefix, sdk in reps.items():
                flutter_framework_package(
                    name = source_repo(name, prefix),
                    flutter_version = sdk.version or "",
                    framework_json = framework_json(sdk.framework) if sdk.framework else None,
                    sha256 = flutter_source_sha256(sdk.version) if sdk.version and not sdk.framework else "",
                    sdk = sdk.name,
                    prefix = prefix,
                )
        elif e.kind == HOSTED:
            flutter_pub_library_repo(name = library_repo(name), package_name = name)
            flutter_apple_plugin_repo(name = apple_repo(name), package_name = name, version = e.version)
            apple_repos[name] = apple_repo(name)
            pub_archive_files(
                name = files_repo(name),
                package_name = name,
                version = e.version,
                sha256 = e.sha256,
                base_url = e.url,
            )
            flutter_pub_package(
                name = source_repo(name),
                files = pub_files_label(files_repo(name)),
                package_name = name,
                overlay_roots = overlay_roots,
                # rules_dart's curated registry is the single source of truth
                # for which pub package a Bazel-built native library stands in
                # for, and at which versions. Consulting it here is what makes a
                # Flutter app depending on, say, `drift` get `sqlite3`'s
                # library without naming it: the asset lands on the package
                # that owns it, so it propagates through the Dart graph exactly
                # as pub's own would.
                code_assets = curated_code_assets(name, e.version),
                ignore_hook = name in ignore_hooks,
                android_deps = annotations.get(name, {}).get("android_deps", []),
                build_config_fields = annotations.get(name, {}).get("build_config_fields", {}),
            )
        elif e.kind == GIT:
            flutter_pub_library_repo(name = library_repo(name), package_name = name)
            flutter_apple_plugin_repo(name = apple_repo(name), package_name = name, version = e.version)
            apple_repos[name] = apple_repo(name)
            pub_git_files(
                name = files_repo(name),
                package_name = name,
                version = e.version,
                url = e.git_url,
                resolved_ref = e.resolved_ref,
                path = e.git_path,
                lock = e.lock,
            )
            flutter_pub_package(
                name = source_repo(name),
                files = pub_files_label(files_repo(name)),
                package_name = name,
                overlay_roots = overlay_roots,
                code_assets = curated_code_assets(name, e.version),
                ignore_hook = name in ignore_hooks,
                android_deps = annotations.get(name, {}).get("android_deps", []),
                build_config_fields = annotations.get(name, {}).get("build_config_fields", {}),
            )
        elif e.kind == LOCAL:
            # The directory pub reads, built from its pubspec as a hosted
            # package is built from its archive.
            flutter_pub_library_repo(name = library_repo(name), package_name = name)
            flutter_apple_plugin_repo(name = apple_repo(name), package_name = name, version = e.version)
            apple_repos[name] = apple_repo(name)
            flutter_pub_package(
                name = source_repo(name),
                package_name = name,
                version = e.version,
                directory = e.directory,
                path_identity = e.path_identity,
                overlay_roots = overlay_roots,
                code_assets = curated_code_assets(name, e.version),
                ignore_hook = name in ignore_hooks,
                android_deps = annotations.get(name, {}).get("android_deps", []),
                build_config_fields = annotations.get(name, {}).get("build_config_fields", {}),
            )
        elif e.kind == FLUTTER_SOURCE:
            for prefix, sdk in reps.items():
                flutter_pub_library_repo(name = library_repo(name, prefix), package_name = name, prefix = prefix)
                flutter_apple_plugin_repo(name = apple_repo(name, prefix), package_name = name, prefix = prefix, version = e.version)
                if prefix == SPOKE_PREFIX:
                    apple_repos[name] = apple_repo(name)
                files = None
                if sdk.version and not sdk.framework:
                    flutter_source_files(
                        name = files_repo(name, prefix),
                        package_name = name,
                        flutter_version = sdk.version,
                        sha256 = flutter_source_sha256(sdk.version),
                        packages = flutter_sdk_packages(sdk.version),
                    )
                    files = pub_files_label(files_repo(name, prefix))
                flutter_pub_package(
                    name = source_repo(name, prefix),
                    files = files,
                    package_name = name,
                    version = e.version,
                    framework_json = framework_json(sdk.framework) if sdk.framework else None,
                    sdk = sdk.name,
                    prefix = prefix,
                    overlay_roots = overlay_roots,
                    android_deps = annotations.get(name, {}).get("android_deps", []),
                    build_config_fields = annotations.get(name, {}).get("build_config_fields", {}),
                )

    # The build's Android Maven data: what every built spoke's Gradle build
    # declares, against what `@rules_flutter_maven` resolved. An Android app's
    # `flutter_android_plugin_libs` checks the part its plugins need, and a
    # spoke's `android/` package reads what resolved, so only Android builds
    # fetch it.
    flutter_android_maven(
        name = ANDROID_MAVEN_REPO,
        spokes = [
            "@{}//:{}".format(source_repo(name), MAVEN_DEPS_FILE)
            for name in sorted(built.keys())
        ],
    )

    # The build's Apple plugins whose Package.swift decides its defines from
    # the app, which an Apple app builds for itself.
    flutter_apple_app_settings(
        name = APPLE_APP_SETTINGS_REPO,
        packages = sorted(apple_repos.keys()),
    )

    if "flutter_test" in built:
        flutter_pub_goldens(name = GOLDENS_REPO)

    # One hub repo per name, with aliases for the packages of its lock(s). Two
    # tags of one name are one hub holding both locks' packages.
    # flutter_pub.from_lock() always uses `flutter_pub_lock_hub` (not
    # rules_dart's plain `pub_lock_hub`) for its `android/` and `goldens/`
    # packages. Non-Flutter pub.pub() consumers keep using rules_dart's plain
    # hub.
    for hub_name, packages in sorted(hub_packages.items()):
        flutter_pub_lock_hub(
            name = hub_name,
            hub_name = hub_name,
            packages = sorted(packages.keys()),
            built_packages = sorted([n for n in packages if n in built]),
            sdk_packages = [n for n in sdk_packages if n in packages],
            sdk_prefixes = prefixes,
            apple_repos = [apple_repos[n] for n in sorted(packages.keys()) if n in apple_repos],
            swift_package_resolved = hub_resolved.get(hub_name),
        )
