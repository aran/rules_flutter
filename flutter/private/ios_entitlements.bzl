"""Which entitlements file an iOS app ships, out of three answers.

An iOS app ships `ios/Runner/Runner.entitlements` only when a capability was
enabled in Xcode, so its absence is an ordinary, capability-less app rather
than a misconfigured one — that is why `flutter_ios_app` discovers the file
instead of requiring it, and why macOS (where `flutter create` always writes
the pair) fails on its absence instead.

Discovery has one consequence worth a named function: the file is in the build
because it is on disk, and nobody wrote it down. That is invisible until a
device build, which is signed against a provisioning profile, and an
entitlement the profile does not grant fails it — `aps-environment`, which
Xcode writes the moment Push Notifications is enabled, cannot be granted by a
team wildcard profile at all. rules_apple reports that as

    Target "//:app_device" uses entitlements with the "aps-environment" key,
    but the profile does not have this key

which names the profile and not the file, and the file is the last place its
reader looks. `False` is the third answer: ship none although the file exists.
Deleting the file would be the wrong remedy — it is the app's own answer for
the profile that *can* grant push, and Xcode writes it again — so the target
that cannot use it is the one that says so.
"""

def resolve_ios_entitlements(entitlements, discovered):
    """The entitlements label for an iOS app, or None to ship none.

    Args:
        entitlements: What the caller passed: `None` to discover, `False` to
            ship none, or a label to use.
        discovered: The conventional file if the package has one, else None.

    Returns:
        A label, or None.
    """
    if entitlements == None:
        return discovered

    # `False`, the way `app_icons = []` ships no icon: falsy and not None is
    # the caller saying "none", distinct from not having said anything.
    if not entitlements:
        return None

    return entitlements
