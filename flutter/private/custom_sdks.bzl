"""Which SDKs the root module declares with the tags that replace part of a release, or all of it, and which one it builds with."""

visibility("//flutter/...")

# The tags, each one form of SDK: its attributes are what that form needs.
CUSTOM_SDK_TAGS = ["custom_framework", "custom_engine", "custom_sdk", "checkout"]

def checkout_repo_names(name):
    """The repositories of the checkout SDK `name`: its framework source and its engine source."""
    return struct(
        framework = name + "_checkout_framework",
        engine = name + "_checkout_engine",
    )

def custom_sdks(modules, release_names, default_name):
    """The custom SDKs the modules declare and the SDK the root chooses, or why the module graph cannot have them.

    Args:
        modules: The modules, as `module_ctx.modules` gives them: each with
            `name`, `is_root` and a `tags` list for `use_sdk` and for each of
            `CUSTOM_SDK_TAGS`.
        release_names: The names a `flutter.toolchain` declares, in any module.
        default_name: The name of the release every module may ask a version of.

    Returns:
        A struct: `sdks`, each name's `struct(kind, tag)`, where `kind` is the
        tag's name in `CUSTOM_SDK_TAGS`; `use`, the name `flutter.use_sdk`
        gives, or None; and `error`, None or why the tags cannot stand.
    """
    sdks = {}
    for mod in modules:
        for kind in CUSTOM_SDK_TAGS:
            for tag in getattr(mod.tags, kind):
                declared = "flutter.{}(name = \"{}\")".format(kind, tag.name)
                if not mod.is_root:
                    return _error((
                        "{} in module {} declares an SDK. Only the root module may: " +
                        "a library module must not impose a fork on its dependents."
                    ).format(declared, mod.name))
                if tag.name == default_name:
                    return _error((
                        "{} takes the name of the release every module may ask a version of. " +
                        "Give it another name; to build with it, add flutter.use_sdk(name = ...)."
                    ).format(declared))
                if tag.name in sdks:
                    return _error("\"{}\" is declared twice: by flutter.{}() and by flutter.{}().".format(
                        tag.name,
                        sdks[tag.name].kind,
                        kind,
                    ))
                if tag.name in release_names:
                    return _error((
                        "\"{0}\" is declared by both {1} and flutter.toolchain(name = \"{0}\"). " +
                        "An SDK is one or the other: give one of them another name."
                    ).format(tag.name, declared))
                sdks[tag.name] = struct(kind = kind, tag = tag)

    use = None
    for mod in modules:
        for tag in mod.tags.use_sdk:
            if not mod.is_root:
                return _error((
                    "flutter.use_sdk(name = \"{}\") in module {} chooses the Flutter SDK. Only the root " +
                    "module may: a library module must not decide the SDK of the apps that use it."
                ).format(tag.name, mod.name))
            if use != None:
                return _error(
                    "The root module chooses two Flutter SDKs: flutter.use_sdk(name = \"{}\") and flutter.use_sdk(name = \"{}\"). Keep one.".format(use, tag.name),
                )
            use = tag.name
    declared_names = sorted(list(release_names) + sdks.keys())
    if use != None and use not in declared_names:
        return _error("flutter.use_sdk(name = \"{}\") names no declared Flutter SDK. The declared SDKs are: {}.".format(
            use,
            ", ".join(declared_names),
        ))
    return struct(sdks = sdks, use = use, error = None)

def _error(message):
    return struct(sdks = {}, use = None, error = message)
