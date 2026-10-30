"""Canonical repo name of this package, for `package:runfiles` repo mapping.

Mirrors `//tools/pip_lock_guard:source_repo.bzl`.
"""

SOURCE_REPO = Label("//tools/e2e_patch_guard:patches_identical_test").workspace_name
