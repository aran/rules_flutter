# Agent instructions

## Changelog

The changelog is built from `Changelog:` trailers on commits. Nobody edits a
changelog file by hand. `cliff.toml` renders the trailers between version tags
into the release notes.

**When.** Add a trailer when a user of this project would notice the change:
new or removed API, a changed default or behaviour, a bug they could hit, a
bumped toolchain or SDK version they get. `feat`, `fix`, `perf` and breaking
(`!`) commits must have one. If such a commit is invisible to users (a fix
to tests or CI, say), write `Changelog: skip`. Other types (`chore`, `docs`,
`refactor`, `test`, `ci`, `build`, `style`) add one only when users notice,
for example a `chore` that bumps the default SDK.

**What to write.** One line saying what is different for the user, not how it
was done and not why.

- Name the user-facing thing (rule, attribute, flag, command), in backticks.
- Present tense. Capital letter or backtick first, no trailing period, at most
  100 characters.
- Say nothing about internals, file names, root causes, investigations or
  history. The commit body is where the how and why go.
- One change per line. A commit that makes two user-visible changes gets two
  trailers. A change that took five commits gets one trailer, on the commit
  that makes it usable.

```
Changelog: `flutter_ios_extension` builds iOS app extensions
Changelog: `flutter_bazel run` finds devices that answer mDNS slowly
Changelog: Default Dart SDK is 3.13.4
Changelog: Removed `flutter_app.foo`; use `bar`
```

Not these:

```
Changelog: Fixed a race in the mDNS retry loop by waiting out the window   # how
Changelog: Refactored asset bundling so hot restart works                   # how
Changelog: Because users hit X, we now Y                                    # why
```

**Where.** The trailer goes in the final paragraph of the message with the
other trailers, with no blank line inside that paragraph. Mark breaking changes
with `!` in the subject (`feat(ios)!: ...`), not a `BREAKING CHANGE:` footer,
which git does not treat as a trailer.

**Checks.** `bazel run //tools/changelog:check` checks the commit subject and
the trailers. It runs as the `commit-msg` hook, and in CI on every push where
the repo has CI. To install the hook, `uv tool install prek`, then
`prek install -f` (without `-f`, prek keeps an existing hook and runs both).
`bazel run //tools/changelog` prints the unreleased notes so you can see how
they read.

## Tooling

This is a Dart family of projects. Write repo tooling in Dart, as a
`dart_binary` run with `bazel run`. Do not add shell scripts or wrapper
scripts. When a rule can call a tool directly (multitool's `workspace_root`
with `args`, say), use it rather than a script that only forwards arguments.
Shell is acceptable only where an outside interface requires it, such as the
`release_prep.sh` the bazel-contrib release workflow calls; keep it to the
lines that interface needs.
