"""Readers for the file contents an analysis test asserts on.

Shared rather than private to one test file: several suites need "the JSON
this rule wrote with `ctx.actions.write`", and two copies of that lookup can
disagree about which write they mean — the suffix match and the
exactly-one check are the whole contract.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def written_json(env, suffix):
    """Decode the content of the single `ctx.actions.write` output ending in `suffix`.

    Args:
      env: The `analysistest` env.
      suffix: Basename suffix identifying the write, e.g.
        `".package_config.json"`.

    Returns:
      The decoded JSON, or None when the write was not found (the
      exactly-one assertion has already failed by then).
    """
    writes = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and
           a.outputs.to_list()[0].basename.endswith(suffix)
    ]
    asserts.equals(env, 1, len(writes), "expected exactly one %s write" % suffix)
    if not writes:
        return None
    return json.decode(writes[0].content)

def package_entry(config, package_name):
    """The `package_config.json` entry naming `package_name`, or None.

    Args:
      config: Decoded `package_config.json`, from `written_json`.
      package_name: The Dart package name to find.

    Returns:
      The entry dict, or None when the config holds no such package.
    """
    if config == None:
        return None
    for entry in config["packages"]:
        if entry["name"] == package_name:
            return entry
    return None

def action_config_text(env, mnemonic):
    """The JSON config the single `mnemonic` action reads, as text.

    The rules hand their tools a config through `json_config_args`: a param
    file standing where the path after `--config` goes. An analysis test's
    `Action.argv` carries the param file's contents in that place, with the
    file paths filled in.

    Args:
      env: The `analysistest` env.
      mnemonic: The action's mnemonic, e.g. `"FlutterWebBundle"`.

    Returns:
      The config text, or None when the action was not found (the
      exactly-one assertion has already failed by then).
    """
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]
    asserts.equals(env, 1, len(actions), "expected exactly one %s action" % mnemonic)
    if not actions:
        return None
    argv = actions[0].argv
    return argv[argv.index("--config") + 1]

def action_config(env, mnemonic):
    """`action_config_text`, decoded.

    Args:
      env: The `analysistest` env.
      mnemonic: The action's mnemonic.

    Returns:
      The decoded config, or None when the action was not found.
    """
    text = action_config_text(env, mnemonic)
    return json.decode(text) if text != None else None
