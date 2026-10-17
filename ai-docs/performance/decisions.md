# Decisions log

Newest last. "User" means the repository owner. "Agent" means the reviewing
agent, deciding within the scope the user set.

## 2026-10-14

**Scope (user).** Analyse and optimise rules_dart and rules_flutter for
performance on large monorepos. A separate cloud agent works on rules_dart. This
review works on rules_flutter. Haiku agents do the code and verification work.

**No double work (user).** The two reviews coordinate through their `ai-docs/`
folders and direct messages to the cloud session. rules_flutter's needs from
rules_dart go in `asks-for-rules-dart.md`.

**Phase 0 first (user).** e2e against rules_dart `main`, then a Flutter
benchmark with a recorded baseline, before any optimisation lands.

**Reuse rules_dart's harness (agent).** Same scenarios and result shape, so
numbers from the two reviews can be read side by side. The harness stays a
set of reference scripts in `ai-docs/`, as rules_dart's does, not repository
tooling.

**Bazel 9.3.0 is housekeeping, not a performance item (agent).** It passes the
root suite but needs every lockfile refreshed. Its changes help remote and disk
caches, not these rules. Bump it in step with rules_dart when the user
schedules it. 10.0.0rc1 is parked until 10.0 final.

**Toolchain shape (open, user to decide).** The user asked why rules_flutter
has its own toolchain rather than using and extending rules_dart's.
`findings.md` "Two Dart SDKs in every Flutter workspace" has the facts. The
agent recommends plan item T:

- Flutter's bundled Dart becomes a rules_dart `dart_toolchain`, so every
  Flutter workspace has one Dart.
- A Flutter toolchain remains, but only for the engine artifacts. Those vary by
  target platform and are Flutter's, so they don't belong in `DartSdkInfo`.

**Toolchain shape: plan item T adopted (user).** Flutter's bundled Dart becomes a
rules_dart `dart_toolchain`, so every Flutter workspace has one Dart. A Flutter
toolchain remains for the engine artifacts only.

**Landing (user).** As in rules_dart: once a change is verified, it is
fast-forwarded onto `main` and pushed to `Mivr/rules_flutter`.

**Verification scope (user).** Linux and web on the review machine for now.
Later, xtool for the Apple paths and the Android emulator on the review
machine.

**Downloads are hermetic (user).** "The SDK should be downloaded with proper
checksums so it is a hermetic part of the build, both for Dart and Flutter
SDKs." Every repository download, whether SDK, engine artifact or pub package,
is pinned by sha256, and a missing checksum fails the fetch instead of
downloading unverified. This is plan item H0. Under T, the Dart SDK is Flutter's
`dart-sdk-<host>.zip`, which is already pinned for every listed Flutter version.

**T stays on the dart toolchain API of the published rules_dart 0.7.2 (agent).**
rules_flutter depends on rules_dart through the BCR, so T uses only
`dart_toolchain`'s 0.7.2 attributes (`dart`, `sdk_root`, `version`,
`target_os`, `target_arch`). The SDK subsets (`compile_files`/`runtime_files`)
follow when rules_flutter's pin reaches a rules_dart release that has them,
through ask E's macro if rules_dart provides it.

**The kernel compile keeps the engine's `dartaotruntime` (agent).** frontend_server
ships as an AOT snapshot in the engine's `host-tools/`, and an AOT snapshot runs
only on the `dartaotruntime` of the build that produced it. So
`FlutterSdkInfo` keeps `dartaotruntime`, `frontend_server` and the platform
dills, all from the one engine download, even if a user registers a different
Dart toolchain ahead of Flutter's. Build-step scripts and tools take `dart`
from the rules_dart toolchain.
