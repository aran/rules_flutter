"""Adapters that hand a Flutter checkout and its engine out dirs to rules_flutter.

The engine is built outside Bazel (`et`, or `tools/gn` and ninja, in the
developer's checkout), and these repository rules point at it, like a precompiled
`protoc`: `flutter_local_engine` is an engine source (the contract of
`@rules_flutter//flutter:engine.bzl`) over the out dirs of an engine source
directory, and `flutter_local_framework` is a framework source over a checkout's
packages.

They are the halves, for an SDK that pairs a checkout's framework or engine
with another's. A checkout's own framework and engine, the pairing
`flutter run --local-engine` makes, are one declaration instead, which cannot
pair them with anything else: `flutter.checkout(name = "local")` in
`@rules_flutter//flutter:extensions.bzl`.

The paths are machine-local, so they never appear in MODULE.bazel. The
committed MODULE.bazel declares the SDK without a path, and chooses it with
`flutter.use_sdk` when the project builds with it; the paths live in the
untracked `.bazelrc.user`. `FLUTTER_CHECKOUT` is the flutter/flutter checkout,
and `FLUTTER_ENGINE` is the engine's source directory, as flutter_tools reads
it (the default of `--local-engine-src-path`), usually `<checkout>/engine/src`:

```
common --repo_env=FLUTTER_CHECKOUT=/Users/me/src/flutter
common --repo_env=FLUTTER_ENGINE=/Users/me/src/flutter/engine/src
```

MODULE.bazel:

```starlark
local_framework = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_local_framework")
local_engine = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_local_engine")
local_framework(name = "flutter_local_framework")
local_engine(name = "flutter_local_engine")

flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.custom_sdk(name = "local", framework = "@flutter_local_framework", engine = "@flutter_local_engine")
flutter.use_sdk(name = "local")
```

To build with the SDK on one machine only, leave out `flutter.use_sdk` and
put `common --@rules_flutter//flutter:sdk=local` in that machine's
`.bazelrc.user`.

Nothing is read until a build selects the SDK. Where a variable is not set,
or names no checkout or no built engine, the repositories still fetch, with
targets that fail when something uses them, so `bazel query` and
`bazel fetch --all` work on a machine without a checkout.

When the out dirs of a slot are ambiguous (both `host_debug_arm64` and
`host_debug_unopt_arm64`), pin one with `--repo_env=FLUTTER_LOCAL_ENGINES=host_debug_unopt_arm64`.
A pin chooses only for the slots it fits.
"""

load("//flutter/private:checkout_version.bzl", "checkout_channel", "checkout_framework_version", "checkout_repository_url")
load("//flutter/private:framework_source.bzl", "FRAMEWORK_JSON")
load("//flutter/private:local_engine.bzl", "read_engine_out_dirs", "unset_message")

def _source_path(repository_ctx, env, label):
    """A directory's path: the directory of the file `label` names, or the environment variable's value."""
    if label:
        return str(repository_ctx.path(label).dirname)
    return repository_ctx.getenv(env)

def _write_unusable(repository_ctx, message):
    """Writes a framework source that cannot be used, saying why.

    It still fetches, so that `bazel fetch --all` and `bazel query` work on a
    machine without the checkout: the repositories built from it hold targets
    that fail with `message` when a build uses the SDK.
    """
    repository_ctx.file(FRAMEWORK_JSON, json.encode({"unusable": message}) + "\n")

def _local_framework_impl(repository_ctx):
    env = repository_ctx.attr.path_env
    repository_ctx.file("BUILD.bazel", 'exports_files(["%s"], visibility = ["//visibility:public"])\n' % FRAMEWORK_JSON)
    checkout = _source_path(repository_ctx, env, repository_ctx.attr.checkout)
    if not checkout:
        _write_unusable(repository_ctx, unset_message(env, "a flutter/flutter checkout", "/path/to/flutter"))
        return
    root = repository_ctx.path(checkout)
    framework_pubspec = root.get_child("packages").get_child("flutter").get_child("pubspec.yaml")
    repository_ctx.watch(framework_pubspec)
    if not framework_pubspec.exists:
        _write_unusable(repository_ctx, "{}={} is not a flutter/flutter checkout: it has no packages/flutter/pubspec.yaml.".format(env, checkout))
        return

    # The packages and the files the framework expects of its tree, linked so
    # that an edit to the checkout is seen. The `sky_engine` package is the
    # engine's.
    repository_ctx.symlink(root.get_child("packages"), "packages")
    repository_ctx.watch_tree(root.get_child("packages"))
    internal = root.get_child("bin").get_child("internal")
    if not internal.exists:
        repository_ctx.watch(internal)
        _write_unusable(repository_ctx, "{}={} has no bin/internal.".format(env, checkout))
        return
    repository_ctx.symlink(internal, "bin/internal")
    repository_ctx.watch_tree(internal)

    # Which commit it is, which version, and whether it is clean: the host's
    # git, since only git can say what a developer's own checkout is. The
    # version is flutter_tools' computation from the tags, made again
    # whenever the checkout's HEAD or refs move, never read from a version
    # file a run of flutter_tools left behind.
    def git(args):
        result = repository_ctx.execute(["git", "-C", checkout] + args)
        return struct(ok = result.return_code == 0, stdout = result.stdout)

    if not git(["rev-parse", "HEAD"]).ok:
        _write_unusable(repository_ctx, (
            "{}={} is not a git checkout: a checkout's version is told from its git tags, as flutter_tools tells it."
        ).format(env, checkout))
        return
    git_dir = root.get_child(".git")
    if git_dir.is_dir:
        repository_ctx.watch(git_dir.get_child("HEAD"))
        ref = repository_ctx.read(git_dir.get_child("HEAD")).strip()
        if ref.startswith("ref: "):
            repository_ctx.watch(git_dir.get_child(ref[len("ref: "):]))
        repository_ctx.watch(git_dir.get_child("packed-refs"))
        repository_ctx.watch_tree(git_dir.get_child("refs").get_child("tags"))

        # The branch's upstream and the remotes, which name the repository.
        repository_ctx.watch(git_dir.get_child("config"))
    commit = git(["log", "-n", "1", "--pretty=format:%H"]).stdout.strip()
    version = checkout_framework_version(git, commit)
    status = git(["status", "--porcelain"])
    dirty = status.ok and bool(status.stdout.strip())

    repository_ctx.file(FRAMEWORK_JSON, json.encode_indent({
        "version": version,
        "commit": commit,
        "dirty": dirty,
        "origin": "local",
        "path": checkout,
        "channel": checkout_channel(git),
        "repository_url": checkout_repository_url(git),
    }) + "\n")

flutter_local_framework = repository_rule(
    _local_framework_impl,
    doc = "A framework source (`flutter_framework.json`, `packages/`, ...) over a flutter/flutter checkout whose path an environment variable gives.",
    attrs = {
        "path_env": attr.string(
            doc = "The environment variable holding the checkout's path. Set it with `--repo_env`.",
            default = "FLUTTER_CHECKOUT",
        ),
        "checkout": attr.label(
            doc = "A file at the root of a checkout that another repository lays out, in place of the " +
                  "environment variable: for a checkout that Bazel itself produces, such as the stand-in a test builds " +
                  "from the official artifacts.",
            allow_single_file = True,
        ),
    },
    local = True,
)

def _local_engine_impl(repository_ctx):
    path_env = repository_ctx.attr.path_env
    engine_src = _source_path(repository_ctx, path_env, repository_ctx.attr.src)
    read_engine_out_dirs(
        repository_ctx,
        engine_src = engine_src,
        named = "{}={}".format(path_env, engine_src),
        unset = unset_message(path_env, "the engine's source directory, `engine/src` of a flutter/flutter checkout, in which the engine is built in `out`", "/path/to/flutter/engine/src"),
        engines_env = repository_ctx.attr.engines_env,
    )

flutter_local_engine = repository_rule(
    _local_engine_impl,
    doc = "An engine source (the contract of `@rules_flutter//flutter:engine.bzl`) over the out dirs of an engine source directory (`engine/src`, as flutter_tools reads `FLUTTER_ENGINE`) whose path an environment variable gives: the host tools, the platform kernels, the engines of macOS, iOS, Android, Linux and Windows, their gen_snapshots, and the web SDK. A slice no out dir provides is a missing slice that says why.",
    attrs = {
        "path_env": attr.string(
            doc = "The environment variable holding the engine source directory's path. Set it with `--repo_env`.",
            default = "FLUTTER_ENGINE",
        ),
        "engines_env": attr.string(
            doc = "The environment variable naming the out dirs to use, when a slot has more than one candidate.",
            default = "FLUTTER_LOCAL_ENGINES",
        ),
        "src": attr.label(
            doc = "A file at the root of an engine source directory that another repository lays out, in place of the " +
                  "environment variable: for an engine that Bazel itself produces, such as the stand-in a test builds " +
                  "from the official artifacts.",
            allow_single_file = True,
        ),
    },
    local = True,
)
