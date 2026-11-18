"""The transition to debug mode, for the targets that run only there."""

visibility("//flutter/...")

_PROFILE = str(Label("//flutter:profile"))

# Debug mode, not profile: the flag is refused with any `-c` but opt, and a
# profile build is not debug. What is built here is debug by design: the
# simulator engine runs nothing else, an integration test drives its app
# through the VM service that only a debug build serves, and upstream
# refuses a profile simulator build.
#
# Exported for the transitions that set more than this (an Android ABI, a
# simulator CPU) and must still be a debug build.
DBG_SETTINGS = {
    "//command_line_option:compilation_mode": "dbg",
    _PROFILE: False,
}

def _dbg_transition_impl(_settings, _attr):
    return DBG_SETTINGS

dbg_transition = transition(
    implementation = _dbg_transition_impl,
    inputs = [],
    outputs = DBG_SETTINGS.keys(),
)
