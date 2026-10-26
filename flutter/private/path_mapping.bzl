"""Helpers that let an action run under `--experimental_output_paths=strip`.

With that flag, Bazel rewrites `bazel-out/<config>/bin/...` to
`bazel-out/cfg/bin/...` in an action that declares `supports-path-mapping`,
so the same work in two configurations (an Android ABI and its sibling, a
`-c dbg` and a `-c fastbuild` build of a platform-free step, a dependency
reached through a transition) has one cache key. Only paths Bazel can see
are rewritten: a `File` handed to `Args` (directly, with `format`, or read
inside a `map_each` callback, where `path`, `dirname` and `root.path` all
answer the mapped value) and the contents of `Args` param files. A string
built from `file.path` at analysis time, a path inside a file written with
`ctx.actions.write`, and an environment variable all keep the configuration
in them, which costs the cache hit and, inside the action, names a
directory that does not exist.

So an action that opts in carries every output path on its command line as
a `File`, and a tool that takes a JSON config gets it as a param file built
by `json_config_args`, with its paths filled in by Bazel. It declares
rules_dart's `PATH_MAPPING` as its execution requirements; Bazel applies it
only where the action is sandboxed or remote.
"""

load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")

# A file reference inside a `json_config_args` value. The index is the
# reference's position in the `refs` list, so the order `json.encode`
# writes keys in (sorted) does not matter.
_REF_OPEN = "{rules_flutter.path:"
_REF_CLOSE = "}"

def file_ref(refs, file):
    """A placeholder for `file`'s path in a `json_config_args` value.

    Args:
        refs: The list of `File`s collected for one config. Appended to.
        file: The `File` whose exec path the placeholder stands for.

    Returns:
        A string to use where the path goes. It may be embedded in a longer
        string (`file_ref(refs, d) + "/main.dart.js"`).
    """
    refs.append(file)
    return "%s%d%s" % (_REF_OPEN, len(refs) - 1, _REF_CLOSE)

def _expand_json_config(config):
    pieces = config.json.split(_REF_OPEN)
    out = [pieces[0]]
    for piece in pieces[1:]:
        end = piece.find(_REF_CLOSE)
        path = config.files[int(piece[:end])].path

        # The placeholder sits inside a JSON string, so the path goes in
        # escaped and without its quotes.
        out.append(json.encode(path)[1:-1])
        out.append(piece[end + len(_REF_CLOSE):])
    return "".join(out)

def json_config_args(ctx, value, refs):
    """`Args` holding `value` as JSON, in a param file of its own.

    The param file is the tool's config file: the `Args` object expands to
    the param file's path, which Bazel writes at execution time with every
    `file_ref` placeholder replaced by its `File`'s path, mapped or not.

    Args:
        ctx: The rule context.
        value: A JSON-encodable value whose paths are `file_ref` placeholders.
        refs: The `File`s the placeholders name, in `file_ref` order.

    Returns:
        An `Args` object to pass where the config path goes.
    """
    encoded = json.encode(value)

    # A placeholder may appear more than once (one value shared by several
    # entries), but each must name a reference: anything else is a config
    # string that happens to contain the marker.
    for piece in encoded.split(_REF_OPEN)[1:]:
        index = piece[:piece.find(_REF_CLOSE)]
        if not index.isdigit() or int(index) >= len(refs):
            fail("%s: a config value contains `%s`, which json_config_args reserves" % (ctx.label, _REF_OPEN))
    args = ctx.actions.args()
    args.add_all([struct(json = encoded, files = tuple(refs))], map_each = _expand_json_config)
    args.use_param_file("%s", use_always = True)
    args.set_param_file_format("multiline")
    return args

def dirname(file):
    """`map_each` callback: the directory holding `file`.

    Args:
        file: A `File`.

    Returns:
        Its mapped `dirname`.
    """
    return file.dirname

def output_root(file):
    """`map_each` callback: the root `file` sits under (`.` for the exec root).

    For a source file, in this repository or another, that is the exec root;
    for a generated one, its `bazel-out/<config>/bin`. A file's
    workspace-relative path (`external/<repo>/…` for another repository's)
    sits under it.

    Args:
        file: A `File`.

    Returns:
        Its mapped root's path, or `.`.
    """
    return file.root.path or "."

def sdk_action(**extra_env):
    """The `ctx.actions.run` arguments every Flutter SDK action takes.

    `dart compile` records usage under the home directory unless told not to;
    nothing else these tools run reads or writes there, so no home is set and
    the action's environment names no configuration. That lets it opt into
    path mapping on every OS.

    Args:
        **extra_env: Further environment variables for the action.

    Returns:
        A dict of `env` and `execution_requirements`, to pass as
        `ctx.actions.run(..., **sdk_action())`.
    """
    return {
        "env": {"DASH__SUPPRESS_ANALYTICS": "true"} | extra_env,
        "execution_requirements": PATH_MAPPING,
    }
