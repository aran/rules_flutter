"""The execution groups rules_flutter's actions run in.

A kernel compile, a shader compile, an asset bundle, a web compile or a
manifest merge writes the same bytes whichever host runs it, so it needs only
the Flutter tools built for that host: the exec-tools toolchain, which, unlike
`//flutter:toolchain_type`, does not tie the host to the target platform. Such
an action runs in `PORTABLE`, which resolves to the first execution platform
that has the tools: a remote Linux worker when one is registered first, the
local machine otherwise. The group also resolves rules_dart's exec-tools
toolchain, so it lands only on a host that has both SDKs, and rules_dart's
helpers can read their SDK from the same group.

Actions that need the target's `gen_snapshot` (AOT) or engine stay in the
rule's default group, whose `//flutter:toolchain_type` matches the target.
Actions that run Xcode's tools name no group of ours: they run through
`apple_support.run_shell` in the auto exec group of the C++ toolchain resolved
for the Apple target, whose toolchain declares where Xcode executes.

`PORTABLE` is placed only by the toolchains it resolves: it names no
execution constraints of its own, so a build that registers several
execution platforms sends each such action to one that has every tool it
runs. A user who needs one target's actions elsewhere sets
`exec_group_compatible_with` on its group by name, so the group names are
part of the rules' interface.
"""

PORTABLE = "portable"

FLUTTER_EXEC_TOOLS = Label("//flutter:exec_tools_toolchain_type")
DART_EXEC_TOOLS = Label("@rules_dart//dart:exec_tools_toolchain_type")

def _portable():
    return exec_group(toolchains = [FLUTTER_EXEC_TOOLS, DART_EXEC_TOOLS])

PORTABLE_EXEC_GROUPS = {PORTABLE: _portable()}

def portable_tools(ctx):
    """The `FlutterExecToolsInfo` of the host `PORTABLE` actions run on.

    Args:
      ctx: A rule context declaring `PORTABLE`.

    Returns:
      The `FlutterExecToolsInfo`.
    """
    return ctx.exec_groups[PORTABLE].toolchains[FLUTTER_EXEC_TOOLS].flutter_exec_tools_info
