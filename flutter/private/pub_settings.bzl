"""The `pub` extension's root-only statements: `flutter_pub.settings` and ignored hooks."""

def root_only_settings(modules):
    """The root's `flutter_pub.settings` and ignored hooks, refusing either from any other module.

    How the build's version choices are reported is the root's to decide, as
    is whether a hook matters: that depends on the programs the build makes,
    which are the root's. Pure, so a unit test reads the error.

    Args:
      modules: The extension's modules (`module_ctx.modules`).

    Returns:
      `struct(check, ignore_hooks, error)`: the root's level for its raised
      requests, the packages whose hooks the root declared irrelevant, and the
      message refusing the statements, None when there is none.
    """
    check = "warning"
    ignore_hooks = {}
    for mod in modules:
        if not mod.is_root:
            if mod.tags.settings:
                return struct(check = check, ignore_hooks = {}, error = (
                    "Module `%s` uses `flutter_pub.settings`, which only the root module may use: " +
                    "how the build's version choices are reported is the root's to decide. " +
                    "Remove it from that module."
                ) % mod.name)
            hooks = []
            for lock_tag in mod.tags.from_lock:
                hooks.extend(lock_tag.ignore_hooks)
            if hooks:
                return struct(check = check, ignore_hooks = {}, error = (
                    "Module `%s` ignores the build hooks of %s, which only the root module " +
                    "may do: whether a hook matters depends on the programs the build makes, " +
                    "which are the root's. Remove `ignore_hooks` from that module's " +
                    "`flutter_pub.from_lock`; the root declares the hooks its programs never reach."
                ) % (mod.name, ", ".join(["`%s`" % h for h in sorted(hooks)])))
            continue
        if len(mod.tags.settings) > 1:
            return struct(check = check, ignore_hooks = {}, error = (
                "The root module uses `flutter_pub.settings` %d times; state it once."
            ) % len(mod.tags.settings))
        for settings in mod.tags.settings:
            check = settings.check_direct_dependencies
        for lock_tag in mod.tags.from_lock:
            for name in lock_tag.ignore_hooks:
                ignore_hooks[name] = True
    return struct(check = check, ignore_hooks = ignore_hooks, error = None)

def root_annotations(modules, maven_prefix):
    """The root's `flutter_pub.annotation` tags, by package, refusing any from another module.

    An annotation adds to one package's generated targets what its own build
    files cannot say, so it is the root's: it changes what the whole build
    links. Pure, so a unit test reads the error.

    Args:
      modules: The extension's modules (`module_ctx.modules`).
      maven_prefix: How `str()` of a label of `@rules_flutter_maven` starts
        (`@@<repo>//:`); an `android_deps` label must start with it.

    Returns:
      `struct(by_package, error)`: the annotation fields by package name (a
      dict of `android_deps`, a list of label strings, and
      `build_config_fields`, field name to Java expression), and the message
      refusing the statements, None when there is none.
    """
    by_package = {}
    for mod in modules:
        if not mod.tags.annotation:
            continue
        if not mod.is_root:
            return struct(by_package = {}, error = (
                "Module `%s` uses `flutter_pub.annotation`, which only the root module may use: " +
                "what a package is built with is the root's to decide. Remove it from that module."
            ) % mod.name)
        for tag in mod.tags.annotation:
            if tag.package in by_package:
                return struct(by_package = {}, error = (
                    "The root module annotates the package `%s` more than once; " +
                    "state all its fields in one `flutter_pub.annotation`."
                ) % tag.package)
            android_deps = [str(label) for label in tag.android_deps]
            for dep in android_deps:
                if not dep.startswith(maven_prefix):
                    return struct(by_package = {}, error = (
                        "`flutter_pub.annotation(package = \"%s\")` names `%s` in " +
                        "`android_deps`, which is not an artifact of `@rules_flutter_maven`. " +
                        "Write `\"@rules_flutter_maven//:<artifact target>\"`."
                    ) % (tag.package, dep))
            by_package[tag.package] = {
                "android_deps": android_deps,
                "build_config_fields": dict(tag.build_config_fields),
            }
    return struct(by_package = by_package, error = None)

def unknown_annotation(by_package, known):
    """The message for an annotation naming a package no lock has, or None.

    Args:
      by_package: The `by_package` of `root_annotations`.
      known: The names of the packages the locks list.

    Returns:
      The message naming the first unknown package, or None.
    """
    for package in sorted(by_package.keys()):
        if package not in known:
            return (
                "`flutter_pub.annotation(package = \"%s\")` names a package that no " +
                "`flutter_pub.from_lock` lock lists. Check the name, or remove the annotation."
            ) % package
    return None
