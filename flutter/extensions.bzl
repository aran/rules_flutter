"""Extensions for bzlmod.

`flutter` installs the Flutter SDKs and their toolchains. The pub dependency
extension is `pub` in `@rules_flutter//flutter/pub:extensions.bzl`; it is its
own extension so that a lock it refuses breaks only the builds that use its
repositories, never the toolchains, and `bazel run @rules_flutter//flutter/pub`,
which fixes the lock, still runs.

Every module can ask for a toolchain version under the default name, "flutter",
which rules_flutter always registers. The root module's version is the one
used; without one, the highest version any module asks for is used.

The root module can declare more releases under other names, each name's
version resolved the same way. rules_flutter registers the toolchains of every
declared SDK. The root module can also declare SDKs
that are not releases, each form its own tag: `flutter.custom_framework` (a
release's engine under another framework), `flutter.custom_engine` (a release's
framework over another engine), `flutter.custom_sdk` (both halves given) and
`flutter.checkout` (a flutter/flutter checkout, its framework and the engine
built in it).

A build uses one SDK. `flutter.use_sdk` in the root module says which, and
without it the build uses `flutter`. `--@rules_flutter//flutter:sdk=<name>`
overrides that choice for one build, or for one machine in `.bazelrc.user`.
"""

load("@rules_dart//dart:repositories.bzl", "dart_kernel_source")
load("//flutter:local_sdk.bzl", "flutter_local_framework")
load("//flutter/private:constants.bzl", "ANDROID_ABI_FOR_ARCH")
load("//flutter/private:custom_sdks.bzl", "checkout_repo_names", "custom_sdks")
load("//flutter/private:engine_labels.bzl", "android_arches")
load("//flutter/private:flutter_android_emulator_repo.bzl", "flutter_android_emulator_repo", "flutter_android_system_image_repo")
load("//flutter/private:flutter_chrome_for_testing.bzl", "flutter_chrome_for_testing")
load("//flutter/private:flutter_dev_root_repo.bzl", "flutter_dev_root_repo")
load("//flutter/private:flutter_face_repo.bzl", "IOS_ENGINE_EXTRA", "IOS_ENGINE_TARGETS", "MACOS_ENGINE_EXTRA", "MACOS_ENGINE_TARGETS", "WEB_SDK_TARGETS", "android_engine_face_extra", "flutter_face_repo")
load("//flutter/private:flutter_linux_runtime_repo.bzl", "flutter_linux_runtime_repo")
load("//flutter/private:flutter_material_fonts_repo.bzl", "flutter_material_fonts_repo")
load("//flutter/private:flutter_sdk_toolchains_repo.bzl", "flutter_sdk_toolchains_repo")
load("//flutter/private:flutter_sdks_repo.bzl", "encode_sdks", "flutter_sdks_repo")
load("//flutter/private:flutter_web_sdk_repo.bzl", "host_platform")
load("//flutter/private:linux_runtime_pins.bzl", "LINUX_RUNTIME")
load("//flutter/private:local_engine.bzl", "flutter_checkout_engine")
load("//flutter/private:pub_extension.bzl", "DEFAULT_SDK_NAME")
load("//flutter/private:repositories.bzl", "flutter_register_toolchains")
load("//flutter/private:toolchain_version.bzl", "select_flutter_version")
load("//flutter/private:toolchains_repo.bzl", "flutter_toolchains_repo", "sdk_repo_name")
load("//flutter/private:versions.bzl", "ANDROID_EMULATOR", "ANDROID_SYSTEM_IMAGE", "CHROME_FOR_TESTING", "FLUTTER_VERSIONS", "flutter_source_sha256", "require_supported_flutter_version")

flutter_toolchain = tag_class(
    doc = """\
A Flutter release. Any module may ask for a version of the default one,
`flutter`; the root module may declare others under other names.
""",
    attrs = {
        "name": attr.string(doc = """\
The name of the SDK this declares. `flutter` is the default; any other name is
another SDK, which `flutter.use_sdk` or `--@rules_flutter//flutter:sdk`
chooses. A name other than the default is only permitted in the root module.
""", default = DEFAULT_SDK_NAME),
        "flutter_version": attr.string(doc = """\
Version of the Flutter release. Some module must give one for each name.
"""),
        "allow_upgrade_by_dependencies": attr.bool(doc = """\
Root module only. When False (the default) the root's `flutter_version` is used
exactly, and a dependency asking for a newer release fails the build. When True,
the highest version any module asks for is used. As `dart.toolchain`'s attribute
of the same name.
"""),
    },
)

_SDK_NAME_DOC = """\
The name of the SDK this declares: what `flutter.use_sdk` and
`--@rules_flutter//flutter:sdk` choose it by. Not `flutter`, the release every
module may ask a version of.
"""

_FRAMEWORK_DOC = """\
A repository whose root is a flutter/flutter tree and which holds
`flutter_framework.json` (the framework contract), such as a
`flutter_local_framework` of `@rules_flutter//flutter:local_sdk.bzl`.
"""

_ENGINE_DOC = """\
A repository whose slices are the engine contract's labels (see
`@rules_flutter//flutter:engine.bzl`), such as a `flutter_local_engine` of
`@rules_flutter//flutter:local_sdk.bzl`.
"""

_MATERIAL_FONTS_DOC = """\
The checksum of the Material fonts archive the framework expects, when its
`bin/internal/material_fonts.version` names an archive no pinned release does.
"""

flutter_custom_framework = tag_class(
    doc = "A release's engine under another framework. Root module only.",
    attrs = {
        "name": attr.string(doc = _SDK_NAME_DOC, mandatory = True),
        "framework": attr.label(doc = _FRAMEWORK_DOC, mandatory = True),
        "flutter_version": attr.string(doc = "Version of the Flutter release whose engine this uses.", mandatory = True),
        "material_fonts_sha256": attr.string(doc = _MATERIAL_FONTS_DOC),
    },
)

flutter_custom_engine = tag_class(
    doc = "A release's framework over another engine. Root module only.",
    attrs = {
        "name": attr.string(doc = _SDK_NAME_DOC, mandatory = True),
        "engine": attr.label(doc = _ENGINE_DOC, mandatory = True),
        "flutter_version": attr.string(doc = "Version of the Flutter release whose framework this uses.", mandatory = True),
    },
)

flutter_custom_sdk = tag_class(
    doc = """\
A framework and an engine, neither of them a release's. Root module only. For a
checkout's own framework and the engine built in it, `flutter.checkout` is one
declaration.
""",
    attrs = {
        "name": attr.string(doc = _SDK_NAME_DOC, mandatory = True),
        "framework": attr.label(doc = _FRAMEWORK_DOC, mandatory = True),
        "engine": attr.label(doc = _ENGINE_DOC, mandatory = True),
        "material_fonts_sha256": attr.string(doc = _MATERIAL_FONTS_DOC),
    },
)

flutter_checkout = tag_class(
    doc = """\
An SDK that is a flutter/flutter checkout: its framework, from `packages/`, and
the engine built in its `engine/src/out`, as `flutter run --local-engine` pairs
them. Root module only.

The checkout's path is machine-local, so it is not an attribute: it is the
environment variable `path_env` names, set in `.bazelrc.user`:

    common --repo_env=FLUTTER_CHECKOUT=/Users/me/src/flutter

To pair a checkout's framework or engine with another's, declare the halves
with `@rules_flutter//flutter:local_sdk.bzl` and give them to
`flutter.custom_sdk`, `flutter.custom_framework` or `flutter.custom_engine`.
""",
    attrs = {
        "name": attr.string(doc = _SDK_NAME_DOC, mandatory = True),
        "path_env": attr.string(
            doc = "The environment variable holding the checkout's path. Set it with `--repo_env`.",
            default = "FLUTTER_CHECKOUT",
        ),
        "engines_env": attr.string(
            doc = "The environment variable naming the out dirs to use, when a slot has more than one candidate.",
            default = "FLUTTER_LOCAL_ENGINES",
        ),
        "checkout": attr.label(doc = """\
A file at the root of a checkout that another repository lays out, in place of
the environment variable: for a checkout that Bazel itself produces, such as
the stand-in a test builds from the official artifacts.
"""),
        "material_fonts_sha256": attr.string(doc = _MATERIAL_FONTS_DOC),
    },
)

flutter_use_sdk = tag_class(
    doc = """\
Chooses the Flutter SDK the build uses, from those declared. Root module only, once.

Without it the build uses `flutter`. `--@rules_flutter//flutter:sdk=<name>`, when
given, overrides this for that build.
""",
    attrs = {
        "name": attr.string(doc = "The name of a declared SDK.", mandatory = True),
    },
)

def _label_prefix(label):
    """A label's repository, as a prefix any repository can name it by."""
    return "@@" + label.repo_name

def _framework_json(sdk):
    """The label of the `flutter_framework.json` of an SDK whose framework is not the release's."""
    return sdk.framework + "//:flutter_framework.json"

def _sdk(name, version = None, framework = None, engine = None, material_fonts_sha256 = "", checkout = None):
    """One SDK: the release that supplies a half not given, and the halves given, as label prefixes."""
    if version:
        require_supported_flutter_version(version)
    return struct(
        name = name,
        version = version,
        framework = framework,
        engine = engine,
        material_fonts_sha256 = material_fonts_sha256,
        checkout = checkout,
    )

def _custom_framework_sdk(tag):
    return _sdk(
        tag.name,
        version = tag.flutter_version,
        framework = _label_prefix(tag.framework),
        material_fonts_sha256 = tag.material_fonts_sha256,
    )

def _custom_engine_sdk(tag):
    return _sdk(tag.name, version = tag.flutter_version, engine = _label_prefix(tag.engine))

def _custom_sdk_sdk(tag):
    return _sdk(
        tag.name,
        framework = _label_prefix(tag.framework),
        engine = _label_prefix(tag.engine),
        material_fonts_sha256 = tag.material_fonts_sha256,
    )

def _checkout_sdk(tag):
    # A checkout's framework and engine, as repositories of this extension.
    repos = checkout_repo_names(tag.name)
    return _sdk(
        tag.name,
        framework = "@" + repos.framework,
        engine = "@" + repos.engine,
        material_fonts_sha256 = tag.material_fonts_sha256,
        checkout = tag,
    )

# The SDK each of the custom-SDK tags declares, by the tag's name.
_CUSTOM_SDK = {
    "custom_framework": _custom_framework_sdk,
    "custom_engine": _custom_engine_sdk,
    "custom_sdk": _custom_sdk_sdk,
    "checkout": _checkout_sdk,
}

def _declared_sdks(module_ctx):
    """The SDKs the modules declare, a struct for each by name, and the one the root module chooses."""

    # The root module's version for a name is used exactly; a dependency asking
    # for newer fails, unless the root sets `allow_upgrade_by_dependencies`.
    # A name the root does not pin takes the highest version asked for.
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
            requests.setdefault(toolchain.name, [])
            if toolchain.flutter_version:
                requests[toolchain.name].append((mod.name, toolchain.flutter_version))

    sdks = {}
    for name, name_requests in requests.items():
        if not name_requests:
            fail("flutter.toolchain(name = \"{}\") needs a flutter_version, in some module.".format(name))
        selection = select_flutter_version(name, root_versions.get(name), name_requests, allow_upgrade.get(name, False))
        if selection.error:
            fail(selection.error)
        sdks[name] = _sdk(name, version = selection.version)

    customs = custom_sdks(module_ctx.modules, requests.keys(), DEFAULT_SDK_NAME)
    if customs.error:
        fail(customs.error)
    for name, custom in customs.sdks.items():
        sdks[name] = _CUSTOM_SDK[custom.kind](custom.tag)
    if DEFAULT_SDK_NAME not in sdks:
        fail("A flutter.toolchain() is required: the default SDK, named \"{}\".".format(DEFAULT_SDK_NAME))
    return struct(sdks = sdks, use = customs.use or DEFAULT_SDK_NAME)

def _register_sdk(sdk, host):
    """Declares the repositories of one SDK; returns the label prefix of its engine source."""
    name = sdk.name
    if sdk.checkout:
        # One checkout, read from one path, makes both halves.
        repos = checkout_repo_names(name)
        flutter_local_framework(
            name = repos.framework,
            path_env = sdk.checkout.path_env,
            checkout = sdk.checkout.checkout,
        )
        flutter_checkout_engine(
            name = repos.engine,
            path_env = sdk.checkout.path_env,
            engines_env = sdk.checkout.engines_env,
            checkout = sdk.checkout.checkout,
        )
    if sdk.engine == None and sdk.framework == None:
        # The release, with the artifact repositories it is made of.
        flutter_register_toolchains(name = name, flutter_version = sdk.version, host = host)
        return "@{}_stock_engine".format(name)

    # The Material fonts come with the framework: the ones its
    # `bin/internal/material_fonts.version` names, or the release's.
    fonts = name + "_material_fonts"
    flutter_material_fonts_repo(
        name = fonts,
        flutter_version = sdk.version or "",
        framework_json = _framework_json(sdk) if sdk.framework else None,
        sha256 = sdk.material_fonts_sha256,
    )
    fonts_label = "@{}//:material-fonts/MaterialIcons-Regular.otf".format(fonts)
    if sdk.engine == None:
        # A framework of the root module's choosing over the release engine,
        # with the artifact repositories it is made of.
        flutter_register_toolchains(
            name = name,
            flutter_version = sdk.version,
            host = host,
            framework_json = _framework_json(sdk),
            framework_json_file = _framework_json(sdk),
            material_fonts = fonts_label,
        )
        return "@{}_stock_engine".format(name)

    # An engine of the root module's choosing: the toolchains are written
    # against its slices.
    flutter_sdk_toolchains_repo(
        name = sdk_repo_name(name),
        engine = sdk.engine,
        sdk = name,
        version = sdk.version or "",
        material_fonts = fonts_label,
        sysroot_prefix = DEFAULT_SDK_NAME,
        framework_json = _framework_json(sdk) if sdk.framework else "",
        framework_json_file = _framework_json(sdk) if sdk.framework else None,
        engine_json_file = sdk.engine + "//:flutter_engine.json",
    )
    return sdk.engine

def _toolchain_extension(module_ctx):
    declared = _declared_sdks(module_ctx)
    sdks = declared.sdks

    # The web SDK repository holds the Dart SDK of the machine Bazel runs on,
    # so the extension's repositories depend on its OS and CPU.
    host = host_platform(module_ctx.os)
    engine_prefixes = {}
    outline_packages = {}
    for name in sorted(sdks.keys()):
        sdk = sdks[name]
        engine_prefixes[name] = _register_sdk(sdk, host)

        # The SDK's dev root, for `@rules_flutter//flutter/pub`. Declared
        # unconditionally because bzlmod repositories are lazy: a workspace
        # that never references it never fetches the tarball.
        released = sdk.version and not sdk.framework
        flutter_dev_root_repo(
            name = name + "_dev_root_src",
            flutter_version = sdk.version or "",
            framework_json = _framework_json(sdk) if sdk.framework else None,
            sky_engine = (
                sdk.engine + "//sky_engine:pubspec.yaml" if sdk.engine else "@{}_sky_engine//sky_engine:pubspec.yaml".format(name)
            ) if sdk.framework else None,
            engine_json = sdk.engine + "//:flutter_engine.json" if sdk.engine else None,
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
                sha256 = FLUTTER_VERSIONS[sdk.version].dart_source_sha256,
            )
            outline_packages[name] = "@{}_outline_tool_src//".format(name)
        else:
            outline_packages[name] = sdk.engine + "//outline_tool"

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
            extra = android_engine_face_extra(
                engine_prefixes,
                arch,
                ANDROID_ABI_FOR_ARCH[arch],
                custom = [name for name, sdk in sdks.items() if sdk.engine != None],
            ),
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
        frameworks = {name: _framework_json(sdk) for name, sdk in sdks.items() if sdk.framework},
    )

    # Every SDK's toolchains, and the settings that say which one the build
    # uses: the one `--@rules_flutter//flutter:sdk` names, or without the flag
    # the one `flutter.use_sdk` chooses.
    flutter_toolchains_repo(
        name = "flutter_toolchains",
        sdks = sorted(sdks.keys()),
        default_sdk = declared.use,
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
        "custom_framework": flutter_custom_framework,
        "custom_engine": flutter_custom_engine,
        "custom_sdk": flutter_custom_sdk,
        "checkout": flutter_checkout,
        "use_sdk": flutter_use_sdk,
    },
    os_dependent = True,
    arch_dependent = True,
    doc = "Installs the Flutter SDKs and their toolchains. The module docstring says which SDKs exist and which a build uses.",
)
