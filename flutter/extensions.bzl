"""Extensions for bzlmod.

`flutter` installs the Flutter SDKs and their toolchains. The pub dependency
extension is `pub` in `@rules_flutter//flutter/pub:extensions.bzl`; it is its
own extension so that a lock it refuses breaks only the builds that use its
repositories, never the toolchains, and `bazel run @rules_flutter//flutter/pub`,
which fixes the lock, still runs.

Every module can ask for a toolchain version under the default name, "flutter",
which rules_flutter always registers. The root module's version is the one
used; without one, the highest version any module asks for is used.

The root module can declare more toolchains under other names (each name
resolved the same way) and register them as it sees fit, overriding the default
one by toolchain resolution precedence.
"""

load("@rules_dart//dart:repositories.bzl", "dart_kernel_source")
load("//flutter/private:constants.bzl", "ANDROID_ABI_FOR_ARCH")
load("//flutter/private:engine_labels.bzl", "android_arches")
load("//flutter/private:flutter_android_emulator_repo.bzl", "flutter_android_emulator_repo", "flutter_android_system_image_repo")
load("//flutter/private:flutter_chrome_for_testing.bzl", "flutter_chrome_for_testing")
load("//flutter/private:flutter_dev_root_repo.bzl", "flutter_dev_root_repo")
load("//flutter/private:flutter_face_repo.bzl", "IOS_ENGINE_EXTRA", "IOS_ENGINE_TARGETS", "MACOS_ENGINE_EXTRA", "MACOS_ENGINE_TARGETS", "WEB_SDK_TARGETS", "android_engine_face_extra", "flutter_face_repo")
load("//flutter/private:flutter_linux_runtime_repo.bzl", "flutter_linux_runtime_repo")
load("//flutter/private:flutter_material_fonts_repo.bzl", "flutter_material_fonts_repo")
load("//flutter/private:flutter_sdk_toolchains_repo.bzl", "flutter_sdk_toolchains_repo")
load("//flutter/private:flutter_sdks_repo.bzl", "encode_sdks", "flutter_sdks_repo")
load("//flutter/private:linux_runtime_pins.bzl", "LINUX_RUNTIME")
load("//flutter/private:pub_extension.bzl", "DEFAULT_SDK_NAME", "framework_json")
load("//flutter/private:repositories.bzl", "flutter_register_toolchains")
load("//flutter/private:toolchain_version.bzl", "select_flutter_version")
load("//flutter/private:toolchains_repo.bzl", "flutter_toolchains_repo", "sdk_repo_name")
load("//flutter/private:versions.bzl", "ANDROID_EMULATOR", "ANDROID_SYSTEM_IMAGE", "CHROME_FOR_TESTING", "FLUTTER_VERSIONS", "flutter_source_sha256", "require_supported_flutter_version")

flutter_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
The name of the SDK this declares. `flutter` is the stock release (or the SDK a
team always builds against, given sources); any other name is another SDK, which
a build chooses with `--@rules_flutter//flutter:sdk=<name>`. A name other than
the default is only permitted in the root module.
""", default = DEFAULT_SDK_NAME),
    "flutter_version": attr.string(doc = """\
Version of the Flutter release that supplies whichever half of the SDK is not
given as `framework` or `engine`. An error when both are given, and required
when either is not.
"""),
    "framework": attr.label(doc = """\
A repository whose root is a flutter/flutter tree and which holds
`flutter_framework.json` (the framework contract): the SDK's packages come from
it instead of the release. Root module only.
"""),
    "engine": attr.label(doc = """\
A repository whose slices are the engine contract's labels (see
`@rules_flutter//flutter:engine.bzl`): the SDK's engine comes from it instead of
the release. Root module only.
"""),
    "allow_upgrade_by_dependencies": attr.bool(doc = """\
Root module only. When False (the default) the root's `flutter_version` is used
exactly, and a dependency asking for a newer release fails the build. When True,
the highest version any module asks for is used. As `dart.toolchain`'s attribute
of the same name.
"""),
    "material_fonts_sha256": attr.string(doc = """\
The checksum of the Material fonts archive a non-release framework expects, when
its `bin/internal/material_fonts.version` names an archive no pinned release does.
"""),
})

def _declared_sdks(module_ctx):
    """The SDKs the modules declare: a struct for each, by name."""

    # The root module's version for a name is used exactly; a dependency asking
    # for newer fails, unless the root sets `allow_upgrade_by_dependencies`.
    # A name the root does not pin takes the highest version asked for.
    tags = {}
    requests = {}
    root_versions = {}
    allow_upgrade = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != DEFAULT_SDK_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the Flutter toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if mod.is_root and toolchain.flutter_version:
                if toolchain.name in root_versions and root_versions[toolchain.name] != toolchain.flutter_version:
                    fail("The root module declares the Flutter toolchain {} twice, with versions {} and {}.".format(
                        toolchain.name,
                        root_versions[toolchain.name],
                        toolchain.flutter_version,
                    ))
                root_versions[toolchain.name] = toolchain.flutter_version
            if toolchain.allow_upgrade_by_dependencies:
                if not mod.is_root:
                    fail((
                        "flutter.toolchain(name = \"{}\") in module {} sets allow_upgrade_by_dependencies. " +
                        "Only the root module may: a library must not decide the SDK of the apps that use it."
                    ).format(toolchain.name, mod.name))
                allow_upgrade[toolchain.name] = True
            if (toolchain.framework or toolchain.engine) and not mod.is_root:
                fail((
                    "flutter.toolchain(name = \"{}\") in module {} gives a framework or an engine. " +
                    "Only the root module may: a library module must not impose a fork on its dependents."
                ).format(toolchain.name, mod.name))
            tags.setdefault(toolchain.name, []).append(toolchain)
            requests.setdefault(toolchain.name, [])
            if toolchain.flutter_version:
                requests[toolchain.name].append((mod.name, toolchain.flutter_version))

    sdks = {}
    for name, name_tags in tags.items():
        versions = [t.flutter_version for t in name_tags if t.flutter_version]
        frameworks = {str(t.framework): t.framework for t in name_tags if t.framework}
        engines = {str(t.engine): t.engine for t in name_tags if t.engine}
        if len(frameworks) > 1 or len(engines) > 1:
            fail("flutter.toolchain(name = \"{}\") is declared with more than one framework or engine.".format(name))
        framework = frameworks.values()[0] if frameworks else None
        engine = engines.values()[0] if engines else None
        if framework and engine and versions:
            fail((
                "flutter.toolchain(name = \"{}\") gives a framework and an engine, so its " +
                "flutter_version = \"{}\" would be unused. Drop it."
            ).format(name, versions[0]))
        if not (framework and engine) and not versions:
            fail((
                "flutter.toolchain(name = \"{}\") needs flutter_version: the release that " +
                "supplies the half of the SDK that is not given."
            ).format(name))
        selected = None
        if versions:
            selection = select_flutter_version(name, root_versions.get(name), requests[name], allow_upgrade.get(name, False))
            if selection.error:
                fail(selection.error)
            selected = selection.version
        if selected:
            require_supported_flutter_version(selected)
        fonts_sha256 = [t.material_fonts_sha256 for t in name_tags if t.material_fonts_sha256]
        sdks[name] = struct(
            name = name,
            version = selected,
            framework = framework,
            engine = engine,
            material_fonts_sha256 = fonts_sha256[0] if fonts_sha256 else "",
        )
    if DEFAULT_SDK_NAME not in sdks:
        fail("A flutter.toolchain() is required: the default SDK, named \"{}\".".format(DEFAULT_SDK_NAME))
    return sdks

def _label_prefix(label):
    """A label's repository, as a prefix any repository can name it by."""
    return "@@" + label.repo_name

def _register_sdk(sdk):
    """Declares the repositories of one SDK; returns the label prefix of its engine source."""
    name = sdk.name
    if sdk.engine == None and sdk.framework == None:
        # The release, with the artifact repositories it is made of.
        flutter_register_toolchains(name = name, flutter_version = sdk.version)
        return "@{}_stock_engine".format(name)

    # The Material fonts come with the framework: the ones its
    # `bin/internal/material_fonts.version` names, or the release's.
    fonts = name + "_material_fonts"
    flutter_material_fonts_repo(
        name = fonts,
        flutter_version = sdk.version or "",
        framework_json = framework_json(sdk.framework) if sdk.framework else None,
        sha256 = sdk.material_fonts_sha256,
    )
    fonts_label = "@{}//:material-fonts/MaterialIcons-Regular.otf".format(fonts)
    if sdk.engine == None:
        # A framework of the root module's choosing over the release engine,
        # with the artifact repositories it is made of.
        flutter_register_toolchains(
            name = name,
            flutter_version = sdk.version,
            framework_json = str(framework_json(sdk.framework)),
            framework_json_file = framework_json(sdk.framework),
            material_fonts = fonts_label,
        )
        return "@{}_stock_engine".format(name)

    # An engine of the root module's choosing: the toolchains are written
    # against its slices.
    flutter_sdk_toolchains_repo(
        name = sdk_repo_name(name),
        engine = _label_prefix(sdk.engine),
        sdk = name,
        version = sdk.version or "",
        material_fonts = fonts_label,
        sysroot_prefix = DEFAULT_SDK_NAME,
        framework_json = str(framework_json(sdk.framework)) if sdk.framework else "",
        framework_json_file = framework_json(sdk.framework) if sdk.framework else None,
        engine_json_file = Label("@@{}//:flutter_engine.json".format(sdk.engine.repo_name)),
    )
    return _label_prefix(sdk.engine)

def _toolchain_extension(module_ctx):
    sdks = _declared_sdks(module_ctx)
    engine_prefixes = {}
    outline_packages = {}
    for name in sorted(sdks.keys()):
        sdk = sdks[name]
        engine_prefixes[name] = _register_sdk(sdk)

        # The SDK's dev root, for `@rules_flutter//flutter/pub`. Declared
        # unconditionally because bzlmod repositories are lazy: a workspace
        # that never references it never fetches the tarball.
        released = sdk.version and not sdk.framework
        flutter_dev_root_repo(
            name = name + "_dev_root_src",
            flutter_version = sdk.version or "",
            framework_json = framework_json(sdk.framework) if sdk.framework else None,
            sky_engine = (
                "@@{}//sky_engine:pubspec.yaml".format(sdk.engine.repo_name) if sdk.engine else "@{}_sky_engine//sky_engine:pubspec.yaml".format(name)
            ) if sdk.framework else None,
            engine_json = "@@{}//:flutter_engine.json".format(sdk.engine.repo_name) if sdk.engine else None,
            sha256 = flutter_source_sha256(sdk.version) if released else "",
        )

        # The outline stripper for this SDK's Dart. A release engine's is
        # built from that Dart release's pinned source; a custom engine
        # provides its own (the contract's `//outline_tool:outline_tool`).
        # Fetched only with `--@rules_dart//dart:outline_kernel`.
        if sdk.engine == None:
            dart_kernel_source(
                name = name + "_outline_tool_src",
                dart_version = FLUTTER_VERSIONS[sdk.version].dart_version,
            )
            outline_packages[name] = "@{}_outline_tool_src//".format(name)
        else:
            outline_packages[name] = _label_prefix(sdk.engine) + "//outline_tool"

    # The repositories rules_flutter and its users name by fixed names, each
    # an alias into the selected SDK's own.
    flutter_face_repo(
        name = "flutter_macos_engine",
        sdks = engine_prefixes,
        targets = MACOS_ENGINE_TARGETS,
        extra = MACOS_ENGINE_EXTRA,
    )
    flutter_face_repo(
        name = "flutter_ios_engine",
        sdks = engine_prefixes,
        targets = IOS_ENGINE_TARGETS,
        extra = IOS_ENGINE_EXTRA,
    )
    flutter_face_repo(
        name = "flutter_web_sdk",
        sdks = engine_prefixes,
        targets = WEB_SDK_TARGETS,
    )
    for arch in android_arches():
        flutter_face_repo(
            name = "flutter_android_engine_" + arch,
            sdks = engine_prefixes,
            targets = {},
            extra = android_engine_face_extra(engine_prefixes, arch, ANDROID_ABI_FOR_ARCH[arch]),
        )
    flutter_face_repo(
        name = "flutter_outline_tool",
        sdks = outline_packages,
        targets = {"outline_tool": "{prefix}:outline_tool"},
    )
    flutter_face_repo(
        name = "flutter_dev_root",
        sdks = {name: "@{}_dev_root_src".format(name) for name in sdks},
        targets = {"dev_root": "{prefix}//:dev_root", "version_manifest": "{prefix}//:version_manifest"},
    )

    # What the `pub` extension needs of the SDKs: it cannot see the toolchain tags.
    flutter_sdks_repo(
        name = "flutter_sdks",
        sdks = encode_sdks(sdks),
    )

    # Every SDK's toolchains, chosen among by `--@rules_flutter//flutter:sdk`.
    flutter_toolchains_repo(
        name = "flutter_toolchains",
        sdks = sorted(sdks.keys()),
    )

    # The browser web integration tests run in, one repository per host it is
    # built for. Declared unconditionally: a repository is fetched only when
    # something references it, and only the `chrome` runner of
    # `//flutter/integration_test` does, selecting the host's own.
    for platform, sha256 in CHROME_FOR_TESTING.sha256.items():
        flutter_chrome_for_testing(
            name = "flutter_chrome_for_testing_" + platform.replace("-", "_"),
            platform = platform,
            version = CHROME_FOR_TESTING.version,
            sha256 = sha256,
        )

    # The emulator Android integration tests run on by default, one repository
    # per host it is pinned for, and the system image it boots, one per ABI.
    # Fetched only when an emulator runner selects the host's own.
    for host, sha256 in ANDROID_EMULATOR.sha256.items():
        flutter_android_emulator_repo(
            name = "flutter_android_emulator_" + host,
            build_id = ANDROID_EMULATOR.build_id,
            host = host,
            sha256 = sha256,
        )
    for abi, sha256 in ANDROID_SYSTEM_IMAGE.sha256.items():
        flutter_android_system_image_repo(
            name = "flutter_android_system_image_" + abi.replace("-", "_"),
            abi = abi,
            api_level = ANDROID_SYSTEM_IMAGE.api_level,
            revision = ANDROID_SYSTEM_IMAGE.revision,
            sha256 = sha256,
            tag = ANDROID_SYSTEM_IMAGE.tag,
        )

    # The X server, GTK, Mesa and libraries a Linux integration test runs with,
    # one repository per architecture, fetched only when a Linux runner of
    # `//flutter/integration_test` selects the host's.
    for arch, packages in LINUX_RUNTIME.packages.items():
        flutter_linux_runtime_repo(
            name = "flutter_linux_runtime_" + arch,
            arch = arch,
            snapshot = LINUX_RUNTIME.snapshot,
            debs = {path: sha256 for _, _, path, sha256 in packages},
            floor = LINUX_RUNTIME.floor,
        )

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
    },
    os_dependent = False,
    arch_dependent = False,
    doc = "Installs the Flutter SDKs and their toolchains.",
)
