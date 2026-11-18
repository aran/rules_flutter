"""Naming policy for the Swift module a Flutter app's runner compiles into.

Shared by `flutter_ios_app` and `flutter_macos_app` so both platforms spell the
module the same way — the name leaks into NIBs and Info.plists, so a
platform-specific rule would be a trap.
"""

load(":validation.bzl", "validate_swift_module_name")

visibility("//flutter/...")

def runner_module_name(macro, name):
    """Derives the runner's Swift module name from an app target's name.

    The module name must satisfy two constraints, both of which rules_apple
    and rules_swift enforce by way of output paths rather than diagnostics:

    1. **Unique per target in a package.** `swift_library` derives its
       `.swiftmodule` output path from `module_name` alone, so the historical
       hardcoded "Runner" made any two Flutter apps in one package collide on
       `<pkg>/Runner.swiftmodule` — an analysis-time action conflict that made
       them unbuildable in a single invocation.

    2. **Different from the app target's own name.** rules_apple names the
       linked-storyboard directory `storyboards/<parent_dir>/<swift_module>`
       (resources_support.bzl `_storyboards`), and resources it cannot
       attribute to a Swift module fall back to `rule_label.name`. An iOS app
       has two `Base.lproj` storyboards — `Main.storyboard`, owned by the
       runner library, and `LaunchScreen.storyboard`, passed to
       `ios_application(launch_storyboard = ...)` and therefore stuck with the
       fallback. Were the module equal to the target name, those two would
       collide inside a single target.

    Appending a suffix satisfies both: it is injective, so distinct targets get
    distinct modules, and it can never equal the target's own name.

    Note the consequence for XIBs and storyboards routed through
    `*_application(resources = ...)`: those get ibtool `--module <target name>`,
    which is deliberately not this module, so they cannot resolve the runner's
    Swift classes. Resources that name runner classes belong on the runner
    library, which is the route the macros use for MainMenu.xib and
    Main.storyboard.

    Args:
        macro: Name of the calling macro, for the failure message.
        name: The app target's name.

    Returns:
        The Swift module name for the runner library.
    """
    validate_swift_module_name(name, "%s(name = %r)" % (macro, name))
    return name + "Runner"
