"""`FlutterPubMemberInfo`: what a Flutter pub package contributes beyond its Dart package.

Its own file so that `flutter_info_forwarding.bzl`, which every rule reading
`FlutterInfo` loads, can read a `flutter_pub_member` without loading
`flutter_pub_library.bzl`, which loads those rules.
"""

FlutterPubMemberInfo = provider(
    doc = "What a Flutter pub package contributes to `FlutterInfo`, beyond its Dart package.",
    fields = {
        "contributions": "dict: The keyword arguments of `flutter_info()` for what this package itself contributes (plugin, native libraries, assets, fonts, shaders).",
    },
)

def member_contributions(members):
    """What the Flutter pub packages among `members` contribute, together.

    Args:
      members: The member Targets of a library. One of rules_dart's kinds
        contributes nothing.

    Returns:
      The keyword arguments of `flutter_info()`, each channel's values in the
      order of `members`.
    """
    contributions = {}
    for member in members:
        if FlutterPubMemberInfo in member:
            for channel, values in member[FlutterPubMemberInfo].contributions.items():
                contributions.setdefault(channel, []).extend(values)
    return contributions
