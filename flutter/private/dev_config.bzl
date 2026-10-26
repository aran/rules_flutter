"""`_dev_config.json`: the dev tool's description of a debug app's build.

The dev tool reads every path in the config off this machine. A build output
is written here only if the target declares it: being some action's input is
not enough, because a cache hit (disk or remote) runs no action and so writes
none of its inputs. A path to an undeclared output is a config the dev tool
cannot use, and it fails only once a cache holds the actions.

So the config takes its paths as Files, and `write_dev_config` returns every
one that is a build output, for the rule to declare. A path reaches the config
only through that. The other values:

- `dev_config_file(file, names)`: a file whose own content names further files
  (a package_config). The non-source `names` are declared with it.
- `dev_source_dir(file, path)`: a directory the dev tool reads by path, such as
  an SDK root. It must hold the source `file`: a source directory is on disk
  without a build writing it.
- `dev_search_roots(paths)`: the directories the dev compiler searches for a
  filesystem scheme. They name no file; what the compiler reads under them is
  named through the dev package_config.
- A string is a name, a URI, or a workspace-relative source path.
  `write_dev_config` refuses one under the output tree.
"""

_MAX_NODES = 1000000

def dev_config_file(file, names):
    """A file in the config whose content names `names`.

    Args:
      file: The File the config names.
      names: The Files `file`'s content names. Each non-source one is declared.

    Returns:
      A value for `write_dev_config`'s `fields`.
    """
    return struct(_dev_config_kind = "file", file = file, names = names)

def dev_source_dir(file, path):
    """A source directory in the config, given by a source File it holds.

    Args:
      file: A source File under `path`.
      path: The directory's execution path.

    Returns:
      A value for `write_dev_config`'s `fields`.
    """
    if not file.is_source:
        fail("dev config: %s is a build output, so the directory %s is not on disk unless a build writes it; name the directory as a File" % (file.path, path))
    if not file.path.startswith(path + "/"):
        fail("dev config: %s is not under %s" % (file.path, path))
    return struct(_dev_config_kind = "dir", path = path)

def dev_search_roots(paths):
    """Directories the dev compiler searches, which name no file themselves.

    Args:
      paths: Execution paths.

    Returns:
      A value for `write_dev_config`'s `fields`.
    """
    return struct(_dev_config_kind = "roots", paths = list(paths))

def _leaf(value, out_prefix, declared):
    if type(value) == "File":
        if not value.is_source:
            declared[value.path] = value
        return value.path
    if type(value) == "struct":
        kind = getattr(value, "_dev_config_kind", None)
        if kind == "file":
            declared[value.file.path] = value.file
            for f in value.names:
                if not f.is_source:
                    declared[f.path] = f
            return value.file.path
        if kind == "dir":
            return value.path
        if kind == "roots":
            return value.paths
        fail("dev config: a struct that is not a dev config value: %r" % value)
    if type(value) == "string" and value.startswith(out_prefix):
        fail("dev config: %s is a build output given as a string; pass its File, so the target declares it" % value)
    return value

def write_dev_config(ctx, output, fields):
    """Writes `fields` to `output` as JSON, with every path in it a File's.

    Args:
      ctx: The rule context.
      output: The declared `_dev_config.json` File.
      fields: A dict of JSON values, Files and the values this file's
        functions return, nested in lists and dicts.

    Returns:
      `output` and every build output the config names, to be declared by
      the target.
    """
    out_prefix = ctx.bin_dir.path.split("/")[0] + "/"
    declared = {}

    # Starlark has no recursion: rebuild the tree from a work list, each item
    # a value with the slot of its converted copy.
    root = [None]
    work = [(fields, root, 0)]
    for _ in range(_MAX_NODES):
        if not work:
            break
        value, parent, slot = work.pop()
        if type(value) == "dict":
            copy = {k: None for k in value}
            parent[slot] = copy
            work.extend([(v, copy, k) for k, v in value.items()])
        elif type(value) in ("list", "tuple"):
            copy = [None] * len(value)
            parent[slot] = copy
            work.extend([(v, copy, i) for i, v in enumerate(value)])
        else:
            parent[slot] = _leaf(value, out_prefix, declared)
    if work:
        fail("dev config: more than %d values" % _MAX_NODES)

    ctx.actions.write(output, json.encode(root[0]))
    return [output] + declared.values()
