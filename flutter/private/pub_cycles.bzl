"""The `flutter_pub.cycle()` declarations every library repository plans against.

Pub allows packages to depend on each other in a cycle; Bazel does not, so the
packages of one are built as one library, and only where the cycle is
declared. The root module decides: each of its declarations must be exactly a
cycle at the versions the build fetches, or the build fails. Other modules'
declarations, and rules_dart's curated ones (`curated_cycles()`), apply where
they are exactly a cycle and are inert where they are not. Whether a
declaration is a cycle is known only once its packages' pubspecs are read, in
the library repository (`dependency_cycle()`); what is checked here is what is
known before: its form, and that the root's name packages the build builds.
"""

load("@rules_dart//dart/ext:registry.bzl", "curated_cycles")
load("@rules_dart//dart/pub:pub_graph.bzl", "cycle_declaration", "cycle_declarations_error")

visibility("//flutter/...")

# The tag that declares a cycle, as a user writes it, for messages.
DECLARE = "flutter_pub.cycle"

# The tag that fetches a lock, as rules_dart's messages name it.
FROM_LOCK = "flutter_pub.from_lock"

def module_cycles(module):
    """One module's `flutter_pub.cycle()` declarations, for `plan_cycles`.

    Args:
      module: A module of the extension's `module_ctx.modules`.

    Returns:
      `struct(where, is_root, groups)`: who declared them, for messages,
      whether it is the root module, and each declaration's sorted packages.
    """
    return struct(
        where = "the root module" if module.is_root else "module `%s`" % module.name,
        is_root = module.is_root,
        groups = [sorted(tag.packages) for tag in module.tags.cycle],
    )

def plan_cycles(modules, built, not_built = {}):
    """The declarations the library repositories plan against, or what is wrong.

    Args:
      modules: Every module's declarations, as `module_cycles` gives them.
      built: The packages the build builds from the locks: each has a library
        repository, so only these can be in a cycle it builds.
      not_built: The packages the locks name that are not built, each with
        why, for the message of a root declaration naming one.

    Returns:
      `struct(declared, advisory, error)`: the root module's declarations, and
      every other one (other modules', and the curated ones) whose packages
      are all built, each a sorted list stated once; `error` is the message
      when a module's declarations are malformed or the root's name a package
      the build does not build, else None.
    """
    declared = []
    advisory = {}
    for module in modules:
        error = cycle_declarations_error(module.groups, module.where, DECLARE)
        if error:
            return struct(declared = [], advisory = [], error = error)
        if not module.is_root:
            for group in module.groups:
                advisory[" ".join(group)] = group
            continue
        for group in module.groups:
            problems = []
            for name in group:
                if name in built:
                    continue
                why = not_built.get(name, "no `flutter_pub.from_lock()` lock lists for the build to build")
                problems.append("  - `%s`, which %s" % (name, why))
            if problems:
                return struct(declared = [], advisory = [], error = (
                    "%s, in the root module, names packages this build does not build, so " +
                    "they are in no cycle it builds:\n%s\nRemove each from the declaration, " +
                    "or remove the declaration."
                ) % (cycle_declaration(group, DECLARE), "\n".join(problems)))
            declared.append(group)
    for group in curated_cycles():
        advisory[" ".join(group)] = group
    return struct(
        declared = declared,
        advisory = [
            advisory[key]
            for key in sorted(advisory)
            if all([name in built for name in advisory[key]])
        ],
        error = None,
    )
