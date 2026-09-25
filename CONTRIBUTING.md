# How to Contribute

## Formatting

Starlark files must be formatted by buildifier, and YAML files by yamlfmt.
Git hooks check this, along with prettier, typos, file hygiene and the commit
message policy. They run with [prek](https://github.com/j178/prek), which reads
`.pre-commit-config.yaml`. Install prek with [uv](https://docs.astral.sh/uv/)
and set up the hooks once per clone:

```shell
uv tool install prek
prek install -f
```

`-f` replaces hooks already in the clone, such as ones pre-commit installed;
without it prek keeps them and runs them too. The installed hook calls the prek
at `~/.local/bin/prek`, which stays put across `uv tool upgrade prek` and
`bazel clean`. Set `PREK_QUIET=1` in your shell profile for hooks that print
nothing unless one fails.

To run every hook without installing anything beyond Bazel:

```shell
bazel run @multitool//tools/prek -- -C "$PWD" run --all-files
```

## Commit messages

Subjects follow [Conventional Commits](https://www.conventionalcommits.org/),
and user-visible commits carry a `Changelog:` trailer; see
[AGENTS.md](AGENTS.md#changelog). `prek install` sets up the check as the
`commit-msg` hook. To check a message by hand:

```shell
bazel run //tools/changelog:check -- <message-file>
```

`bazel run //tools/changelog` prints the release notes the unreleased commits
would produce.

## Using this as a development dependency of other rules

You'll commonly find that you develop in another repository that
depends on rules_flutter.

To always tell Bazel to use this local checkout rather than a release
artifact or a version fetched from the registry, run this from this
directory:

```sh
OVERRIDE="--override_module=rules_flutter=$(pwd)"
echo "common $OVERRIDE" >> ~/.bazelrc
```

This means that any usage of `@rules_flutter` on your system will point to this folder.

## Releasing

Releases are automated on a cron trigger.
The new version is determined automatically from the commit history, assuming the commit messages follow conventions, using
https://github.com/marketplace/actions/conventional-commits-versioner-action.
If you do nothing, eventually the newest commits will be released automatically as a patch or minor release.
This automation is defined in .github/workflows/tag.yaml (which calls release.yaml and publish.yaml).

Publishing to the Bazel Central Registry requires one-time setup: a fork of
`bazelbuild/bazel-central-registry` at `aran/bazel-central-registry` and a
`BCR_PUBLISH_TOKEN` repository secret with permission to push to that fork and
open pull requests. Until those exist, the build/release steps still run and a
GitHub release is created; only the BCR publish step needs them.

Rather than wait for the cron event, you can trigger manually. Navigate to
https://github.com/aran/rules_flutter/actions/workflows/tag.yaml
and press the "Run workflow" button.

If you need control over the next release version, for example when making a release candidate for a new major,
then: tag the repo and push the tag, for example

```sh
% git fetch
% git tag v1.0.0-rc0 origin/main
% git push origin v1.0.0-rc0
```

Then watch the automation run on GitHub actions which creates the release.
