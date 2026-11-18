"""A prebuilt library, as a fixture: a plain library file linked outside the build.

A vendored or downloaded `.so`/`.dylib`/`.dll` is a file with no
`CcSharedLibraryInfo`, linked from nothing the build knows. This hands over
`library`'s file as one, built for whichever platform the app is so no binary
is checked in, and says so in `DartLinkInputsInfo`: its `inputs` are empty, as
a source file's are, so an Apple app's dSYM of it holds its symbol table.
"""

load("@rules_dart//dart:providers.bzl", "DartLinkInputsInfo")

def _prebuilt_library_impl(ctx):
    library = ctx.attr.library[OutputGroupInfo].main_shared_library_output.to_list()
    if len(library) != 1:
        fail("library must build exactly one shared library")
    return [
        DefaultInfo(files = depset(library)),
        DartLinkInputsInfo(library = library[0], inputs = depset()),
    ]

prebuilt_library = rule(
    implementation = _prebuilt_library_impl,
    attrs = {
        "library": attr.label(mandatory = True, doc = "The `cc_shared_library` standing in for the prebuilt file."),
    },
)
