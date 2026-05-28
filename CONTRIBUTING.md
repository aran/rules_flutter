# How to Contribute

## Formatting

Starlark files must be formatted by buildifier, and YAML files by yamlfmt.
We suggest using a pre-commit hook to automate this. Two options:

### Option A — Git hook (no extra tools needed)

The repo ships with a `.git/hooks/pre-commit` script that runs buildifier,
yamlfmt, and typos via `bazel run`, so no additional installs are needed
beyond Bazel.

If the hook isn't already installed, copy it:

```shell
cp .git/hooks/pre-commit.sample .git/hooks/pre-commit
# paste the script from the repo, then:
chmod +x .git/hooks/pre-commit
```

### Option B — pre-commit

[Install pre-commit](https://pre-commit.com/#installation), then run:

```shell
pre-commit install
```

This runs the full hook suite including prettier, commitizen, and file
hygiene checks.

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
