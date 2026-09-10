"""Resolves the canonical Bazel repo name of `//tools/pip_lock_guard` at load
time.

`pip_facts_test` passes this to `Runfiles.create` so that apparent -> canonical
translations against `_repo_mapping` resolve from the test's own perspective.
Under bzlmod the canonical name is `_main` when rules_flutter is the main
module and `rules_flutter+` when it ships as a dep; `Label(...).workspace_name`
returns whichever applies.

Lives in its own `.bzl` because `Label` is only callable from Starlark files,
not directly from BUILD files. Mirrors `//tools/dev_tool:source_repo.bzl`.
"""

SOURCE_REPO = Label("//tools/pip_lock_guard:pip_facts_test").workspace_name
