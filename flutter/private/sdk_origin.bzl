"""Where an SDK's engine comes from, for the rules that record it.

Every slice of an engine source records where it came from (`provenance`); the
official release's say `origin: release`. An app of the release carries no
record of its SDK: its pieces are the official ones and agree by construction.
An app of any other source does, and its pieces are checked first
(`flutter_sdk_record.bzl`).
"""

visibility("//flutter/...")

RELEASE_ORIGIN = "release"

def is_release_engine(host_tools):
    """Whether an SDK's engine is the official release.

    Args:
        host_tools: The `FlutterHostToolsInfo` of the SDK.

    Returns:
        True when the engine source is the stock release.
    """
    return host_tools.provenance.get("origin") == RELEASE_ORIGIN
