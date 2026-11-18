"""What the bundle-parts aspects share: walking a launch target's dependencies.

A hot restart reads two things of the app it restarts: the `flutter_assets`
tree and the native libraries the launch artifact carries. Each platform has an
aspect that collects them below the launch target, in the configuration each
was built in, so that building its output groups builds them and nothing of the
artifact itself. These are the parts of that walk no platform changes.
"""

visibility("//flutter/...")

PartsInfo = provider(
    doc = "Every bundle's assets and native library inputs at or below this node.",
    fields = {
        "assets": "depset[File]",
        "native_libs": "depset[File]",
    },
)

def parts_of_dependencies(rule_attr):
    """The collected parts of every dependency, whatever attribute shape holds it.

    Args:
        rule_attr: `ctx.rule.attr` of the node the aspect is visiting.

    Returns:
        The `PartsInfo` of each dependency that has one.
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
            if type(item) == "Target" and PartsInfo in item:
                deps.append(item[PartsInfo])
    return deps

def own_libraries(cc_info, owner):
    """The files the linker is given for `owner`'s own libraries.

    Args:
        cc_info: the node's `CcInfo`.
        owner: the node's label; linker inputs owned by others are theirs to
            contribute.

    Returns:
        The static libraries, shared libraries and objects, as a list.
    """
    files = []
    for linker_input in cc_info.linking_context.linker_inputs.to_list():
        if linker_input.owner != owner:
            continue
        for library in linker_input.libraries:
            for file in [
                library.static_library,
                library.pic_static_library,
                library.dynamic_library,
            ] + list(library.objects or []) + list(library.pic_objects or []):
                if file:
                    files.append(file)
    return files

def parts_result(assets, native_libs, below, assets_group, native_libs_group):
    """The providers a bundle-parts aspect returns at one node.

    Args:
        assets: list of depsets of this node's own assets trees.
        native_libs: list of depsets of this node's own native library inputs.
        below: `PartsInfo` of every dependency, from `parts_of_dependencies`.
        assets_group: the output group name the assets go in.
        native_libs_group: the output group name the native libraries go in.

    Returns:
        `PartsInfo` and the `OutputGroupInfo` holding both groups.
    """
    assets_all = depset(transitive = assets + [d.assets for d in below])
    native_all = depset(transitive = native_libs + [d.native_libs for d in below])
    return [
        PartsInfo(assets = assets_all, native_libs = native_all),
        OutputGroupInfo(**{
            assets_group: assets_all,
            native_libs_group: native_all,
        }),
    ]

def runner_binary(runner):
    """The runner executable a desktop bundle copies in, as its bundling picks it.

    Args:
        runner: the bundle's `runner` target, which is a compiled executable
            (with its sources and headers listed beside it, which are not it).

    Returns:
        The first file of the target that is not a source or a header, or None.
    """
    for file in runner[DefaultInfo].files.to_list():
        if not file.path.endswith(".h") and not file.path.endswith(".cc"):
            return file
    return None
