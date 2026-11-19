"""The objects a link read, whatever form the C++ toolchain passes them in.

A toolchain that supports `--start-lib` (Bazel's autoconfigured one, on a
Linux machine whose compiler links with gold) passes a library's objects to
the link itself; another passes the library's static archive. Either way the
link reads the same objects.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

# MSVC's object and archive extensions beside the Unix ones.
_OBJECT_EXTENSIONS = ("o", "obj")
_ARCHIVE_EXTENSIONS = ("a", "lib")

def linked_objects(link_inputs, libraries):
    """Names the objects among a link's inputs, an archive standing for those it holds.

    Args:
        link_inputs: The Files the link read.
        libraries: Targets with CcInfo whose static archives the link may read.

    Returns:
        The sorted names of the objects, each the basename of the source it
        was compiled from without its extension (`bridge` for `bridge.pic.o`,
        `bridge.o` and `bridge.obj`). An archive none of `libraries` makes
        keeps its own basename, so a test names it.
    """
    held = {}
    for library in libraries:
        for linker_input in library[CcInfo].linking_context.linker_inputs.to_list():
            for lib in linker_input.libraries:
                for archive, objects in [(lib.static_library, lib.objects), (lib.pic_static_library, lib.pic_objects)]:
                    if archive:
                        held[archive.short_path] = objects or []
    names = []
    for f in link_inputs:
        if f.extension in _OBJECT_EXTENSIONS:
            names.append(_source_name(f))
        elif f.extension in _ARCHIVE_EXTENSIONS:
            if f.short_path in held:
                names.extend([_source_name(o) for o in held[f.short_path]])
            else:
                names.append(f.basename)
    return sorted(names)

def _source_name(object_file):
    name = object_file.basename[:-len(object_file.extension) - 1]
    return name[:-len(".pic")] if name.endswith(".pic") else name
