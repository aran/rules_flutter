"""Build settings and helpers for selecting the Apple build backend.

`rules_flutter` supports two backends for iOS and macOS builds:
- `rules_apple` (default): Uses `@rules_apple` (`ios_application`,
  `macos_application`, `apple_dynamic_framework_import`, etc.) with a local
  Xcode installation on macOS.
- `xtool` (explicit opt-in): Uses `@flutter_xtool_darwin_sdk`
  (`darwin.artifactbundle` + `ld64.lld` + `llvm-lib` + `OpenAppleMacrosServer`)
  and the hermetic pure-Dart `xtool_pack` bundler to build and package
  unsigned `.app` / `.ipa` bundles on Linux (or signed when `zsign` is
  configured).
"""

APPLE_BACKEND_VALUES = [
    "rules_apple",
    "xtool",
]

USE_XTOOL_BACKEND = Label("//flutter/settings:use_xtool_backend")
IS_XTOOL_EXPLICIT = Label("//flutter/settings:is_xtool_explicit")
IS_RULES_APPLE_EXPLICIT = Label("//flutter/settings:is_rules_apple_explicit")
