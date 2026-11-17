"""Which SDKs the `flutter.checkout` tags declare."""

def checkout_repo_names(name):
    """The repositories of the checkout SDK `name`: its framework source and its engine source."""
    return struct(
        framework = name + "_checkout_framework",
        engine = name + "_checkout_engine",
    )

def checkout_sdks(modules, toolchain_names):
    """The checkout SDKs the modules declare, or why the module graph cannot have them.

    Args:
        modules: The modules, as `module_ctx.modules` gives them: each with
            `name`, `is_root` and `tags.checkout`.
        toolchain_names: The names a `flutter.toolchain` declares, in any module.

    Returns:
        A struct: `tags`, each name's tag, and `error`, None or why the tags
        cannot stand.
    """
    tags = {}
    for mod in modules:
        for tag in mod.tags.checkout:
            if not mod.is_root:
                return struct(tags = {}, error = (
                    "flutter.checkout(name = \"{}\") in module {} declares an SDK. Only the root module may: " +
                    "a library module must not impose a checkout on its dependents."
                ).format(tag.name, mod.name))
            if tag.name in tags:
                return struct(tags = {}, error = "flutter.checkout(name = \"{}\") is declared twice.".format(tag.name))
            if tag.name in toolchain_names:
                return struct(tags = {}, error = (
                    "\"{0}\" is declared by both flutter.checkout(name = \"{0}\") and flutter.toolchain(name = \"{0}\"). " +
                    "An SDK is one or the other: give the checkout another name."
                ).format(tag.name))
            tags[tag.name] = tag
    return struct(tags = tags, error = None)
