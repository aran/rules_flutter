"""The libraries of a `flutter_application`, compiled into kernel modules, for a program compiled in its package."""

load("@rules_dart//dart:providers.bzl", "DartModuleInfo")
load("//flutter:providers.bzl", "FlutterApplicationInputsInfo")
load("//flutter/private:flutter_module.bzl", "flutter_module_aspect")

visibility("//flutter/...")

ApplicationLibrariesInfo = provider(
    doc = "The libraries an application's program depends on, each with its kernel modules: what `flutter_test`'s `application` adds to the test's `deps`.",
    fields = {
        "libraries": "dict[Label, Target]: by label, every Target in the application's `FlutterApplicationInputsInfo.inputs.deps`, as reached by `flutter_module_aspect`, so each carries `DartModuleInfo` beside its own providers.",
    },
)

def _application_libraries_impl(target, ctx):
    # `flutter_module_aspect` hands on a target that is not a library's own
    # libraries, one hop: an application's `deps`. A
    # `flutter_application_variant` holds the application it varies one hop
    # further, so its libraries are the application's and its own.
    libraries = dict(target[DartModuleInfo].exported)
    inner = getattr(ctx.rule.attr, "application", None)
    if inner != None and ApplicationLibrariesInfo in inner:
        libraries = inner[ApplicationLibrariesInfo].libraries | libraries
    return [ApplicationLibrariesInfo(libraries = libraries)]

application_libraries_aspect = aspect(
    implementation = _application_libraries_impl,
    attr_aspects = ["application"],
    requires = [flutter_module_aspect],
    doc = "Collects, on a `flutter_application` or `flutter_application_variant`, the libraries of its program with their kernel modules (`ApplicationLibrariesInfo`).",
)

def application_libraries(application):
    """The Targets of `application`'s program's `deps`, each with its kernel modules.

    Args:
        application: A Target reached through an attribute that applies
            `application_libraries_aspect`.

    Returns:
        The list of Targets, in the order of the program's `deps`.
    """
    libraries = application[ApplicationLibrariesInfo].libraries
    return [libraries[dep.label] for dep in application[FlutterApplicationInputsInfo].inputs.deps]
