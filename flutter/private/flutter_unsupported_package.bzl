"""Spoke for a lock entry rules_flutter has no repository for.

A `pubspec.lock` lists packages from sources rules_flutter cannot provide:
sources it has never heard of, and `path` packages the user declared with
`flutter_pub.from_lock(ignored = ...)`, which no Bazel build may contain. (Hosted, git and `sdk: flutter` packages it
builds, and `path` packages are the user's own targets; see
`lock_entry_kind.bzl`.) A hub that failed to load over such an entry would break
every app that merely lists it, even though nothing in Bazel uses it.

The hub therefore still lists the package. Its target is a stub that fails when
Bazel analyses something that depends on it, with a message naming the package,
where the lock got it from, and what to do. Nothing that does not depend on it is
affected.
"""

visibility("//flutter/...")

def _unsupported_package_impl(ctx):
    fail(ctx.attr.message)

unsupported_package = rule(
    implementation = _unsupported_package_impl,
    attrs = {
        "message": attr.string(mandatory = True),
    },
    doc = "A package target that fails analysis with `message`. See the file docstring.",
)

def unsupported_package_message(lock, package, source):
    """Why rules_flutter cannot provide a lock entry, and what to do about it.

    Args:
        lock: The lock file's label, for the message.
        package: The package name.
        source: The entry's `source:` in the lock.

    Returns:
        The message.
    """
    advice = (
        "rules_flutter fetches hosted and git packages and builds the Flutter SDK packages, " +
        "not packages from a \"{}\" source. Depend on a hosted release of \"{}\" " +
        "and re-resolve the lock."
    ).format(source, package)
    return "package \"{}\" (source: {}) in {} cannot be built: {}".format(
        package,
        source,
        lock,
        advice,
    )

def ignored_package_message(package, ignorings):
    """What a build that reaches a package `flutter_pub.from_lock(ignored = ...)` names fails with.

    Args:
        package: The package name.
        ignorings: `struct(lock_label, reason)` for each lock that ignores it.

    Returns:
        The message, rules_dart's `pub.from_lock`'s: what each lock says, then
        what to do.
    """
    said = sorted({
        "package `{}` (in {}) is ignored: {}.".format(package, i.lock_label, i.reason): True
        for i in ignorings
    }.keys())
    return ("flutter_pub.from_lock(): {} Something depends on it; remove that dependency, or " +
            "build the package: name it in `resolve` or `build_from_pubspec` instead of " +
            "`ignored`.").format("\n".join(said))

def _flutter_unsupported_package_impl(repository_ctx):
    package = repository_ctx.attr.package_name
    repository_ctx.file("BUILD.bazel", """\
load("@rules_flutter//flutter/private:generated_repos.bzl", "unsupported_package")

unsupported_package(
    name = {name},
    message = {message},
    visibility = ["//visibility:public"],
)
""".format(name = repr(package), message = repr(repository_ctx.attr.message)))

flutter_unsupported_package = repository_rule(
    implementation = _flutter_unsupported_package_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "message": attr.string(
            mandatory = True,
            doc = "What the package's target fails with (see `unsupported_package_message`).",
        ),
    },
    doc = "A hub spoke whose package target fails analysis; for lock entries rules_flutter cannot provide.",
)
