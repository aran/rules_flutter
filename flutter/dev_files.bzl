"""The aspect that requests the files the dev loop reads.

The dev tool reads build outputs off disk to drive a running app. Bazel
materializes an output when it belongs to a target named on the command line,
and a launchable target names only its bundle.

This cannot be an output group on that target: on Apple platforms it is
`rules_apple`'s `macos_application` / `ios_application`. Nor a sibling target:
those rules apply a split transition to their `deps`, so the
`flutter_application` the app was assembled from sits in a configuration
(`…-ST-<hash>`) nothing can name and no sibling re-derives. An aspect rides the
existing dep edges in the configuration they already have.

The group is the one the `flutter_application` declares, its own `DefaultInfo`
rather than a hand-listed subset, so the two cannot drift.
"""

# The output group the dev tool requests. Named for what it is rather than for
# who wants it: a release build has no use for these, but they are not "debug"
# either — the release pipeline simply never asks.
DEV_FILES_GROUP = "flutter_dev_files"

def _flutter_dev_files_aspect_impl(target, ctx):
    # The application declares the group itself, and the search ends there: an
    # application below it is not the one the app runs. A
    # `flutter_application_variant` holds the application it varies, whose dev
    # config would otherwise sit beside the variant's in the same configuration.
    # Not `FlutterApplicationInfo in target`: a bundling rule passes that
    # provider on, with files of its own.
    if OutputGroupInfo in target and hasattr(target[OutputGroupInfo], DEV_FILES_GROUP):
        return []

    files = []

    # Otherwise the application below. `attr_aspects = ["*"]`, not an edge list:
    # the path from a launchable target down to its `flutter_application` runs
    # through rules this project does not own (`macos_application` → its
    # `deps` → a generated runner), so naming the edges would encode another
    # project's attribute names and break silently when they change.
    for attr_name in dir(ctx.rule.attr):
        attr = getattr(ctx.rule.attr, attr_name)
        deps = attr if type(attr) == "list" else [attr]
        for dep in deps:
            if type(dep) == "Target" and OutputGroupInfo in dep:
                group = getattr(dep[OutputGroupInfo], DEV_FILES_GROUP, None)
                if group != None:
                    files.append(group)

    return [OutputGroupInfo(**{DEV_FILES_GROUP: depset(transitive = files)})]

flutter_dev_files_aspect = aspect(
    implementation = _flutter_dev_files_aspect_impl,
    attr_aspects = ["*"],
    doc = """Collects the `flutter_application` outputs the dev tool reads.

Applied by the dev tool, not by users:

    bazel build //:app \\
      --aspects=@rules_flutter//flutter:dev_files.bzl%flutter_dev_files_aspect \\
      --output_groups=+flutter_dev_files

Requesting the group is what makes those files top-level, so bazel writes them
to this machine even when a cache served the actions that produced them.
""",
)
