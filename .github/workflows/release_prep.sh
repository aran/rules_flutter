#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

# Argument provided by reusable workflow caller, see
# https://github.com/bazel-contrib/.github/blob/d197a6427c5435ac22e56e33340dff912bc9334e/.github/workflows/release_ruleset.yaml#L72
TAG=$1
# The prefix is chosen to match what GitHub generates for source archives
# This guarantees that users can easily switch from a released artifact to a source archive
# with minimal differences in their code (e.g. strip_prefix remains the same)
PREFIX="rules_flutter-${TAG:1}"
ARCHIVE="rules_flutter-$TAG.tar.gz"

# NB: configuration for 'git archive' is in /.gitattributes
git archive --format=tar --prefix="${PREFIX}"/ "${TAG}" | gzip >"$ARCHIVE"

cat <<EOF
Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "rules_flutter", version = "${TAG:1}")
\`\`\`
EOF

# The notes are the `Changelog:` trailers since the previous release (see
# AGENTS.md). The release job checks out the tag alone, so fetch the history
# back to that release first.
if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
  git fetch --quiet --unshallow --tags origin
fi
echo
bazel run --noshow_progress --ui_event_filters=-info \
  @multitool//tools/git-cliff:workspace_root -- \
  --config cliff.toml --current --strip header
