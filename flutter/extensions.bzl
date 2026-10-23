"""Extensions for bzlmod.

Installs a Flutter toolchain and optionally resolves pub dependencies
(including Flutter SDK packages like package:flutter).

Every module can define a toolchain version under the default name, "flutter".
The root module's request wins when it makes one (even when a dependency
requests a newer SDK); without a root request the latest of those versions
will be selected (the rest discarded), and will always be registered by
rules_flutter.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.

The root module can also register custom Flutter releases missing from
`flutter/private/versions.bzl` with `flutter.version(...)`, and can source a
toolchain out of a pre-extracted local SDK with
`flutter.toolchain(local_path = ...)` instead of downloading. See
docs/flutter-sdk-versions.md.
"""

load("@rules_dart//dart/ext:registry.bzl", "curated_code_assets")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_lock")
load("//flutter/private:artifact_urls.bzl", "source_strip_prefix")
load("//flutter/private:flutter_gen_l10n_repo.bzl", "flutter_gen_l10n_repo")
load("//flutter/private:flutter_pub_lock_hub.bzl", "flutter_pub_lock_hub")
load("//flutter/private:flutter_pub_package.bzl", "flutter_pub_package", "flutter_pub_path_package", "is_maven_dep_label")
load("//flutter/private:flutter_pub_path.bzl", "foreign_lock_path_error", "workspace_relative_lock_path")
load("//flutter/private:flutter_sdk_package.bzl", "flutter_sdk_package")
load("//flutter/private:pub_lock_sdks.bzl", "hosted_package_sha256", "parse_lock_sdk_constraints", "version_below_lower_bound")
load("//flutter/private:toolchain_selection.bzl", "select_toolchain_source")
load("//flutter/private:versions.bzl", "custom_engine_base_url", "custom_source_url", "flutter_source_sha256", "merge_custom_versions", "unknown_version_message")
load("//flutter/private:xtool_darwin_sdk_repo.bzl", "resolve_darwin_sdk_from_modules")
load(":repositories.bzl", "flutter_register_toolchains")

_DEFAULT_NAME = "flutter"

# Flutter SDK packages that exist as source under packages/ in the Flutter repo.
# sky_engine is excluded — it provides dart:ui which is already in platform_strong.dill.
_FLUTTER_SDK_PACKAGES = {"flutter": True, "flutter_test": True, "flutter_driver": True, "flutter_localizations": True, "flutter_web_plugins": True, "integration_test": True}

def _fail_on_invalid_maven_deps(hub_name, android_maven_deps):
    """Refuse an `android_maven_deps` value that is not a Bazel label.

    Every value lands in a generated spoke deps list; a non-label is
    refused here, naming the hub and key, rather than emitted into
    BUILD text.
    """
    for _maven_key in android_maven_deps.keys():
        _maven_label = android_maven_deps[_maven_key]
        if not is_maven_dep_label(_maven_label):
            fail((
                "flutter.pub(name = \"{hub}\"): android_maven_deps[{key}] " +
                "is not a valid Bazel label ({label}). Map the " +
                "coordinate to a label in another repository " +
                "(\"@...\") or an absolute label (\"//...\") with no " +
                "quotes, backslashes or newlines."
            ).format(
                hub = hub_name,
                key = _maven_key,
                label = _maven_label,
            ))

flutter_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one Flutter toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
    "flutter_version": attr.string(
        doc = "Version of the Flutter SDK. Either this or `local_path` is " +
              "required, never both. May name a stock release from " +
              "flutter/private/versions.bzl or a custom version registered " +
              "with `flutter.version` in the root module.",
        default = "",
    ),
    "local_path": attr.string(
        doc = "Path to a pre-extracted Flutter SDK (bin/cache layout) to " +
              "source the toolchain from instead of downloading. Root-only, " +
              "and mutually exclusive with `flutter_version`. A relative " +
              "path resolves against the main workspace root.",
        default = "",
    ),
})

flutter_version = tag_class(attrs = {
    "version": attr.string(
        doc = "Flutter release tag to register (e.g. `\"3.44.8\"`). Must " +
              "not already be listed in flutter/private/versions.bzl.",
        mandatory = True,
    ),
    "engine_revision": attr.string(
        doc = "Engine commit hash the release's artifacts are published under.",
        mandatory = True,
    ),
    "source_sha256": attr.string(
        doc = "SHA-256 of the framework source tarball (`source_url`, by " +
              "default the GitHub tag tarball of `version`).",
        mandatory = True,
    ),
    "material_fonts_url": attr.string(
        doc = "GCS path of the Material icon font bundle for the release " +
              "(a full https:// URL is used as-is).",
        mandatory = True,
    ),
    "artifact_sha256": attr.string_dict(
        doc = "Engine artifact path → SHA-256, keyed exactly like " +
              "ARTIFACT_CHECKSUMS. Every artifact the repositories fetch " +
              "needs an entry; a needed artifact without one fails the " +
              "fetch naming the artifact and the version.",
        default = {},
    ),
    "engine_base_url": attr.string(
        doc = "Replacement origin serving the engine revision directory " +
              "(an enterprise build). Empty means the default GCS base. " +
              "Plain mirrors stay Bazel's job (`--downloader_config`).",
        default = "",
    ),
    "source_url": attr.string(
        doc = "Replacement framework source tarball URL. Empty means the " +
              "default GitHub tag tarball of `version`. Plain mirrors stay " +
              "Bazel's job (`--downloader_config`).",
        default = "",
    ),
})

_flutter_pub = tag_class(attrs = {
    "name": attr.string(
        doc = "Repository name for the resolved packages hub.",
        mandatory = True,
    ),
    "lock": attr.label(
        doc = "The pubspec.lock file to parse.",
        mandatory = True,
        allow_single_file = True,
    ),
    "ignore_hooks": attr.string_list(
        doc = "Pub package names whose `hook/build.dart` is knowingly " +
              "irrelevant to this build (its native code is never reached). " +
              "Suppresses the unreplaced-hook error for them. This is a " +
              "declaration you make deliberately; it is never a default.",
        default = [],
    ),
    "android_maven_deps": attr.string_dict(
        doc = "`group:artifact` -> Bazel label additions to the built-in " +
              "mapping from a plugin's `android/build.gradle*` runtime " +
              "dependencies to `@rules_android_maven` labels. A plugin dep " +
              "found in neither table fails the spoke fetch; mapping it " +
              "here is the fix for external artifacts. The label must " +
              "resolve in the workspace's `rules_android_maven` install.",
        default = {},
    ),
    "android_maven_ignore": attr.string_list(
        doc = "`group:artifact` coordinates that need no Bazel label and " +
              "must not fail the spoke fetch as unknown. This is a " +
              "declaration you make deliberately; it is never a default.",
        default = [],
    ),
})

_flutter_plugin_overlays = tag_class(attrs = {
    "roots": attr.label_list(
        doc = "BUILD.bazel anchors for user-supplied overlay trees. Each " +
              "label points at an `ext/BUILD.bazel` (or equivalent) that " +
              "anchors a directory tree of `<package>/<version>/BUILD.bazel.tpl` " +
              "overrides. flutter_pub_package walks user roots first, then the " +
              "bundled `@rules_flutter//ext:BUILD.bazel`. A template declares " +
              "its language version and its dependencies by placeholder " +
              "(`{LANGUAGE_VERSION}`, `{DEPS}`), never by hand; see " +
              "docs/TESTING.md \"Native Assets overlay authoring\".",
        allow_files = True,
        default = [],
    ),
})

_flutter_darwin_sdk = tag_class(
    doc = (
        "Root-module-only configuration for the opt-in xtool Darwin SDK (`@flutter_xtool_darwin_sdk`). " +
        "Specify either `url` + `sha256` (hermetic) or `path` (local, non-hermetic). " +
        "IMPORTANT (Apple SDK licensing): `rules_flutter` never downloads or bundles an Apple SDK by default " +
        "(`url` and `path` both default to `\"\"`). Users must obtain and supply their own `darwin.artifactbundle` " +
        "(`iPhoneOS.sdk`, `iPhoneSimulator.sdk`, `MacOSX.sdk`) in compliance with the Apple Xcode and Apple SDKs Agreement."
    ),
    attrs = {
        "path": attr.string(
            doc = "Optional local filesystem path to a user-supplied `darwin.artifactbundle` for the xtool backend (local, non-hermetic; mutually exclusive with `url`). Subject to Apple's SDK licensing terms.",
            default = "",
        ),
        "url": attr.string(
            doc = "Optional URL to download a user-supplied `darwin.artifactbundle` archive for the xtool backend (hermetic; requires `sha256` and is mutually exclusive with `path`). No default URL is provided; users must supply their own SDK under Apple's terms.",
            default = "",
        ),
        "sha256": attr.string(
            doc = "Required SHA-256 checksum when `url` is specified.",
            default = "",
        ),
        "swift_toolchain_path": attr.string(
            doc = "Optional local path to the Linux Swift toolchain root directory (local, non-hermetic).",
            default = "",
        ),
    },
)

# Exec-host pairs the xtool repo can symlink a hermetic LLVM tree for, in a
# fixed order shared with the repo rule (index = 2 * is_macos + is_x86_64).
_LLVM_TOOL_EXECS = (
    ("linux", "aarch64"),
    ("linux", "x86_64"),
    ("macos", "aarch64"),
    ("macos", "x86_64"),
)

def _llvm_tool_repos_for_modules(*, modules, sdk_configured):
    """Apparent names of llvm's per-host prebuilt-toolchain repos.

    The names (`llvm-toolchain-minimal-<os>-<cpu>`) are imported into
    rules_flutter's own repo mapping by this module's `use_repo` on llvm's
    toolchain extension, so the xtool repo rule resolves them there — plain
    strings cross the extension boundary because a `Label(...)` built in an
    extension implementation cannot see them. The xtool repo only resolves
    (fetches) the entry matching the exec host, and only when the returned
    list is non-empty. The list is non-empty exactly when LLVM may be
    linked: the root module opted into a Darwin SDK, or this evaluation runs
    for rules_flutter itself (whose hermetic-LLVM script tests assert the
    linkage with no SDK configured). Plain consumers get `[]`: no LLVM label
    is ever built for them, so no LLVM repository is fetched.
    Same host mapping as `resource_dir_arg` in `@llvm//toolchain:selects.bzl`.
    """
    self_root = False
    for mod in modules:
        if mod.is_root and mod.name == "rules_flutter":
            self_root = True
            break
    if not sdk_configured and not self_root:
        return []
    names = []
    for (exec_os, exec_cpu) in _LLVM_TOOL_EXECS:
        os_part = "darwin" if exec_os == "macos" else exec_os
        cpu_part = "amd64" if exec_cpu == "x86_64" else "arm64"
        names.append("llvm-toolchain-minimal-%s-%s" % (os_part, cpu_part))
    return names

def _collect_custom_tags(modules):
    """Collects `flutter.version` tags as structs for version-table merging."""
    return [
        struct(
            version = tag.version,
            engine_revision = tag.engine_revision,
            source_sha256 = tag.source_sha256,
            material_fonts_url = tag.material_fonts_url,
            artifact_sha256 = tag.artifact_sha256,
            engine_base_url = tag.engine_base_url,
            source_url = tag.source_url,
            is_root = mod.is_root,
        )
        for mod in modules
        for tag in mod.tags.version
    ]

def _collect_lock_floors(module_ctx):
    """Collects pub-lock Flutter floors, keyed by lock label string.

    In download mode these are checked at evaluation; in local mode they
    travel with the toolchain registration and each host repo checks them
    once the SDK is read (the version is only known then).
    """
    lock_flutter_constraints = {}
    for mod in module_ctx.modules:
        for pub_tag in mod.tags.pub:
            constraint = parse_lock_sdk_constraints(module_ctx.read(pub_tag.lock)).get("flutter", "")
            if constraint:
                lock_flutter_constraints[str(pub_tag.lock)] = constraint
    return lock_flutter_constraints

def _collect_registrations(modules):
    """Validates `flutter.toolchain` tags and groups them by toolchain name."""
    registrations = {}
    for mod in modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the Flutter toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if toolchain.local_path and not mod.is_root:
                fail("Only the root module may source a Flutter toolchain from a local SDK (local_path); dependencies must request downloadable versions.")
            if toolchain.local_path and toolchain.flutter_version:
                fail("flutter.toolchain(local_path = ...) is mutually exclusive with downloading: set exactly one of local_path and flutter_version.")
            if not toolchain.local_path and not toolchain.flutter_version:
                fail("flutter.toolchain() needs exactly one of flutter_version and local_path.")
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
            registrations[toolchain.name].append(struct(
                version = toolchain.flutter_version,
                local_path = toolchain.local_path,
                is_root = mod.is_root,
                module = mod.name,
            ))
    return registrations

def _register_local_toolchain(name, local_path, lock_flutter_constraints, darwin_sdk, llvm_tool_repos):
    """Registers one local-SDK toolchain and its gen-l10n repo."""
    flutter_register_toolchains(
        name = name,
        local_path = local_path,
        flutter_constraints = lock_flutter_constraints,
        darwin_sdk_path = darwin_sdk.path,
        darwin_sdk_url = darwin_sdk.url,
        darwin_sdk_sha256 = darwin_sdk.sha256,
        darwin_sdk_swift_toolchain_path = darwin_sdk.swift_toolchain_path,
        darwin_sdk_llvm_tool_repos = llvm_tool_repos,
    )
    flutter_gen_l10n_repo(
        name = name + "_gen_l10n",
        hub_name = "gen_l10n_deps",
        local_path = local_path,
    )
    return struct(version = "", local_path = local_path)

def _register_download_toolchain(name, selected, merged, darwin_sdk, llvm_tool_repos):
    """Registers one downloaded toolchain and its gen-l10n repo."""
    if selected not in merged.versions:
        fail(unknown_version_message(selected))
    meta = merged.versions[selected]
    version_source_url = custom_source_url(selected, merged.source_urls)
    flutter_register_toolchains(
        name = name,
        flutter_version = selected,
        engine_revision = meta.engine_revision,
        source_sha256 = flutter_source_sha256(selected, merged.versions),
        material_fonts_url = meta.material_fonts_url,
        artifact_sha256s = merged.checksums[selected],
        engine_base_url = custom_engine_base_url(selected, merged.engine_base_urls),
        source_url = version_source_url,
        source_strip_prefix = source_strip_prefix(selected, version_source_url),
        darwin_sdk_path = darwin_sdk.path,
        darwin_sdk_url = darwin_sdk.url,
        darwin_sdk_sha256 = darwin_sdk.sha256,
        darwin_sdk_swift_toolchain_path = darwin_sdk.swift_toolchain_path,
        darwin_sdk_llvm_tool_repos = llvm_tool_repos,
    )

    # The gen-l10n generator, carved out of the same release's
    # flutter_tools. Declared unconditionally because bzlmod repositories
    # are lazy: a workspace that never references `@{name}_gen_l10n` never
    # fetches the tarball, the same way gen_snapshot repos work.
    flutter_gen_l10n_repo(
        name = name + "_gen_l10n",
        flutter_version = selected,
        sha256 = flutter_source_sha256(selected, merged.versions),
        hub_name = "gen_l10n_deps",
        source_url = version_source_url,
        source_strip_prefix = source_strip_prefix(selected, version_source_url),
    )
    return struct(version = selected, local_path = "")

def _register_all_toolchains(module_ctx, registrations, merged, lock_flutter_constraints, darwin_sdk):
    """Registers every requested toolchain; returns name → selected info."""
    selected_info = {}
    for name, requests in registrations.items():
        source = select_toolchain_source(name, requests)
        if source.note:
            # buildifier: disable=print
            print("NOTE: " + source.note)
        llvm_tool_repos = _llvm_tool_repos_for_modules(
            modules = module_ctx.modules,
            sdk_configured = darwin_sdk.configured,
        )
        if source.local_path:
            selected_info[name] = _register_local_toolchain(name, source.local_path, lock_flutter_constraints, darwin_sdk, llvm_tool_repos)
            continue
        selected_info[name] = _register_download_toolchain(name, source.version, merged, darwin_sdk, llvm_tool_repos)
    return selected_info

def _check_pub_flutter_floor(lock_content, toolchain_info, pub_tag):
    """Fails when the lock's Flutter floor exceeds the pinned toolchain.

    This is the one moment where the SDK that resolved the lock and
    the SDK that will consume it are both in view. Pub does not
    record the resolver's version, but it does record the floor its
    solution needs; a toolchain below that floor cannot compile what
    the lock pins. A local SDK reads its version out of
    bin/cache/flutter.version.json at fetch time, so in local mode
    the floor travels with the toolchain registration (see above)
    and each host repo checks it once the SDK is read; only the
    download-mode pin is checked here.
    """
    flutter_constraint = parse_lock_sdk_constraints(lock_content).get("flutter", "")
    flutter_version = toolchain_info.version
    if flutter_constraint and flutter_version and version_below_lower_bound(flutter_version, flutter_constraint):
        fail((
            "{lock} was resolved against a newer Flutter than this " +
            "build pins: the lock requires flutter {constraint}, and " +
            "flutter.toolchain() pins {version}.\n" +
            "Either raise flutter.toolchain(flutter_version = ...) or " +
            "re-resolve with the pinned toolchain:\n" +
            "    bazel run @rules_flutter//flutter:pub -- upgrade"
        ).format(
            lock = str(pub_tag.lock),
            constraint = flutter_constraint,
            version = flutter_version,
        ))

def _fail_on_odd_package_name(hub_name, package_name):
    """Refuse a lock package name that cannot survive BUILD emission.

    Pub package names are lowercase letters, digits and underscores, but a
    hand-edited lock can say anything; the name lands in spoke repository
    names, hub aliases and generated target names. Anything holding a quote,
    a backslash, a newline, whitespace or a label separator fails here,
    naming the hub and the package, rather than emitting it into BUILD text.
    """
    for ch in ['"', "\\", "\n", "\r", " ", "\t", ":", "/"]:
        if ch in package_name:
            fail((
                "flutter.pub hub \"{hub}\": package name {name} cannot be " +
                "a Bazel target name. Rename the package rather than " +
                "emitting a hub that cannot name it."
            ).format(
                hub = hub_name,
                name = repr(package_name),
            ))

def _classify_lock_packages(hub_name, lock_label, lock_pkgs):
    """Splits lock packages into hosted, path, Flutter-SDK, and all names."""
    hosted = {}
    path_pkgs = {}
    sdk_flutter = {}
    all_package_names = []
    for name, info in lock_pkgs.items():
        _fail_on_odd_package_name(hub_name, name)
        source = info.get("source", "unknown")
        if source == "hosted":
            hosted[name] = info
            all_package_names.append(name)
        elif source == "path":
            desc = info.get("description", {})
            entry_path = desc.get("path", "") if type(desc) == "dict" else ""
            if not entry_path or (type(desc) == "dict" and not desc.get("relative", False)):
                fail("flutter.pub hub \"{hub}\": path dependency \"{pkg}\" has no workspace-relative path in the lock. Re-resolve the lock with a relative `path:` dependency.".format(
                    hub = hub_name,
                    pkg = name,
                ))
            refusal = foreign_lock_path_error(hub_name, name, lock_label)
            if refusal:
                fail(refusal)
            path_pkgs[name] = struct(
                path = workspace_relative_lock_path(hub_name, name, lock_label, entry_path),
                version = info.get("version", ""),
            )
            all_package_names.append(name)
        elif source == "sdk":
            if name in _FLUTTER_SDK_PACKAGES:
                sdk_flutter[name] = info
                all_package_names.append(name)
        else:
            # Reason for print: warn the user that a locked package is
            # silently unsupported (not an error; the build proceeds).
            # buildifier: disable=print
            print("flutter.pub: skipping package \"{}\" (source: {}). Only hosted, path, and Flutter SDK packages are supported.".format(name, source))
    return hosted, path_pkgs, sdk_flutter, all_package_names

def _create_hosted_spokes(hub_name, hosted, all_package_names, user_overlay_roots, pub_tag, ignore_hooks):
    """Creates one `flutter_pub_package` spoke per hosted package.

    flutter.pub() routes every hosted package through flutter_pub_package —
    the `flutter pub get` analog — so plugins surface their
    `flutter.plugin.platforms` metadata via FlutterInfo. Pure-Dart
    packages still emit a plain `dart_library`; the rule branches
    internally on whether a `flutter.plugin` block is present.
    Non-Flutter modules using `pub.pub()` keep using rules_dart's
    `pub_lock_package` directly.
    """
    for name, info in hosted.items():
        desc = info.get("description", {})
        version = info.get("version", "")

        # Hosted packages are fetched by checksum only. An entry with
        # no sha256 is a lock that predates the field, or was edited
        # by hand; refuse it rather than download unverified bytes.
        sha256 = hosted_package_sha256(name, info, pub_tag.lock)

        flutter_pub_package(
            name = hub_name + "__" + name,
            package_name = name,
            version = version,
            sha256 = sha256,
            base_url = desc.get("url", "https://pub.dev") if type(desc) == "dict" else "https://pub.dev",
            hub_name = hub_name,
            lock_packages = all_package_names,
            overlay_roots = user_overlay_roots + ["@rules_flutter//ext:BUILD.bazel"],
            # rules_dart's curated registry is the single source of
            # truth for which pub package a Bazel-built native library
            # stands in for, and at which versions. Consulting it here
            # is what makes a Flutter app depending on, say, `drift`
            # get `sqlite3`'s library without naming it: the asset
            # lands on the package that owns it, so it propagates
            # through the Dart graph exactly as pub's own would.
            code_assets = curated_code_assets(name, version),
            ignore_hook = name in ignore_hooks,
            android_maven_deps = pub_tag.android_maven_deps,
            android_maven_ignore = pub_tag.android_maven_ignore,
        )

def _create_path_spokes(hub_name, path_pkgs, all_package_names, user_overlay_roots, ignore_hooks):
    """Creates one `flutter_pub_path_package` spoke per path dependency.

    The package directory is symlinked in from the workspace (resolved
    against the lock file's directory at classification time) and watched
    for changes; the spoke then runs the same generator pipeline as a
    hosted package, so assets, fonts, shaders, and plugin metadata surface
    identically — including the `android/BUILD.bazel` stub the hub's
    `all_android_plugin_libs` aggregator depends on uniformly.
    """
    for name, path_info in path_pkgs.items():
        flutter_pub_path_package(
            name = hub_name + "__" + name,
            package_name = name,
            path = path_info.path,
            version = path_info.version,
            hub_name = hub_name,
            lock_packages = all_package_names,
            overlay_roots = user_overlay_roots + ["@rules_flutter//ext:BUILD.bazel"],
            code_assets = curated_code_assets(name, path_info.version),
            ignore_hook = name in ignore_hooks,
        )

def _create_sdk_spokes(hub_name, sdk_flutter, all_package_names, toolchain_info, merged, flutter_version):
    """Creates one `flutter_sdk_package` spoke per Flutter SDK package.

    In download mode each pins the same framework source tarball, so the
    checksum is read once here for all of them; custom-source overrides
    travel with the release. In local mode each symlinks the package out
    of the local SDK tree instead.
    """
    if toolchain_info.local_path:
        for name in sdk_flutter.keys():
            flutter_sdk_package(
                name = hub_name + "__" + name,
                package_name = name,
                local_path = toolchain_info.local_path,
                hub_name = hub_name,
                lock_packages = all_package_names,
            )
        return
    sdk_source_sha256 = flutter_source_sha256(flutter_version, merged.versions)
    sdk_source_url = custom_source_url(flutter_version, merged.source_urls)
    for name in sdk_flutter.keys():
        flutter_sdk_package(
            name = hub_name + "__" + name,
            package_name = name,
            flutter_version = flutter_version,
            sha256 = sdk_source_sha256,
            hub_name = hub_name,
            lock_packages = all_package_names,
            source_url = sdk_source_url,
            source_strip_prefix = source_strip_prefix(flutter_version, sdk_source_url),
        )

def _register_pub_hub(module_ctx, pub_tag, selected_info, merged, user_overlay_roots):
    """Resolves one `flutter.pub` tag into spoke repos plus the hub repo."""
    hub_name = pub_tag.name

    _fail_on_invalid_maven_deps(hub_name, pub_tag.android_maven_deps)
    lock_content = module_ctx.read(pub_tag.lock)
    lock_pkgs = parse_pubspec_lock(lock_content)

    # Determine the Flutter version to use for SDK packages.
    # Use the default toolchain version; fail if no toolchain is registered.
    toolchain_info = selected_info.get(_DEFAULT_NAME)
    if not toolchain_info:
        fail("flutter.pub() requires a flutter.toolchain() to be registered.")

    _check_pub_flutter_floor(lock_content, toolchain_info, pub_tag)

    hosted, path_pkgs, sdk_flutter, all_package_names = _classify_lock_packages(hub_name, pub_tag.lock, lock_pkgs)
    ignore_hooks = {pkg_name: True for pkg_name in pub_tag.ignore_hooks}
    _create_hosted_spokes(hub_name, hosted, all_package_names, user_overlay_roots, pub_tag, ignore_hooks)
    _create_path_spokes(hub_name, path_pkgs, all_package_names, user_overlay_roots, ignore_hooks)
    _create_sdk_spokes(hub_name, sdk_flutter, all_package_names, toolchain_info, merged, toolchain_info.version)

    # Create hub repo with aliases for all packages plus the
    # Android plugin-libs aggregator. flutter.pub() always uses
    # `flutter_pub_lock_hub` (not rules_dart's plain
    # `pub_lock_hub`) because the Tier-1 `flutter_android_app`
    # macro needs `@<hub>//android:all_android_plugin_libs` to
    # auto-wire transitively-collected plugin Kotlin/Java into
    # the final APK. Non-Flutter pub.pub() consumers keep using
    # rules_dart's plain hub.
    flutter_pub_lock_hub(
        name = hub_name,
        hub_name = hub_name,
        packages = sorted(all_package_names),
    )

def _collect_overlay_roots(modules):
    """Collects user-supplied plugin overlay roots from tags.

    Applied to every flutter_pub_package invocation in the order seen,
    then the bundled `@rules_flutter//ext` root. This makes any pub
    plugin user-fixable locally — drop a
    `<workspace>/plugin_overlays/<pkg>/<major>/BUILD.bazel.tpl` and
    register the root in MODULE.bazel; the next build picks it up.
    """
    user_overlay_roots = []
    for mod in modules:
        for tag in mod.tags.plugin_overlays:
            user_overlay_roots.extend(tag.roots)
    return user_overlay_roots

def _toolchain_extension(module_ctx):
    darwin_sdk = resolve_darwin_sdk_from_modules(module_ctx.modules)

    # Custom versions first: every later lookup resolves against the merged
    # tables, so a custom release behaves exactly like a stock one.
    merged = merge_custom_versions(_collect_custom_tags(module_ctx.modules))

    # Pub lock floors, collected before any toolchain registers: download mode
    # checks them at evaluation below, while local mode hands them to the
    # host repos, which check them against the local SDK's own version at
    # fetch time (the version is only known once the SDK is read).
    lock_flutter_constraints = _collect_lock_floors(module_ctx)

    registrations = _collect_registrations(module_ctx.modules)
    selected_info = _register_all_toolchains(module_ctx, registrations, merged, lock_flutter_constraints, darwin_sdk)

    # Collect user-supplied overlay roots from `flutter.plugin_overlays(...)`
    # tags. They're applied to every flutter_pub_package invocation in
    # the order seen, then the bundled `@rules_flutter//ext` root.
    user_overlay_roots = _collect_overlay_roots(module_ctx.modules)

    # Handle flutter.pub() tags — resolve pubspec.lock with Flutter SDK support.
    for mod in module_ctx.modules:
        for pub_tag in mod.tags.pub:
            _register_pub_hub(module_ctx, pub_tag, selected_info, merged, user_overlay_roots)

    # Don't declare root_module_direct_deps: flutter_register_toolchains creates
    # many repos (iOS, Android, web, desktop, cross-compile per platform) and
    # each user workspace only needs a subset — a macOS-only app doesn't want
    # Android engine repos forced into its use_repo. Declaring a strict subset
    # makes `bazel mod tidy` strip out repos the user actually needs; declaring
    # the full set makes tidy force repos they don't. Letting users maintain
    # their own use_repo lists (rules_python does the same) is the right
    # tradeoff for an extension with this many optional outputs.
    return module_ctx.extension_metadata(reproducible = True)

flutter = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {
        "toolchain": flutter_toolchain,
        "version": flutter_version,
        "pub": _flutter_pub,
        "plugin_overlays": _flutter_plugin_overlays,
        "darwin_sdk": _flutter_darwin_sdk,
    },
    os_dependent = False,
    arch_dependent = False,
    doc = "Installs a Flutter SDK toolchain and optionally resolves pub dependencies including Flutter SDK packages.",
)
