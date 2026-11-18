# Testing Guide

Complete instructions for testing rules_flutter changes. Run **all applicable sections** before considering work done.

> **Never run `bazel clean`** — it destroys the cache and causes long rebuilds.

> **Capture the whole run to a file, then read the file.** Anything long — `bazel
> test //...`, the e2e suite, a manual `flutter_bazel run` — goes to a log that is
> inspected afterwards. Never watch one through a `tail`/`grep`/`head` filter on
> the live pipe: the filter has to be chosen before you know what went wrong, it
> keeps only the lines you already thought to ask for, and the output is gone once
> it has scrolled past. The failure is routinely somewhere other than the line you
> matched on.
>
> Redirect rather than pipe, so the exit status survives as well — a shell reports
> the *tail* of a pipeline, so `… | tee log` leaves `$?` at 0 no matter how the
> command exited (§ 2 has the `dart test` case):
>
> ```sh
> bazel test //... > /tmp/root-tests.log 2>&1; echo "exit=$?"
> grep -n 'FAILED\|ERROR' /tmp/root-tests.log   # afterwards, against the file
> ```
>
> If you must watch a run as it happens, `tee` to the file and read *that*
> afterwards — `cmd 2>&1 | tee log` — and take the status from `$pipestatus[1]`
> (zsh, this repo's shell) or `${PIPESTATUS[0]}` (bash), never from `$?`. The two
> are not interchangeable: zsh arrays are 1-indexed, so `${PIPESTATUS[0]}` there
> expands to the empty string rather than to a status, and a test for it being
> non-zero silently passes.

## 1. Root workspace

```sh
bazel test //...
bazel test //... --config=deep   # before a merge, and in a Flutter version bump
```

Tests tagged `deep` are left out of a plain `bazel test` (`.bazelrc`), from building as well as from running, and so are the targets only they build, which carry the tag too: a test only filtered out of running would still be built, and its downloads fetched. They are the heavy ones, or ones only a toolchain bump can break: today, the outline-cutoff tests of `//flutter/tests/outline_fixture` under each supported Dart release but the default's, each of which fetches another Flutter SDK (about 330 MB); and `//tools/dev_tool:source_watcher_fs_test`, the one dev tool test over the platform's real file watcher, whose verdict rests on the OS delivering file events in time (macOS FSEvents stops delivering for a minute or more while other processes write heavily, as a plain `bazel test //...` does, so run it on a machine left to itself). CI runs them in its weekly run.

### Proving analysis covers a file

`bazel test` runs `dart analyze` and the `dart format` check as rules_dart's
`dart_analyze` aspect (`.bazelrc`), over each target's own hand-written files:
a library's sources, and an executable's `[main] + srcs`. A clean run proves
nothing about a file until you have seen it go red. Nothing checks that the
target you believe owns a file actually carries it, so a file no checked target
owns passes exactly as quietly as a clean one. The aspect also never visits a
`manual` target, or one incompatible with the host, since `//...` does not
expand to either. Prove coverage by making a deliberate diagnostic appear — a
transient file whose only content is an unused import — and confirming the
build fails **at that file's own path**, then restoring and confirming green.

Which probe discriminates depends on the owning target's shape:

* **Target carries `srcs`** → drop the probe in as a new, *unimported* file.
  Unimported is what makes it proof: an imported one is reached through `main`'s
  own closure, so the target goes red whether or not `srcs` carries it.
* **Target is `main`-only** — a `main` and no `srcs`
  (`//tools/update_flutter_version`) →
  transiently repoint `main` at the probe; restoring must return it to green.
  The dropped-file form cannot discriminate here: a probe added to a `srcs` the
  committed target does not have goes red even if the `main` slot is never
  analyzed at all.

Place the probe at the full extent the coverage claims, not at its shallowest
point. A flat glob (`test/e2e/*.dart`) with a probe dropped at the top of
`test/e2e/` passes over the gap; only a probe in a *subdirectory* catches it —
a depth where a test `dart test` would discover and run can sit with nothing
analyzing it. A probe answers only for the depth and shape it was placed at.

The principle under all three: **the probe must exercise the same staging path
the committed target uses.** One that produces a diagnostic by some other route
proves the analyzer works, not that this target covers anything. This is not
specific to analysis — any probe meant to prove a check *can* fail has to fail
through the path the committed check actually takes.

### Never apply `dart fix` unreviewed

`bazel run @rules_dart//dart/fix -- <patterns>` writes the analyzer's fixes
back into the tree. **The reviewed diff is the deliverable, not a green
build**: never run it and commit the result unread. (`bazel run
@rules_dart//dart/format -- <patterns>` is safe to apply as it stands: it writes
exactly what the format check would otherwise fail on.) Everything after the
`--` is what the tools' own `bazel build` receives, so a `deep`-tier target
needs its config there: `bazel run @rules_dart//dart/format -- --config=deep
//:gradle_host_test`. An exclusion pattern needs a `--` of its own first, as
with `bazel build`: `-- //app/... -//app/gen/...`.

The reason: `avoid_redundant_argument_values` deletes `sourceRepository:` from
`Runfiles.create` call sites. That argument is a
`String.fromEnvironment('RUNFILES_SOURCE_REPO')` const supplied by the BUILD
file's `defines`, and **the analyzer receives no `-D` defines**, so it sees the
empty-string `defaultValue` and calls the argument redundant. The result
compiles and every unit test passes; it breaks runfiles resolution only for
downstream consumers, where nothing in this repo would notice.

**Any lint that reasons about a constant's value misfires the same way**, since
the analyzer never sees the build's defines. That is the general case, not one
bad rule.

### Why the Windows capture helper is native

A `py_binary` cannot run here. rules_python's `stage2_bootstrap_template.py`
finds runfiles only as a *directory* — it reads `RUNFILES_MANIFEST_FILE` solely
to derive a directory name, then requires that directory to exist, and never
reads the manifest. Bazel on Windows defaults to `--noenable_runfiles`, so no
tree is materialised and the check cannot pass. **No value the parent forwards
fixes this.**

So `screenshot.cc` captures through DXGI Desktop Duplication and encodes with
WIC, linking Windows SDK libraries only: it reads nothing at runtime and has no
runfiles to lose — the same shape as `//tools/macos_screenshot:screenshot`.

Two consequences worth keeping in mind:

- **MSVC is a host dependency**, discovered the way `rules_apple` discovers
  Xcode — there is no hermetic MSVC. It costs nothing here, because
  `flutter_windows_application.bzl` already compiles the Win32 runner from C++,
  so Windows users need it regardless, and the macOS helper makes the same
  bargain with Xcode.
- **Linux needs no helper.** The dev tool reads the X display itself over
  the X11 protocol (`lib/x11_screenshot.dart`: connect to `DISPLAY`, open it
  with the `Xauthority` cookie, `GetImage` of the root window, encode a PNG),
  so a host with no `scrot` captures all the same. Its unit test serves a
  fake X server on a loopback socket; it has not been run against a real X
  server by the suite.

**Upstream ask**: rules_python's bootstrap should read
`RUNFILES_MANIFEST_FILE` rather than only deriving a directory from it. That
is the general fix for any `py_binary` spawned from another binary's runfiles
on Windows.

### Language versions: unset, with pubspecs at the pinned SDK

No `dart_package_metadata` in this repo states `language_version`, and none should without a
reason that requires it. Unset, a target is compiled, analyzed and
format-checked at the SDK's newest language version, and an entrypoint inside
a package takes that package's version.

That default is right only while every `pubspec.yaml` states the SDK this repo
pins as its `sdk:` lower bound (`^3.13.0` today). `dart format` run by hand or
by an IDE takes its version from that lower bound, through the
`.dart_tool/package_config.json` pub writes, while the format check (rules_dart's
`dart_analyze` aspect) formats at the SDK's newest. When the two differ, as
they did at Dart 3.13, which rewraps a long `typedef`, each reformats the
other's output.

So bumping the pinned Flutter/Dart SDK means raising every `pubspec.yaml`'s
`sdk:` lower bound, and the `sdks:` floor of its `pubspec.lock`, to the new
version in the same change, then reformatting whatever the new style moves.
The one exception is `flutter/private/gen_l10n/pubspec.yaml`, which matches
upstream `flutter_tools` exactly.

### A green sweep does not test the published rules_dart pin

The repo root and every `e2e/` workspace carry a gitignored
`.bazelrc.user` holding:

    common --override_module=rules_dart=/Users/aran/Projects/rules_dart
    common --lockfile_mode=off

So every local build resolves rules_dart **main**, and the committed
`bazel_dep(name = "rules_dart", version = ...)` is inert. CI has no such file —
it is gitignored and no sibling checkout exists there — so CI builds against the
published pin. A full green sweep is therefore *no evidence* that the code works
against the version consumers get.

Two different kinds of breakage hide behind this, and only the second is widely
known:

1. **Starlark API** — a rule or attribute that exists only on rules_dart main.
   This fails at *loading*, loudly, the moment you remove the override.
2. **Dart SDK version** — this fails at *compilation*, long after loading and
   module resolution have succeeded, so any check that stops at "it loaded" will
   miss it entirely.

The second is the nastier one. `dart_binary` compiles with **rules_dart's**
exec-tools Dart, not the Flutter SDK's Dart, even inside rules_flutter. The
Flutter Dart is downloaded but only as the `dart_sdk` file sets, not as a
registered toolchain. So Dart source using an API newer than rules_dart's Dart
builds clean locally and fails on CI, whenever the sibling checkout carries a
newer Dart than the published pin.

**Check any new or changed `dart_binary` like this** — it must *compile*, not
merely load:

    mv .bazelrc.user .bazelrc.user.aside
    bazel build --lockfile_mode=error //path/to:target
    mv .bazelrc.user.aside .bazelrc.user

To check one workspace's lock by hand, use the lock check below, with the
`.bazelrc.user` files moved aside as it describes.

Two cautions:

- **Do not run this while another session is building out of the same tree.**
  It changes the resolved rules_dart mid-flight, which produces failures that
  look like your change and are not.
- **Restore the file.** Verify with `find . e2e -maxdepth 3 -name .bazelrc.user`
  before moving on; a half-restored override is a confusing state to inherit.

When the right fix is a newer rules_dart, say so upstream rather than reaching
for a toolchain override locally. When the offending code is dead in this
context, deleting it is the better answer, and should be commented as
deliberate so nobody later "restores" it.

### Testing against another rules_dart

To build against a rules_dart other than the sibling checkout, such as its
committed HEAD while that tree is being changed, export it to a directory and
override the module there:

    git -C ../rules_dart archive HEAD | tar -x -C /tmp/rules_dart_snapshot
    bazel test --override_module=rules_dart=/tmp/rules_dart_snapshot //...

The e2e tests that generate a workspace (`pub_inputs_fixture.dart`,
`digest_probe.dart`) copy the repository's `.bazelrc.user` into it, so a
command-line override does not reach them. Set `E2E_RULES_DART_OVERRIDE` to the
directory instead; it replaces that file's rules_dart override, or adds one:

    E2E_RULES_DART_OVERRIDE=/tmp/rules_dart_snapshot \
      bazel run //tools/dev_tool:e2e -- test/e2e/pub_versions_e2e_test.dart

### Lock files

Every `e2e/` workspace commits a `MODULE.bazel.lock`, and the committed
`.bazelrc` of each says `common --lockfile_mode=error`: a build fails rather
than rewrite or quietly ignore a lock that is stale or incomplete. So does the
root's. Your own `.bazelrc.user` turns that off (see above), which is why a
local sweep cannot tell you a lock has drifted. This does, from the repository
root:

    bazel run @overhead//locks:check

overhead is the dev-tooling module rules_flutter shares with rules_dart (see
"Tooling" in `AGENTS.md`). For the root and every workspace under `e2e/` with a
`MODULE.bazel` it runs both `bazel mod deps` and `bazel build --nobuild //...`
with `--lockfile_mode=error`. Run both: each has passed a lock the other rejected
(`mod deps` caught a stale `rules_dart` `pub` entry in `e2e/smoke` and a
missing protobuf entry in what is now `e2e/package_assets`;
`build --nobuild` passed both; and a `build --nobuild` has caught a stale lock
`mod deps` passed). Workspaces are found from `git ls-files`, so a new tracked
workspace is covered without being listed anywhere. A workspace that is meant to
fail carries a `lock_expected_failure.txt` naming what its failure prints.

It runs Bazel with every rc file Bazel reads: each workspace's committed
`.bazelrc`, its gitignored `.bazelrc.user` and your `~/.bazelrc`. Move the
`.bazelrc.user` files (the root's and every workspace's) aside first, and put
them back afterwards: their `--override_module` lines would put a local checkout
into the lock. Startup options such as `--max_idle_secs` do not reach a lock, so
a `.bazelrc.user` holding only those can stay.

It lists each stale workspace with the command that fixes it:

    bazel run --lockfile_mode=off @overhead//locks:refresh -- e2e/smoke

which runs `bazel mod tidy --lockfile_mode=refresh`, then
`bazel mod deps` and `bazel build --nobuild --lockfile_mode=update //...`, again
with the `.bazelrc.user` files moved aside (regenerating through them writes a
lock that omits the registry entry for rules_dart). A stale Maven lock fails these steps; see
"Maven lock files" below for the re-pin, then refresh again. Commit the changed
lock with the change that made it stale.

Analysing `//...` needs every platform's toolchain, so run it on macOS. CI
splits it in two, on every push and pull request: the `Lock files (macos-latest)`
job checks the workspaces whose table entry (`tools/ci_matrix/e2e_matrix.dart`)
runs on macOS or on no system, and `Lock files (ubuntu-latest)` the root and the
rest, which analyse on Linux in their own jobs. Run it yourself after a change
to a `MODULE.bazel`, before you push.

#### Maven lock files

Every `maven.install` in the root `MODULE.bazel` and the e2e workspaces names a
`lock_file`, a rules_jvm_external lock holding each jar's URL and sha256. Without
one, rules_jvm_external resolves the artifacts through Coursier, which keeps no
checksums, so nothing reaches Bazel's repository cache and every fresh output
base and CI runner downloads every jar again (the Android set is 371 MB, one jar
of it 158 MB; Maven Central answered 429 for that jar on 2026-11-03). With the
lock each jar is an `http_file` with a sha256, so a second output base takes it
from the repository cache.

| Lock | In | Pins |
|---|---|---|
| `rules_flutter_maven_install.json` | the repo root, and the Android e2e workspaces that add artifacts (`plugin_example`, `android_example`, `integration_test`) | `@rules_flutter_maven` |

`hello_world` and `custom_engine` add none and declare no install: they use the
root's lock, as a consumer whose plugins declare no Maven artifacts does.
rules_android 0.8.1 pins its own installs, `@rules_android_maven`,
`@android_ide_common_30_1_3` and `@bazel_worker_maven`, with locks of its own,
and no workspace declares them.

A workspace's lock holds the artifacts of every module that contributes to the
repo, not only the ones the file next to it lists: `@rules_flutter_maven` merges
what rules_flutter and the workspace declare, and rules_jvm_external takes the
highest version of an artifact both name. So a change to the root
`maven.install` makes the root lock and the e2e locks stale, and a change to a
workspace's list makes its own.

Evaluating the extension warns when a repository has contributions from other
modules that its root `maven.install` does not name (`known_contributing_modules`,
which then limits the contributors to those named), and when a root artifact is
overridden by a dependency's higher version. A lock lets Bazel replay the last
evaluation without printing either, so the lock check also evaluates the extension
afresh: `REPIN=1 bazel fetch --repo=@<install> --lockfile_mode=off` on a new
server, in the repository root and every workspace with a pinned install, and
fails on either warning (`mavenWarnings` in `tools/maven_locks/maven_locks.dart`).
It ignores the workspace's `.bazelrc`, which evaluating an extension does not read.

The root `maven.install` also passes Coursier `--reconciliation *:*:relaxed`
(`additional_coursier_options`), so an exact POM range such as `fragment [1.3.6]`
no longer fails the pin when another artifact wants a higher version. Options are
concatenated across modules, so the e2e workspaces get it without repeating it.
Changing it changes how every lock resolves; re-pin all of them. It does not
make the root install's `androidx.lifecycle` entries unnecessary: without the
lines that pin `lifecycle-livedata`, `-livedata-core` and
`-viewmodel-savedstate` to 2.10.0, Coursier resolves but takes the old versions
other artifacts ask for (2.0.0, 2.6.1, 2.6.1, and `savedstate` 1.2.1) beside
`lifecycle-runtime` 2.10.0. `//tools/maven_locks:root_lock_test` fails on a
root lock where the group is not at one version.

The root's lock ships to consumers. rules_jvm_external takes the one lock a
repository's modules name, and the root module's when it names one, which then
pins the whole merged repository. So a consumer that adds no artifacts gets the
root's lock, and one that adds some declares `maven.install(name =
"rules_flutter_maven", lock_file = ...)` itself (README, "Maven dependencies").

A stale lock fails the build, at the point the repo loads:
`rules_flutter_maven_install.json contains an invalid input signature ... must
be regenerated`. `bazel run @overhead//locks:check` finds it in each e2e workspace
(`build --nobuild //...`), and the Maven check of rules_flutter's own finds the
root's: `bazel fetch --repo=@rules_flutter_maven`. That check is

    bazel run //tools/maven_locks

and also fails a `maven.install` in the root or an e2e `MODULE.bazel` that names
no `lock_file` (installs a dependency declares are not seen), and the warnings
above. Run both commands; neither covers the other.

To regenerate, after a change to the artifacts or to a module that contributes
them:

    bazel run //tools/maven_locks -- --refresh e2e/plugin_example
    bazel run --lockfile_mode=off @overhead//locks:refresh -- e2e/plugin_example

The first re-pins every stale Maven repo of that workspace (`REPIN=1 bazel run
@rules_flutter_maven//:pin` underneath, run in the workspace); the second
refreshes its `MODULE.bazel.lock` as above. The root's lock is re-pinned the same
way, `bazel run //tools/maven_locks -- --refresh .`, and then every Android e2e
lock the change reaches. Pinning resolves through Coursier, so it needs Maven
Central and maven.google.com. Commit the changed lock with the change that made it stale.

A re-pin of `plugin_example` that changes a version also takes its
`test/gradle_module_metadata.json`: the Gradle module metadata of what the lock
resolves, which `verify_android_maven_artifacts_test` reads in place of
maven.google.com so that `//...` needs no network. The test fails naming each
artifact the snapshot lacks; `bazel run //:record_gradle_module_metadata`
records it again from the live repositories. `gradle_module_metadata_live_test`,
in the workspace's `deep` tier, fails when the snapshot and the live metadata
differ. A new `maven.install` needs its lock
file to exist first (an empty file will do); the run then fills it.

## 2. dev_tool tests

Unit tests run under section 1 — every one of them has a Bazel target, on the
hermetic toolchain. To run just those:
```sh
bazel test //tools/dev_tool/...
```

E2e tests spawn real builds and drive real devices, so they are not Bazel
targets (they invoke `bazel` themselves) and run sequentially. Run them through
the guarded runner:
```sh
bazel run //tools/dev_tool:e2e
```

It forwards its arguments to `dart test`, so scoping works as usual — any
positional argument replaces the default `test/e2e/` path, and paths are
relative to `tools/dev_tool` from whatever directory you run it in:
```sh
bazel run //tools/dev_tool:e2e -- --plain-name="macOS"
bazel run //tools/dev_tool:e2e -- test/e2e/agent_e2e_test.dart
```

**A case whose device is missing fails; it does not skip.** The full sweep
drives every platform, so a bench without one fails that platform's cases,
naming what is missing and how to provide it: an Android case with no device
in `adb devices` says to boot an emulator or authorize a phone, and an iOS
case with no booted simulator says so. A bench that lacks a platform leaves it
out by tag, which drops those cases before they run:
```sh
bazel run //tools/dev_tool:e2e -- --exclude-tags android
bazel run //tools/dev_tool:e2e -- --exclude-tags android,ios_sim
```
The tags are `android`, `ios_sim`, `macos`, `linux`, `windows` and `web`,
declared in `tools/dev_tool/dart_test.yaml`; every case that needs one of those
devices carries it. A case that this host's OS cannot run at all (a Windows
case on a Mac) is still skipped, and the runner lists it before its verdict. A
green run therefore means every platform you did not exclude ran.

**Give the suite the workspace to itself.** Every case builds and launches a real
app with deadlines in minutes, and a `bazel` in this workspace takes the same
lock the suite's builds need. Running anything else here while it goes — a
`bazel test`, a `bazel build`, or a **`git commit`, which fires three bazel
invocations through this repo's hooks** — pushes cases over their `app.started`
and control-channel timeouts. Measured 2026-09-17: the same tree gave **53
passed / 20 failed** with commits landing alongside it and **73 passed / 0
failed** on a quiet machine, ~40 minutes apart. The failures name nothing about
their cause, so the temptation is to go hunting in the change.

### Why a runner rather than a bare `dart test`

Because `dart test` has a way of finishing without running the suite that looks
exactly like success. With `package:test` 1.31 — the version `pubspec.lock`
resolves, not the `^1.25.0` the pubspec asks for:

| condition | exit | verdict |
|---|---|---|
| version solving fails (a dep cannot resolve) | 65 | loud |
| nothing selected (`--tags` / `-n` match none) | 79 | loud |
| **every selected test skipped** | **0** | **silent** |

The third row is the hole, and it is reachable rather than theoretical:

```sh
$ cd tools/dev_tool
$ dart test test/e2e/agent_e2e_test.dart --tags=e2e --plain-name="occluded"
00:23 +0 ~1: All tests skipped.
$ echo $?
0
```

Zero tests ran; the shell was told everything is fine. About half the e2e files
have at least one case `skip:`-gated on `Platform.isMacOS` (or on a flag derived
from it). On any other host, a file whose cases are all gated "passes" having
executed nothing; a file that also has Chrome cases runs those and skips the
rest.

`tool/e2e.dart` closes that by reading `dart test`'s machine-readable result
stream instead of its exit code, and failing when the number of tests that
actually *ran* is zero. It runs the suite on `Platform.resolvedExecutable`, the
VM running the runner itself, so the `dart` its first line of output names is
the one that runs — see the next section.

The same goes for each selector you pass. A test file, `--plain-name` or
`--name` that ran no case fails the run and is named in the verdict, even when
the other selectors ran plenty: `dart test` joins them, so a mistyped name, or
one file of six that is all gated on macOS, would otherwise leave the run green
having proved nothing about it. A selector whose cases were all skipped on this
host fails the same way and says so. A `--tags` selector is not checked
one by one, since the result stream does not say which tags a case has; a run
that selects nothing at all names the tags `dart_test.yaml` does not declare.

One trap worth naming if you ever parse that stream yourself: a skipped test
reports `result: "success"` in the JSON reporter, for backwards compatibility.
The predicate for "ran and passed" is `result == "success" && !skipped
&& !hidden`.

### The suite runs on the toolchain's Dart

`//tools/dev_tool:e2e` is `tool/e2e.dart` compiled to a kernel, so the VM that
runs it, and then the suite, is the `dart` of the toolchain the build compiles
with. No `dart` on `PATH` is consulted, and none is needed.

The runner resolves the pub workspace with `dart pub get` before it starts
`dart test`. Left to `dart test`, a fresh checkout can fail before any test
runs with `Bad state: Attempting to send request on closed client`: Dart 3.13's
pub resolves there, judges its own result stale whenever a workspace member's
`pubspec.yaml` is newer than `pubspec.lock`, and the second resolution finds its
HTTP client already closed. The workspace has packages depending on
`sdk: flutter`, which a bare Dart SDK cannot resolve.
The runner sets `FLUTTER_ROOT` to `@flutter_dev_root`, the same tree
`bazel run //flutter/pub` resolves `pubspec.lock` against. Both paths are on the
runner's first lines of output.

The suite runs `bazel` itself, in this workspace among others. That does not
wait on the `bazel run` that started it: Bazel builds the target, releases the
workspace, and only then starts the binary. The runner finds the source tree
through `BUILD_WORKSPACE_DIRECTORY` and starts the suite without the variables
`bazel run` set for the runner. The dev tool the suite drives reads
`BUILD_WORKSPACE_DIRECTORY` before anything else, so a leftover one would aim
its sessions at this workspace instead of the e2e workspace each test chose.

### The suite drives the shipped binary

`startDevTool` / `attachDevTool` launch the AOT `dart_binary`
`//tools/dev_tool:flutter_bazel` — what a user installs. The harness builds it
itself (`ensureBuiltDevTool`, once per test file), so there is no `bazel build`
pre-step and no way to measure a stale binary; a failed build ends the run
quoting Bazel's own output rather than falling back.

Passing `viaDartRun: true` launches `bin/flutter_bazel.dart` through the
toolchain `dart` instead. Exactly one case does — a deliberate negative control
in `machine_protocol_e2e_test.dart` that keeps the from-source path, and the
"Running build hooks…" stdout prefix only it produces, exercised. That case is
the reason `hermeticDart` still exists.

### The Android SDK and NDK are downloaded

The root and every Android e2e workspace (`android_example`, `custom_engine`,
`hello_world`, `integration_test`, `plugin_example`) take the Android SDK and
NDK from hermetic_android_toolchains, as the README recommends, and accept their
licences in the checked-in `.bazelrc`. Nothing needs to be installed or
exported: `ANDROID_HOME` and `ANDROID_NDK_HOME` are read by no workspace here.
The first build of each fetches about 1.1 GB on a Mac (the NDK is 950 MB, 2.8 GB
unpacked); the repository cache keeps the archives and the repository contents
cache the unpacked NDK, both shared by every workspace, and each output base
unpacks its own 350 MB of SDK.

Every build in such a workspace fetches the SDK repository, whatever the
target, because rules_android registers `@androidsdk//:all` for every module
that depends on it; a test that copies a workspace (`editableWorkspace`) copies
the `.bazelrc` that accepts the licences with it.

### macOS permission prerequisites

Two e2e groups drive the OS, not just the app, and macOS gates both behind
permissions granted to **the terminal (or IDE) that launches the tests** —
neither can be granted programmatically. Grant them in
System Settings → Privacy & Security:

| Permission | Needed by | Symptom when missing |
|---|---|---|
| **Screen Recording** | `macos_e2e_test.dart` and `multi_window_e2e_test.dart` native-screenshot tests (ScreenCaptureKit) | Test **fails**: `No window titled … Available titles: []` — with the permission missing, `SCShareableContent` still returns windows but their titles come back empty. Not every native-screenshot failure is this one; see "The display must be awake for the native-screenshot tests" below, and read the helper's own message, which names the windows it found |
| **Accessibility** | `agent_e2e_test.dart` occlusion test, which minimizes the app window via `AXMinimized` | (A locked screen or sleeping display produces the same symptoms with the grant intact; see "macOS runtime smoke test" for telling them apart.) Test **fails**, after `osascript` refuses in well under a second: `setting AXMinimized=true on the "Hello World" window failed: exit 1: … not allowed assistive access`, followed by the reading of the session (see "macOS runtime smoke test"). On macOS 27 (Darwin 27.0) the same refusal reads `Can’t get window 1 of process "Hello World". Invalid index. (-1719)`: System Events answers an untrusted client with no windows for any app, so the app's window looks missing rather than forbidden — `count of windows of process "<your terminal>"` coming back `0` is the tell |
| **Automation** (System Events) | the same test, same `osascript` call | Test **fails**, after the bound expires: `setting AXMinimized=true on the "Hello World" window failed: timed out`. Unlike a refusal this one has no error to return — with the permission undecided, the AppleEvent send simply blocks — so the call is given ten seconds and then killed |

These dependencies are essential rather than incidental: there is no way to
capture a real window without Screen Recording, and no way to get a window off
screen — the state the occlusion regression is about, in which an agent must
still get a bounded answer and the tap must still be delivered — without
OS-level window control. Stubbing either would mean the test no longer
exercises the behaviour it exists to guard.

A missing permission, a locked screen and a sleeping display all fail the test,
with the session read after the failure (`GuiSession` in
`tools/macos_gui_session/lib/macos_gui_session.dart`, shared with the e2e workspaces'
tests) naming which one it is. The group also holds the display awake for its
run (`caffeinate -d -u`), so a dark panel is woken before the first window is
asked about. A test that cannot get the window it exists to drive has not
passed, so none of this skips.

### The display must be awake for the native-screenshot tests

**`Failed to start stream due to audio/video capture failure` is a sleeping
display, not a missing permission.** ScreenCaptureKit keeps enumerating windows
after the panel powers down — and keeps resolving their titles, which requires
Screen Recording — so the failure names the windows it found and then refuses
to capture any of them:

```
Skipping window 15793 (Planner — Calendar): Failed to start stream due to audio/video capture failure
No capturable windows for the target pid.
```

Seeing real titles in that message is the tell that the permission is granted
and something else is wrong. The suite runs unattended for minutes,
`displaysleep` defaults to 10, and a terminal driving tests is not user
activity, so the display idles out mid-run.

Hold the display on for the duration:

```sh
caffeinate -d -u bazel run //tools/dev_tool:e2e
```

`-d` is the display-sleep assertion specifically; plain `caffeinate` prevents
only *system* sleep and will not help. `-u` matters just as much and for a
different reason: `-d` keeps an awake display awake but does **not** wake one
that is already off, so a suite started against a dark panel fails exactly as
above with the assertion held the whole time. To wake it first without starting
a run: `caffeinate -u -t 3`.

To confirm after the fact:

```sh
pmset -g log | grep -E "Display is turned (on|off)|delayDisplayOff"
```

### Read `uptime` before you start, and again before you believe the result

Every test in this suite builds, launches and drives something under a wall
clock, so a machine that is already saturated does not produce a slower sweep —
it produces a sweep whose failures are about the machine. Establish idleness by
reading the load, not by grepping for process names you recognise:

```sh
uptime                       # before starting, and again when reading results
```

This is a **precondition for trusting a run**, not a cutoff: a sweep started
against a busy machine tells you nothing, but no load level predicts any
particular failure. For a failure you already have, see "'It failed under load'
is not a diagnosis" below.

**`memory_pressure` does not report free memory**, whatever its output says.
Its "System-wide memory free percentage" is a *pressure* metric. Read memory off
`vm_stat` and do the arithmetic (free + inactive + speculative, times the page
size) rather than off that line.

Some cases in this suite depend on the machine's GUI state — Screen Recording,
window enumeration, an awake display — so a failure there can be about
the environment rather than the code; the permission and display sections above
say which.

### "It failed under load" is not a diagnosis

Reading a load average *before* a sweep, to decide whether the result is worth
trusting, is sound — see "Read `uptime` before you start" above. Reading one
*afterwards* to explain a failure you already have is not: load average is not
the predictive axis, and quoting one as though it were a threshold invites the
mistake this section exists to stop.

**Do not treat "failed under load" as established without a preserved failing
log.** `bazel-testlogs` is overwritten by the next run — including by the rerun
you do to confirm. Copy the failing `test.log` out *before* re-running anything.

When re-running to reproduce, use `--nocache_test_results` and read the
`Stats over N runs` line — the summary line says "1 out of 1" whatever `N` is.

### Dev tool e2e test matrix

| Test file | Platform | What it validates |
|-----------|----------|-------------------|
| `macos_e2e_test.dart` | macOS | Both HTTP control-channel screenshot endpoints: `screenshot/flutter` — asserted as a **refusal**, since Flutter 3.47's macOS Impeller default means the VM service's `_flutter.screenshot` can no longer encode, so the endpoint must answer `501` naming the native one — and `screenshot/native` (the bundled ScreenCaptureKit helper, which is why it runs from the built binary rather than `dart run`). The refusal is asserted through `httpFlutterScreenshotReply`, not `httpScreenshot`, which follows a `501` through to `native` and would quietly duplicate the second case |
| `web_e2e_test.dart` | Any (needs Chrome) | WASM + JS `--screenshot` (CDP), `--machine` screenshot — the JS one over `:app_js`, whose `base_href = "/web_example_js/"` the dev server has to serve under, so it asserts the launch URL's path and a rendered page — and what a `--wasm` run tells a client: `app.webLaunchUrl` carries the served address and the browser's DevTools endpoint (`cdpPort`, the page's `webSocketDebuggerUrl`), and the `app.*` agent surface is offered (over the page bridge, with `X-Settled: yes` on screenshots). A second `--wasm` case drives the app: `app.dumpWidgetTree`, `app.dumpSemanticsTree`, `app.getText`, `app.tap`, `app.enterText`, `app.pressKey`, a screenshot, then `app.restart` and `app.getText` on the reloaded page |
| `web_wasm_only_e2e_test.dart` | Any (needs Chrome) | A `js_fallback = False` app (`web_example //int64/wasm_only:wasm_only_app`, an `Int64List` DDC cannot compile, with no JavaScript variant) run with no flags says `wasm_only_target_runs_wasm` at startup, runs the dart2wasm loop and renders (its text read from the widget tree over the page bridge, with a settled screenshot), and announces no VM service. With `--no-wasm` it warns `ddc_for_wasm_only_target` and the DDC loop's first compile fails on the 64-bit literal, which is the failure the default spares |
| `web_per_compiler_e2e_test.dart` | Any (needs Chrome) | An app whose code differs by compiler (`web_example //int64:int64_app`: `package:int64_ids` is an `Int64List` library under dart2wasm and a `List<int>` one under dart2js and DDC, picked by a `select()` on `@rules_dart//dart/constraints:js`) runs the right program under each, and keeps the dart2js fallback it could not keep if both compilers were handed the `Int64List`. Three runs, each reading its text from the widget tree over the agent surface and taking a settled screenshot: `--wasm` draws `Int64List max: 9223372036854775807`; `--no-wasm`, the DDC loop, draws `List<int> max: 9007199254740991` and announces a VM service, which shows DDC builds the JavaScript branch; and `:int64_app_js_fallback`, the same program with Chrome left out of the WebAssembly allow-list, draws the `List<int>` text from the dart2js build in `main.dart.js` |
| `web_viewport_e2e_test.dart` | Any (needs Chrome) | `--web-viewport` captures at the size asked for, measured on the PNG from `screenshot/native`: `390x844@3` is 1170x2532 and survives a hot restart and an `app.setViewport` to 900x1500, and `390x844` is 390x844. Chrome 154 drops the CDP override when the connection that set it closes, so a tool that applied it and hung up launched cleanly and captured at the window's own 2400x1713 — a run that only checked the launch, or a fake that models the old browser, passes. `cdp_viewport_test` covers the connection handling against a fake that models the new one |
| `web_define_e2e_test.dart` | Any (needs Chrome) | A `web_defines` value in a `bootstrap_js` template reaches the running page — read off `window` over CDP, with a rendered `screenshot/native` and no service worker beside it. The dev loop must serve the build's bootstrap rather than generate one of its own, or the define works on `bazel build` and does nothing under `-d chrome` |
| `ios_simulator_e2e_test.dart` | macOS | `--screenshot` (devicectl), `--machine` screenshot |
| `machine_protocol_e2e_test.dart` | macOS | Protocol lifecycle events, unknown-method error (reload/restart correctness is manual — see "Hot reload / hot restart (manual)") |
| `attach_e2e_test.dart` | macOS | Launch app externally → attach → VM service connects; a hot reload and a hot restart driven over the machine protocol, the restart asserting a `main()`-level edit took effect (attach shares `run`'s reload pipeline, so it gets the orchestrator, asset tracking and codegen refresh). The reload case builds the app with a `--dart-define` attach is never given: the recompile keeps it only because the pipeline reads the defines off the running app. Two cases kill the app instead of driving it, on either side of the pipeline being assembled — both must end the run the same way (exit 0, naming the app as gone), because which side a death lands on is not something the user can see |
| `app_death_e2e_test.dart` | macOS + iOS sim | An app killed after the run connected and was drivable ends the run on its own, with a failure status, and the `app.stop` event carries the platform's account in `error`. macOS: `SIGKILL` to the tool's child process ("killed by signal 9"). iOS Simulator: `SIGSEGV` to the app's process ("killed by signal 11 (SIGSEGV)", read from the simulator's RunningBoard record of the end). A second iOS Simulator case closes the app with `simctl terminate` instead: the run ends with status 0 and `app.stop` carries no `error`. Seen red before the change: on macOS the run ended with status 0 and no reason, on the simulator it never ended and kept printing "still waiting". `connected_app_death_test.dart` states the property with fakes, including that a quit, a relaunch and an exit with code 0 are not deaths |
| `dart_defines_e2e_test.dart` | macOS | `--dart-define` reaches the app (comma-in-value intact) and survives a hot reload (frontend_server -D replay) |
| `dtd_e2e_test.dart` | macOS | A run is found through the Dart Tooling Daemon as the Dart MCP server finds it: `app.dtd` names a DTD that `dart tooling-daemon --list` lists and whose `ConnectedApp` service lists the app, a call to the `reloadSources` registered on the VM service it hands out recompiles an edit that `app.getText` then reads, and the DTD is gone once the run ends |
| `asset_reload_e2e_test.dart` | macOS + Chrome + iOS sim | An app and libraries that are not at the workspace root (`web_example`'s `//nested_assets:nested_app`, the library of its own package under `lib/widgets`, and `ui_kit`): an edit to `nested_assets/assets/message.txt`, one to `nested_assets/lib/widgets/banner.txt` (keyed bare, `lib/widgets/banner.txt`, as the app's own) and one to `nested_assets/ui_kit/assets/greeting.txt` each reach the page, which needs the build's `assetRoots` to say where in the workspace each key's file is (with any part of that map wrong the test fails with "no changes"). Editing `assets/message.txt` mid-run reaches the UI over an **explicit `app.hotReload`**: the tracker decides a build is warranted, the bundle is rebuilt, the changed bytes go up the devFS, and the app re-reads them without restarting. The browser case asserts both halves — the module server hands out the new bytes, and `app.getText` reads the repainted label. The iOS-simulator case is the only one that can catch a wrong assets tree: rules_apple's split transition puts the running app's tree in a config no command line can name, and on macOS both trees hold identical bytes, so watching the wrong one is invisible there. **Runs no watcher** — these launch `--machine` without `--watch`, so the watcher never starts and its accept-this-path predicate is never built. Watch-driven asset delivery has no e2e here or anywhere; that predicate's *parts* are unit-covered only (`source_watcher_test.dart` 'a custom filter widens what reaches the pipeline'; the `watches()` cases in `asset_bundle_test.dart`) |
| `widget_creation_e2e_test.dart` | macOS | The running debug app reports a creation location for a widget (`ext.flutter.inspector.getRootWidgetTree`, the call DevTools makes) at launch, after an `app.hotReload` and after an `app.restart`. The last two are what the dev tool's own frontend_server compiles, so they fail if it does not pass `--track-widget-creation` when the app was built with it |
| `launch_path_e2e_test.dart` | macOS | A run launched through a path that then vanishes (a symlink the test deletes when the tool reports `launching`) still connects to the VM service, answers `app.getText` and takes a native screenshot. That is what `./bazel-bin/.../flutter_bazel run` does every time: the run's own `-c dbg` build repoints `bazel-bin`. Without `pinProcessLocation` the connect hung (DDS reads `Platform.resolvedExecutable` per client and the read threw inside its error zone) and every bundled helper went missing |
| `main_outside_lib_e2e_test.dart` | macOS + Chrome | An app whose `main` sits outside its package's `lib/` (`e2e/macos_example :driver_app`, a `flutter_application_variant` of `:app_flutter`, and `e2e/web_example :app_test_driver`, both `test_driver/app.dart`) hot reloads an edit to that `main` and to the sibling it imports by relative path, each asserted by its exact text and by the reload answering `runningCode: updated`, then hot restarts. Before the build declared those files (`appSources` in `_dev_config.json`) the app ran and every such edit was dropped: reloads answered "no changes detected" and a restart recompiled nothing. On web a debug build of the shape was refused outright |
| `start_paused_e2e_test.dart` | macOS + Chrome | `--start-paused` really holds `main()` (asserted from the isolate's own `pauseEvent`, and on web from the framework being absent), an `app.*` command answers instead of hanging, and resuming starts the app |
| `agent_e2e_test.dart` | macOS + Chrome | Full `app.*` agent surface (tap/enterText/getText/…), and that it still works **after `app.restart`** (engine-hook registrant re-registers extensions). The Chrome case takes the other route in — the build stages the agent source and the dev tool's synthetic entrypoint registers it — and issues every command from `app.started` onward, which on web is before the VM service, the extensions or the widget tree exist |
| `press_key_e2e_test.dart` | macOS + Chrome | `app.pressKey` on both routes, each asserting the reply's `route`. **macOS** (`hello_world`, framework route): typing, Backspace, ArrowLeft and ArrowDown — which the framework leaves unhandled on macOS, so they only edit through the Cocoa selectors the extension sends as `TextInputClient.performSelectors` — and Enter firing `onSubmitted`, read back with `app.getText`; plus `Meta+A` as a shortcut the framework handles, and an unknown key refused by name. **Chrome DDC** (`web_example`, browser route): the same editing through real CDP key events, with `Control+K`, checked with `app.getText`, and a key typed with no field focused coming back with a `warning`. **Chrome `--wasm`**: the agent surface is advertised, `app.pressKey` answers `settled: yes` through the page bridge, focus reaches the field by Tab alone, and the result is read off a screenshot — the fixture draws one magenta square per submitted character, counted by `countColourRuns`. Both Chrome cases run `--web-run-headless`, because a hidden headed window draws no frames. Seen red: with the Mac editing commands turned off, the `--wasm` page submitted `abcd` (four squares) instead of `ab` |
| `reload_after_failure_e2e_test.dart` | macOS | A rejected hot reload does not wedge the resident compiler — the next reload still answers and `app.restart` recovers the session. Runs over `e2e/codegen`, which makes it the only automated check that a **source-assembled** app re-registers the engine's pre-main plugin registrant: the dev compiler feeds that registrant as a `file://` `--source` while a multi-root file system is mounted for the app's own package, and the post-restart `app.waitFor` can only be answered by extensions that registrant brought up. With the registrant suppressed, this test fails |
| `watch_reload_e2e_test.dart` | macOS | The **filesystem watcher** (`--watch`) reload path — one of three tests that deliberately run the watcher — the others are `initial_compile_recovery_e2e_test.dart` and `dev_build_recovery_e2e_test.dart`; every other reload test issues an explicit `app.hotReload`. Two guards. (1) Over `e2e/codegen`: an edit to a **dependency package's** source must key to a `package:` URI through the build-emitted `sourcePackages`, or the watcher drops the path before the pipeline sees it and nothing reloads at all — silently, which is the whole difficulty. With that URI dropped from the watcher's list, the test fails with `Saw 0 app.reloadResult event(s)`. (2) Over `e2e/hello_world`: an edit made the instant `app.started` arrives still reloads, pinning that the watcher is created before the app launches rather than inside the session loop, where the startup window swallows the edit outright. Also asserts `--machine --watch` writes no prose onto the JSON-RPC stdout stream (the `log`-callback regression). **Not** the plugin registrant, deliberately: a hot reload never re-runs the engine's pre-main registrant hook, so that path is reached only by `reload_after_failure_e2e_test.dart`'s restart |
| `initial_compile_recovery_e2e_test.dart` | macOS | A session whose **first** compile failed still reloads. Breaks `hello_world/lib/main.dart` inside the window the initial compile reads it in — on the `package_roots_stabilized` log line, after the launch build and before the compile — then fixes it and requires the watcher-driven reload to land and the app to render the fix. Also pins the reload in between as *answering* with the compiler's diagnostics, and `initial_compile_failed` as carrying `recoverable: true` (JSON mode drops the human `text`, so that field is all a machine client gets). Without the fix, the reload afterwards fails with `Initial compile failed; hot reload is unavailable.` |
| `dev_build_recovery_e2e_test.dart` | macOS | A session whose **launch-time `bazel build`** failed still reloads — one step earlier than the row above, on the wider window. The assembler builds the flutter_application (whose `DefaultInfo` carries the app kernel under `is_debug`) before it starts any compiler, so a source that does not compile fails it; between `run`'s own launch build and this one sits an entire app launch, which is the window a developer saving a typo while the app comes up actually lands in. Breaks `hello_world/lib/main.dart` on the `resolving_toolchain` log line — the last thing logged before the cquery and the build, and **not** the build's own `bazel_command` record, since an edit racing bazel's file read is a coin flip whose lost half lands in the *other* recovery path. Asserts `dev_build_failed` carrying `recoverable: true` (JSON mode drops the human `text`), that it does not name the frontend server, and that the fix reloads and renders. Every edit is derived from the pristine file and asserted to have changed something, so a no-op edit cannot pass |
| `native_libs_reload_e2e_test.dart` | macOS | Both directions of a hot reload whose **own rebuild** moved a native library. Over `e2e/codegen`, the one workspace that is source-assembled (so a reload runs `bazel build`) *and* bundles a `dlopen`ed library — through a `flutter_native_library` wrapper whose binding contract is `:native_add_ir`, one line per exported declaration extracted from the C header — *generated*, which is the shape a real binding generator has and the one that needs the app target to declare the contract as an output (see `flutter_application`). That is what makes both directions drivable from one fixture: editing `native_add.c` moves the library alone, editing a declaration in `native_add.h` moves both, and editing a comment in it moves neither. Case A (code only) asserts the reload **succeeds**, the window shows the new Dart, and `nativeLibsStale` names the library anyway — then that a restart relaunches and the reload after it is clean, which is the guard against a relaunch that failed to re-baseline and would report the library stale forever. Case B (contract too) asserts the reload is **withheld** and the window still shows case A's Dart, which is what makes `runningCode: unchanged` checkable rather than self-reported. Waits for `frontend_server_ready` before editing, because an edit inside the assembler's own build window is compiled into the baseline (see `NativeLibsWatch.of`). A second group does the same two verdicts over **Chrome**, against a `native_modules` entry on `codegen`'s web bundle (an eight-byte wasm header plus a text contract — the tool compares bytes and parses neither), and ends by asserting that a web *restart* re-baselines: the page re-runs `main()` and re-fetches the module, so the reload after it must report nothing stale |
| `native_hot_patch_e2e_test.dart` | macOS | A native edit **patched into the running app** by a hot reload, over `ffi_example`'s hand-written C `hot_patch` (`native/mul_hot_patch.c`, `tools/c_patch_tool.dart`). `ffi_example` is not source-assembled, so the only thing that can notice the edit is the patcher's content hash of the manifest's `sources`. Asserts, in one run: an edit to `native/mul.c` answers `nativePatched` and the `live 3 × 4` line shows the new value (which also pins the reassemble a reload with no Dart delta needs), the value `main` computed at launch is still on screen (no restart), a reload with nothing new says nothing native, an edit to `native/mul.h` that **adds a declaration** is withheld in the builder's own words (a moved contract with a `hot_patch` builder is asked, not refused — the dev tool never reads what about the contract moved), an edit that moves the contract *without* changing what it declares is **delivered** and the next reload over the same moved bytes is clean (the watch advances a patched library's contract with it), and undoing the edit answers `nativeReverted` and shows the launched value again. Then the same for `sub`, which reaches the app as a **code asset** (a stand-in for a bridge generator's own code-asset rule, `code_asset.bzl`) in the `code_assets` of a plain `dart_library` package's `dart_package_metadata`, called through `@Native`: an edit to `native/sub.c` is patched (`live 9 - 4`), a new declaration in `native/sub.h` is withheld in the builder's words, and undoing it reverts. That proves the `flutter_native_library` wrapper's contract and `hot_patch` reach the dev tool when the wrapper sits in a package's `code_assets` rather than in `native_deps`. Then `counter`, **one library serving two asset ids** (`package:count_a`, `package:count_b`) through one `flutter_native_library` per id that all name one `hot_patch`: it is armed once, an edit to `native/counter.c` is one patch (`nativePatched` names `libcounter.dylib` once), and taps bumping through each id show the new code running on the count from before the patch, still shared. A body that defines a `static` of its own, or an edit to `native/counter_state.h` (the layout of the state the launched image holds), is withheld in the builder's words, since either would fork state between the launched image and the patch. Waits for `native_hot_patch_armed` before editing, because the snapshot is taken at assembly |
| `relaunch_e2e_test.dart` | macOS (the same cases on the macOS app and on a booted iOS simulator), Linux (the Linux app, under Xvfb) or Windows (the Windows app, built and run on a Windows host) | `app.restart`'s **relaunch** branch: edits `ffi_example/native/mul.c` so the rebuilt dylib differs, then asserts the HTTP control channel survives the process swap and the relaunched app answers on it. The only test that reaches this branch — it needs a real native-library change. Also: an edit to a header (`native/add.h`, which `add.c` includes) that changes the library built from it relaunches into a process running the rebuilt library; a Dart-only edit keeps the process and the restart's only build is of the bundle's parts (`flutter_macos_bundle_parts`, through `flutter/macos_bundle_parts.bzl`; `flutter_ios_bundle_parts`, through `flutter/ios_bundle_parts.bzl`), never of the bundle, whose `App.framework` carries the kernel (a 10 s rebuild per edit on a loaded machine, against 0.2–0.4 s for the parts) |
| `linux_e2e_test.dart` | Linux (needs a display: Xvfb with `DISPLAY`, `LIBGL_ALWAYS_SOFTWARE=1`, `GALLIUM_DRIVER=llvmpipe`) | `e2e/desktop_example :linux_app` under the dev tool: a hot reload and then a hot restart each land in the window (read with `app.waitFor`), and the native screenshot, the dev tool's own X11 capture, returns a PNG that changes with each |
| `stop_during_build_e2e_test.dart` | macOS | Stopping a run **while its launch build is running** stops the build: `SIGTERM` and `SIGINT` to the tool's pid alone (exit `143`/`130`), `daemon.shutdown` (answered, exit `0`), and `SIGINT` to `flutter_bazel build` (exit `130`). Each forces a real build with a `--dart-define` no earlier run used and stops it on bazel's `Analyzed target` line, then asserts bazel's own `Bazel caught terminate signal`, that nothing of the command's process group is left, that `bazel --noblock_for_lock info` answers at once, and that no `command_failed` was reported. Signalling bazelisk's pid instead of its group fails it: the build runs on to `Build completed successfully` |
| `glass_plugin_e2e_test.dart` | macOS/iOS-sim/Android/Chrome | A plugin written in the workspace that ships fragment shaders (`plugin_example`'s `//glass_plugin`, run as `//glass_app:glass_<platform>`): its `shaders` draw as a `Paint.shader` and as a `BackdropFilter`, checked by the app reading its own pixels, and its Swift/Kotlin is registered. On Chrome, under skwasm (`--wasm`), CanvasKit in the dev loop and a production CanvasKit build (`--profile`), the paint shader draws and the filter is refused, as web requires. `//impeller_shader`'s shader cannot be compiled for SkSL; its app draws with it under Impeller on macOS, the iOS simulator and Android. An edit to the package shader shows after a hot reload, with no restart, on macOS and the iOS simulator |
| `android_restart_e2e_test.dart` | Android (an attached phone or emulator; `$ANDROID_SERIAL` picks one) | What an `app.restart` of `e2e/android_example` builds and when it replaces the process. A Dart-only edit restarts in the same process and the only bazel build the tool runs is of the bundle's parts (`flutter_android_bundle_parts`: the `flutter_assets` tree and native libraries, through `flutter/android_bundle_parts.bzl`), never of the launch target, which packages the APK (dex, resources, zip, sign: 24 of a restart's 46 s on an emulator). An edit to `native/add.c` relaunches: the APK is built once, for the relaunch to install, and the restart after it finds the libraries unchanged and builds no APK. So does an edit to `native/extra.c`, a `cc_library` listed on a Tier 2 `android_binary` (`:native_dep_app`) rather than on the application: the restart watches what the APK packages (each `cc_library`'s archives, the shared libraries and AAR `native_libs.zip`s below the binary, through the `flutter_android_native_libs` group), not only the application's own `native_deps`. So do an edit to the library an AAR carries (`native/aar_native.c`, packed into an AAR by `aar.bzl`) and to a checked-in prebuilt library `cc_import`ed on the binary (`native/prebuilt/libprebuilt.so`, `libprebuilt_static.a`), which are source files the group holds as they are. Waits for `frontend_server_ready` before editing, for the reason `native_libs_reload_e2e_test.dart` does |
| `plugin_example_e2e_test.dart` | macOS/iOS-sim/Android/Chrome | Plugin apps render non-blank frames; Dart plugin registration survives `app.restart` (macOS); web plugins register in both DDC and `--wasm` dev mode (Chrome) |
| `digest_pinned_e2e_test.dart` | Any | Fetches of rules_flutter's own repositories (`flutter_sky_engine_repo`, the profile, Android, iOS, desktop and cross repos, the web SDK repo with its per-host Dart SDK digests, a hosted pub package) in a generated workspace: the artifacts under test are served from a `--distdir` (a correct digest fetches from it), while the workspace's module graph still resolves from Bazel's registry or repository cache; a wrong one or one that is not a SHA-256 fails. The control for `digest_missing_e2e_test.dart` |
| `android_engine_query_e2e_test.dart` | Any | `bazel query 'deps(//...)'` in `e2e/hello_world` (including the device-signed iOS app, whose provisioning profile is the `//:device_profile` flag, so a clean clone without the git-ignored `//device` still loads) loads every package, though the workspace names the Android engine repository of no ABI in `use_repo`. `flutter_android_engine` `select()`s over one repository per ABI and a query loads every branch, so the labels have to resolve from rules_flutter's own `use_repo`. The check that the workspace leaves an ABI out keeps it from passing vacuously |
| `digest_missing_e2e_test.dart` | Any | The same repositories declared with a blank, unset or malformed digest must fail the fetch, naming the digest and the artifact, before a request is made (a fake engine revision answers 404, so a fetch that got that far did not ask). Also the web SDK repo's second archive, the Dart SDK, whose digest is looked up per host, and a hosted pub package served from `file://`, where an unpinned fetch succeeds (its files repository's `sha256`, rules_dart's `pub_archive_files`, is a mandatory attribute, so a declaration without one is refused by Bazel itself; one that is blank is refused by rules_dart's `fetch_pub_archive`). Neither digest file is a Bazel target: each case runs `bazel fetch` in a second, generated workspace, which has to resolve its module graph and so cannot sit inside a sandboxed `bazel test`. The always-run parts are `//flutter/tests:pinned_test` and `//tools/download_guard:flutter_sources_test` |
| `sdk_source_e2e_test.dart` | Any | How a Flutter SDK package is fetched from the pinned Flutter source: `flutter_pub_package` over the files `flutter_source_files` extracts from a fake release tarball served from a distdir (`digest_probe.dart`). A package in the tarball arrives with its own files at the repository root and nothing else of `packages/`, and one the release lacks (not in its `packages`, which `FLUTTER_SDK_PACKAGES` records per release) fails the fetch naming the package, the Flutter version and `bazel run @rules_flutter//flutter/pub -- get`. No network, no device |
| `pub_archive_e2e_test.dart` | Any (macOS/Linux: needs `tar` and `shasum`/`sha256sum`; the link cases skip on Windows) | How a hosted pub package's archive is fetched, through the `flutter_pub.from_lock()` hub of `pub_inputs_fixture.dart` over `file://`: a lock entry without a `sha256` is refused when the lock is read (a query of the hub fails, naming `pubspec.lock` and the package, not at a later fetch), and symbolic links in an archive that leave the package, point at nothing, or reach outside through another link are not extracted, while one that stays inside is kept and the package still loads |
| `pub_vendor_e2e_test.dart` | Any (macOS/Linux: needs `tar` and `shasum`/`sha256sum`; the link case skips on Windows) | `bazel vendor` of a hosted pub package and of a Flutter SDK package (`digest_probe.dart`'s `hostedPubPackage` and `sdkSourcePackage`, from a distdir and `file://`): each source repository's BUILD file begins with the `pub_files.bzl` load that sets up its files repository, no vendored link names the vendoring output base, and a query of each package's `srcs` in a new output base, after the vendoring one is deleted, lists its `lib/` file. Without the load the glob reads through links to a files repository nothing has set up yet and `lib/**` matches nothing. Makes and deletes two output bases of its own. No device, no network |
| `pubspec_reading_e2e_test.dart` | Any (macOS/Linux: needs `tar` and `shasum`/`sha256sum`) | How a hosted package's pubspec is read, through the `flutter_pub.from_lock()` hub of `pub_inputs_fixture.dart` over `file://`. rules_dart's `read_pubspec` reads it as pub does, so what pub refuses fails the fetch of the package's repository naming the package and saying what pub says (YAML that does not load, a `name` that is not the package's or is missing, an empty file, `dependencies` that is not a map, a numeric `environment.sdk`, a package listing itself); and the `flutter:` block is projected from the document, not its layout: assets, fonts and an Android plugin in YAML flow style arrive as the block style's do |
| `framework_pubspec_e2e_test.dart` | Any | What `package:flutter`'s repository (`flutter_framework_package`) takes from its pubspec, over a fake release tarball served from a distdir (`digest_probe.dart`, with the hub's index declared by a module extension of the probe): the language version `environment.sdk` implies (`^3.11.0-0` is `3.11`, none is pub's `2.7`), the library's deps being the runtime dependencies the lock lists and no `dev_dependencies` (the Flutter pubspec verbatim, comments inside the dependency block and nested `sdk: flutter` entries included), and a missing pubspec, a `name` that is not `flutter`, or YAML that does not load failing the fetch naming the package |
| `pub_inputs_e2e_test.dart`, `pub_inputs_properties_e2e_test.dart` | Any (macOS/Linux: needs `tar` and `shasum`/`sha256sum`) | What `flutter_pub.from_lock()` does with the inputs a lock and its packages hand it, in a generated workspace over `file://` packages (`pub_inputs_fixture.dart`, `generatedWorkspace` in `editable_workspace.dart`); no network, no device. The first file pins what works: legal odd file names, overlays at every rung of the version ladder and their edits, either Gradle dialect, `sdk: flutter` entries of any name in the hub. The second states the properties a pub input rules_flutter cannot honour must hold: a file name that cannot be a Bazel label, or an Android namespace that is not a Java package name, is refused at fetch naming the package, or built with the value kept as a string (never run as Starlark); an asset or a shader with `transformers` is refused at fetch naming the package; a lock entry it has no repository for (an unknown `source:`) leaves the hub loading, and its target fails at analysis naming the package when something depends on it; an overlay added after the first build, or beside a less specific one, is used by the next; a dependency in an `apply from:` script is read or reported, and the dependencies come from the build file Gradle uses; `bazel run @rules_flutter//flutter/pub -- get` writes nothing into the HOME it runs under (a canary directory, with the cache elsewhere) |
| `pub_commit_pinned_e2e_test.dart` | Any (needs `git`, `tar`, `shasum`/`sha256sum`) | A lock's `source: git` packages (`GitPackage` in `pub_inputs_fixture.dart` makes the repositories on the spot, so no network): the spoke is the locked commit's tree at its root, the whole repository or a `path:` directory of a monorepo, without later commits or the rest of the repository; a plain package is a plain library, a plugin a plugin, and one with assets bundles them; a hosted package depending on one reaches its library; a `resolved-ref` that is not a full commit id is refused when the lock is read, a commit the repository lacks or a `path:` that is no directory of it at the fetch, each naming the package; a git entry mapped by `resolve` is never fetched |
| `pub_versions_e2e_test.dart` | Any (macOS/Linux: needs `tar` and `shasum`/`sha256sum`) | Several `flutter_pub.from_lock()` locks sharing one repository per package (`PubInputsFixture.otherHubs`): two hubs reach one `flutter_pub_lib__<package>`; the highest version any lock records is built, whichever module's lock it is (`PubInputsFixture.modules`), silently when it raises only another module's lock, with a warning naming both locks, versions and `pub -- upgrade` when it raises one of the root's, nothing at `flutter_pub.settings(check_direct_dependencies = "off")`, and failing at `"error"`; that exact command, run while the failure stands against a registry served over HTTP, moves the lock forward and the hub then analyses; hosted vs git, two registries and one version with two digests fail naming both, at any level; a dependency module's `ignore_hooks` fails; `resolve` maps a package for every hub and two different maps fail; two tags of one name are one hub. No network, no device |
| `pub_resolve_e2e_test.dart` | Any (macOS/Linux: needs `tar` and `shasum`/`sha256sum`) | A lock's packages built from the workspace targets `flutter_pub.from_lock(resolve = {...})` maps, in the generated monorepo workspace of `pub_inputs_fixture.dart` (the lock at `apps/app/pubspec.lock`). A map that does not fit the lock is refused when the lock is read, naming the lock and the package (a path package mapped to nothing, a mapped name the lock lacks, a path package's absolute path, path out of the repository, label in another repository or another Bazel package than the path names); what needs a path package's files is refused when the hub's label is fetched (no `pubspec.yaml`, another name, a dependency the lock lacks; another version is accepted), and editing the pubspec re-runs the check. The hub, and a hosted package that depends on the mapped one, reach the workspace target; it is one configured target however it is reached; a cycle through a hosted package is Bazel's cycle error. A hosted package mapped to a target replaces it for the whole graph and is never fetched (its lock entry names an archive that does not exist), and a target that declares another package name than its key fails analysis naming both |
| `pub_path_package_e2e_test.dart` | Any (macOS/Linux: needs `tar` and `shasum`/`sha256sum`) | A lock's `path` packages that no Bazel target builds, in the generated workspace of `pub_inputs_fixture.dart`. A package named in `build_from_pubspec` is its directory, in the repository or outside it, and a library that depends on the hub's label builds; a file added to its `lib/` is built by the next build, while tool output written into it (`build/`, `.dart_tool/`, `android/.gradle/`, `android/build/`) neither enters its repository nor fetches it again; a directory holding a `BUILD.bazel`, or no directory, is refused at the fetch saying what to do. A package named in `ignored` leaves the hub loading, and a library that depends on it fails analysis with the module's reason |
| `pub_cycle_e2e_test.dart` | Any (macOS/Linux: needs `tar` and `shasum`/`sha256sum`) | Packages that depend on each other, which pub allows and Bazel does not, in the generated `flutter_pub.from_lock()` workspace of `pub_inputs_fixture.dart` over `file://` packages, plus the real `dio` 5.11.1 and `dio_web_adapter` 2.2.2 lock. Whichever package of a cycle an app depends on, every package of it is in the build at the locked version, each keeps its own assets (under `packages/<name>/`), its plugin registers once and its own Android library; a cycle mixes pure-Dart packages and packages with assets, one asking for the Material icon font gets it, and a package built from a plugin overlay cannot be in a cycle (the build says so). The fixture's cycles are declared with `flutter_pub.cycle()`; `dio`'s builds with no declaration, through rules_dart's curated one. An undeclared cycle fails naming it and the declaration to add, a root declaration of part of a cycle or of packages in no cycle fails, and one naming a package the build does not build fails when the module is read. The checks are analysis-time assertions over the providers a target carries |

### Dev tool screenshot mechanisms

| Device | Debug mode | Profile and release |
|--------|------------------------|---------------------------------|
| macOS | bundled ScreenCaptureKit helper (always) | same |
| Linux | the tool's own X11 `GetImage` of the display (always) | same |
| Windows | bundled `dxcam` DXGI helper (always) | same |
| Android (physical) | `adb screencap` (always) | `adb screencap` |
| Android (emulator) | `adb emu screenrecord screenshot` (always) | same |
| iOS Simulator | `devicectl device capture screenshot` (always; needs Xcode 27) | `devicectl device capture screenshot` (always; needs Xcode 27) |
| iOS device | `devicectl device capture screenshot` (always; Xcode 27+) | same |
| Chrome/Web | CDP `Page.captureScreenshot` (always) | N/A (web is always debug) |

Note: `_flutter.screenshot` captures only the Flutter widget tree (no OS chrome); the platform tools capture the full screen or window. The three desktop rows name the helper each device's `captureScreen` actually resolves out of runfiles (`tools/{macos,windows}_screenshot/screenshot`, and the in-process X11 capture on Linux). Windows must use DXGI, not GDI, which captures a Flutter surface as black (§ 4).

Every cell says "always": at the pinned Flutter, **no** device can do `_flutter.screenshot`. Impeller cannot encode a compressed screenshot, and there is no engine screenshot on web at all. They all declare `supportsFlutterScreenshot => false`, so the control channel's `screenshot/flutter` endpoint answers `501` naming `screenshot/native` instead of passing back an engine error that reads as transient.

**Android** answers the RPC with `(-32000) Could not capture image screenshot`. **The three desktop platforms** refuse it since the Flutter 3.47.2 engine, where each embedder's Impeller default flipped on — macOS `FlutterDartProject.enableImpeller` `NO` → `YES`, Linux `FlDartProject.enable_impeller` introduced as `TRUE`, Windows `FlutterWindowsEngine` resolving its `Default` switch to enabled. macOS is measured (`macos_e2e_test.dart` asserts the refusal directly); Linux and Windows are read from those embedder sources, not from a run.

### Stopping a run: signals release what it holds

`SIGTERM` and `SIGINT` (Ctrl-C) run the same shutdown `daemon.shutdown` does —
the app stops, the browser and its temp profile go, the resident compiler
closes, a bazel command still running is stopped — and the tool then exits
`143` or `130`. Signal a second time to exit at once without waiting for the
rest.

**A bazel command the tool started stops with it.** A `bazel` on `PATH` is
usually bazelisk, which ignores SIGINT and SIGTERM sent to its own pid and
counts on a terminal signalling the whole process group. Measured before this
was handled: a signal to the tool alone ended it in milliseconds, and its build
ran on to completion, holding the output base's lock against the next command.
So every bazel command starts in a process group of its own
(`//tools/dev_tool:process_group_exec`), and shutdown sends that group SIGTERM
— not SIGINT, which the Bazel client counts and answers on the third by killing
the server — then waits for bazel to exit and for its last lines to be read.
The Bazel server is never touched. `flutter_bazel build` stops its build the
same way. Two launches cannot interrupt a command and say so if a stop has to
wait on one: Windows, and the tool run from source with `dart run`, which has
none of the helpers Bazel bundles. `stop_during_build_e2e_test.dart` is the
guard.

A leaked profile is not merely wasted bytes — see the `ChromeSession` docs on
why an orphaned browser can serve a screenshot that makes a broken run look
fine.

**A profile survives only a run that could not clean up.** Every ending the
tool sees deletes the browser's `flutter_chrome_*` profile in the system temp
folder, and Chrome's own `com.google.Chrome.*` socket directory beside it: a
normal stop, `daemon.shutdown`, a signal, a failed or stopped launch, Chrome
exiting or crashing, an uncaught error (the browser is killed and the profile
removed on the way out). A second signal exits at once, and kills the browser
first. A `SIGKILL` of the tool (a harness that gave up waiting, the
out-of-memory killer) cannot be intercepted, so the **next** web launch removes
what it left: a profile holds an exclusive lock on its `.dev_tool_owner` file
while its run lives, the operating system drops that lock however the run
ends, and a profile whose lock can be taken and whose browser (the pid in
Chrome's `SingletonLock`) is not running is deleted. A profile whose browser
is still running is kept and reported, since deleting it would pull the
profile from under a live browser; quit that browser and the next launch
removes the profile. A profile with no `.dev_tool_owner` file — made by an
older tool, or not the tool's — is never touched, and nothing is reaped on
Windows, where Chrome records no pid.

**A run also has to be able to end without a signal.** An uncancelled
`ProcessSignal.watch()` keeps the Dart VM alive after `main` returns, so
`daemon.shutdown` can answer, release everything, and leave the process sitting
there. Two guards assert the exit directly — `web_e2e_test.dart` and
`attach_e2e_test.dart`, both "daemon.shutdown ends the process, not just the
app" — and neither runs in CI, so the harness makes **every** e2e test a
lifetime guard as well: `DevToolProcess.dispose` sends `daemon.shutdown`, and a
tool still running 20s later fails the test instead of being killed quietly.

### Capturing a web app at a phone viewport

`--web-viewport WIDTHxHEIGHT[@scale]` lays the app out at a viewport of its
own, whatever size the browser window is — `--web-viewport 393x660@3` gives a
1179x1980 capture, and `--web-viewport 393x660` a 393x660 one. That is what a responsive-layout
sweep needs, and the browser window cannot supply it: `--window-size=393,660`
is accepted and then clamped by new-headless Chrome to about 500 CSS px wide,
with the simulated window chrome coming off the height.

The size is applied over CDP (`Emulation.setDeviceMetricsOverride`) once the
page is up, and the run fails if the page does not come back reporting it. The
connection that applied it stays open for the whole run: Chrome 154 ties the
override to the CDP session that set it and puts the page back at the window's
own size when that socket closes, so a tool that applied it and hung up still
launched cleanly and then captured at 2400x1713. If the connection is lost
mid-run the tool logs `web_viewport_lost`; `app.setViewport` sets it again. The
override is not a mobile emulation, so the page is laid out at exactly the
size asked for before its own code has run.

`app.setViewport` changes it again mid-session — `{"method":"app.setViewport",
"params":{"appId":"…","width":393,"height":660}}` — so a sweep across form
factors is one run driven through several sizes rather than one run per size.

The command exists **only on a web run**; a native session answers `Unknown
command: app.setViewport`, because a desktop window is a real window and there
is no view-metrics override on the VM service to emulate one. It takes a width
and a height and refuses a scale, which cannot be changed on a running browser
at all — the ratio comes from `--force-device-scale-factor`, fixed when Chrome
starts. A different scale is a new run with `--web-viewport WxH@scale`. The
`@scale` half goes on Chrome's command line as `--force-device-scale-factor`
instead, because capture resolution follows the switch and not the override —
an override carrying `deviceScaleFactor: 3` alone still captures at 1x. Passing
`--web-browser-flag=--force-device-scale-factor` beside a `@scale` is refused
for the usual reason: Chrome resolves a duplicated switch by position.

### Why an emulator is captured through its console

`adb screencap` on an emulator does not fail on a Flutter app — it succeeds and
returns a **fully transparent** PNG — `mean=0, alpha=0`, identically through
`screenshot/native` and through a raw `adb exec-out screencap -p`. `adb emu screenrecord screenshot
<dir>` captures the emulator's own framebuffer on the host and gets the real
image.

Whether the blank covers the whole screen or only the Flutter surface varies by
AVD and GPU mode. Either way, on an emulator `screencap` can return a fully
transparent frame while reporting success, and the console capture returns the
real image in both GPU modes — which is why the choice is made by device kind
and not by inspecting the result.

Two consequences worth knowing before reading a capture:

* **`adb emu` says `OK` and exits 0 even when it wrote nothing** — for instance
  into a directory that does not exist. The dev tool therefore captures into
  a directory it creates for that one call and requires exactly one PNG to have
  appeared; that file is the only evidence a capture happened.
* **Rotate with `adb -s <serial> emu rotate`, not `settings put system
  user_rotation`.** The console captures the emulator *window*, so it is
  faithful to what the window shows. `emu rotate` turns the window and the
  guest display together and gives an upright landscape capture.
  `user_rotation` turns only the guest — the window
  stays portrait with the UI lying on its side, and that is genuinely what the
  screen then looks like, so the capture is correct and no rotation belongs in
  the tool.

An app that turns Impeller off could still serve the RPC, and this declaration gives up on it deliberately — the renderer is a runtime property of the app, nothing here can tell the two apart without asking it, and the native endpoint captures both.

## 3. E2E workspaces (automated)

Run `bazel test //...` in each workspace. All non-manual tests run automatically.

```sh
cd e2e/smoke && bazel test //...
bazel run //tools/consumer_archive                            # extract the release archive for the next line
cd e2e/external_module && bazel query "@rules_flutter//..."   # a consumer lists the whole module (CI: consumer-query)
cd e2e/external_module && bazel build --nobuild "@rules_flutter//..."   # and analyses all of it
bazel run @overhead//preset -- --check                       # the generated .bazelrc preset is current
cd e2e/dual_hub && bazel test //...
cd e2e/hello_world && bazel test //...
cd e2e/hello_world && bazel coverage --combined_report=lcov //coverage/... \
  && bazel run //coverage/check -- "$(bazel info output_path)/_coverage/_coverage_report.dat" coverage/lib/shapes.dart coverage/units/lib/units.dart
cd e2e/hello_world && bazel coverage --combined_report=lcov --instrumentation_filter=//coverage/units //coverage/... \
  && bazel run //coverage/check -- "$(bazel info output_path)/_coverage/_coverage_report.dat" coverage/units/lib/units.dart
cd e2e/codegen && bazel test //...
cd e2e/ffi_example && bazel test //...
cd e2e/plugin_example && bazel test //...
cd e2e/plugin_example && bazel test //... --config=deep  # before a merge: the live Gradle metadata check, the Gradle-built host app
cd e2e/macos_example && bazel test //...
cd e2e/integration_test && bazel test //...  # macOS: needs an unlocked, awake desktop; Windows: `build //...`, its tests run on the VM (below)
cd e2e/ios_example && bazel test //...
cd e2e/multi_window_example && bazel test //...
cd e2e/android_example && bazel test //...
cd e2e/web_example && bazel test //...
cd e2e/pub_resolve && bazel test //...  # macOS, Linux (:render_test)
cd e2e/desktop_example && bazel test //...  # Linux and Windows targets, each target_compatible_with its own OS: on macOS nothing runs
cd e2e/package_assets && bazel test //...   # the link hook tests on any host; the macOS app's tests on macOS only (target_compatible_with)
```

**Platform notes:**
- macOS-only targets (macos bundle tests, ios_example) are skipped on other platforms via `target_compatible_with`.
- Linux-only targets (linux bundle tests, `desktop_example`'s Linux section) are skipped on macOS/Windows.
- Windows-only targets (`desktop_example`'s Windows section) are skipped on macOS/Linux.
- The Android workspaces download their Android SDK and NDK (§ "The Android SDK and NDK are downloaded"); none needs `ANDROID_HOME` or `ANDROID_NDK_HOME`.
- A plugin's or AAR's `<uses-permission>` (e.g. `record_android`'s RECORD_AUDIO) reaches the APK without `--merge_android_manifest_permissions`: `flutter_android_app` lifts library permissions into the app's manifest itself, and no e2e workspace sets the flag, so the suite shows it is not needed. `plugin_example`'s `verify_android_apk_test` and `glass_app:verify_glass_apk_test` check it.
- `flutter_android_app` merges `android/app/src/debug/AndroidManifest.xml` (where `flutter create` declares `android.permission.INTERNET`) into `-c dbg` APKs only, mirroring Gradle's variant merge. Debug APKs therefore host the Dart VM service out of the box; release APKs stay permission-free. `plugin_example`'s and `hello_world`'s flutter-create manifests are kept pristine to cover this path; `android_example` declares INTERNET in its hand-written `src/main` manifest and has no variant manifests, covering the no-op path. `verify_android_apk_test` in `plugin_example` is mode-aware: it asserts INTERNET present + `kernel_blob.bin` under `-c dbg`, and INTERNET absent + `libapp.so` in default (release) builds.
- An Android APK is built for the platforms of `--@rules_android//flags:android_platforms`, one build of each dependency per platform: the e2e workspaces that build one set `--@rules_android//flags:android_platforms` to arm64-v8a in their `.bazelrc`, and a test of another ABI, or of several at once, builds through `flutter_android_build`. Packaging hard-fails on any non-ELF native library. `verify_android_apk_test` in `e2e/android_example` asserts every packaged `.so` is ELF with the ABI's machine type, and that every androidx class the engine needs at runtime (including the profileinstaller → concurrent-futures → listenablefuture chain) is defined in the APK's dex — so a missing runtime dep fails in CI without an emulator.
- If Xcode beta causes `local_config_xcode` errors, add `--repo_env=DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **After an Xcode upgrade**, a workspace that has not built since can fail with
  `Running '…/xcode-locator <old version>' failed with code 1 … indicates that
  Xcode version <old> is not available` while `xcode-locator`'s own output in the
  same message lists the new one. Each workspace caches its own
  `local_config_xcode`, so this hits whichever ones are stale and not the rest.
  `bazel fetch --configure` refreshes `apple_support`'s copy but not
  `bazel_tools`'s, which is the one in the error; invalidate that repo (never
  `bazel clean`) and rebuild:
  ```sh
  ob=$(bazel info output_base)
  rm -rf "$ob/external/bazel_tools+xcode_configure_extension+local_config_xcode" \
         "$ob/external/@bazel_tools+xcode_configure_extension+local_config_xcode.marker"
  ```
  `bazel fetch --force --repo=@@bazel_tools+xcode_configure_extension+local_config_xcode`
  does the same in one command.
- **rules_swift's SDK scan outlives an Xcode upgrade too.** A workspace that
  scanned the old Xcode fails analysis with `no such package
  '@@rules_swift++system_sdk+system_sdk_xcode_<old version>//': xcode-locator
  failed`, or with `configurable attribute "actual" in
  @@rules_swift++system_sdk+system_sdk//:all_modules doesn't match this
  configuration`. The `system_sdk` extension declares itself reproducible, so
  Bazel keeps its result in the output base's own `MODULE.bazel.lock`, not the
  checked-in one, and neither a server restart nor `fetch --force` reruns the
  scan. With the server stopped, delete that one entry and refresh
  `local_config_xcode` as above:
  ```sh
  ob=$(bazel info output_base) && bazel shutdown
  python3 -c "import json,sys; p=sys.argv[1]; d=json.load(open(p)); \
  d['moduleExtensions'].pop('@@rules_swift+//swift:extensions.bzl%system_sdk', None); \
  json.dump(d, open(p, 'w'), indent=2)" "$ob/MODULE.bazel.lock"
  ```
- **After a Dart SDK upgrade**, `dart run` inside a workspace whose packages
  have native-asset build hooks fails outright:
  ```
  Can't load Kernel binary: Invalid kernel binary format version (expected 130, found 127).
    Building assets for package:objective_c failed.
  Running build hooks...Error: Running build hooks failed.
  ```
  The hook is compiled once to
  `<workspace>/.dart_tool/hooks_runner/<pkg>/<hash>/hook.dill` and that cache is
  not keyed by SDK version, so the newer VM is handed the older kernel. Only
  `e2e/plugin_example` has such a package today (`objective_c`, via the darwin
  plugins). Delete the cache — it is gitignored and regenerated:
  ```sh
  rm -rf e2e/plugin_example/.dart_tool/hooks_runner
  ```
  A `dart run` launch with `workingDirectory` set to an e2e workspace makes the
  SDK build *that workspace's* hooks before the tool's `main` runs at all, so
  the process dies before `daemon.connected`. The hook's actual error is in
  `<workspace>/.dart_tool/hooks_runner/<pkg>/<hash>/stderr.txt`.
- `cross_compile_example` has **no test targets**, so it is verified with
  `bazel build //...`, not `bazel test`. Its `.bazelrc` pins
  `--platforms=linux_x64` for every command, and a test there would find no test
  toolchain on a macOS host. The analysis and format checks are an aspect, not
  tests, and that workspace enables it under `build`, so one command covers the
  cross-compiled bundle and the checks:
  ```sh
  cd e2e/cross_compile_example
  bazel build //...
  ```
  `bazel test //...` there exits 4 ("No test targets were found") however clean
  the checks are.

### `e2e/integration_test`

The integration test rules (`flutter/integration_test.bzl`) on a real app, in the
host's own desktop session (macOS or Windows), on an X server of the test's own
(Linux), in a browser, on an Android device and on an iOS simulator. Its Windows
tests are run on a Windows host, by hand or on the GCP VM (§ "Windows integration
tests (GCP VM)"); on a Mac or Linux host they are skipped. Its Linux tests need no
desktop: on a Linux host they run as they are, and on the GCP VM of § "Linux
integration tests (GCP VM)". Its macOS tests
launch a window, so run it on a Mac with an unlocked screen and an awake display
(§ "macOS permission prerequisites", "The display must be awake"); the runner holds
the display awake itself and fails, saying which, when the screen is locked or the
display asleep. The Android tests boot an emulator each (below), which needs the
host's hypervisor and nothing attached; the iOS ones need Xcode with an iOS
runtime installed. `bazel test //...` there runs:

| Target | Property |
|---|---|
| `:macos_pass_test` | a two-test suite that taps a counter and reads its text passes, each test reported (Bazel lists each case from the JUnit file) |
| `:macos_red_twin_test` | a failing integration test fails its target, and the JUnit report names the failing case with a `<failure>`. It wraps `:macos_red` (`manual`, since it is meant to fail) in `outcome_test`, which runs the wrapped test's own executable and passes only when it ends as the target says |
| `:macos_crash_test` | an app that `exit(3)`s mid-test fails its target, and the output says `exited with code 3` |
| `:macos_filter_test` | `--test_filter` runs one of the two cases of `:macos_pass_test` and no other |
| `:macos_flavor_test`, `:macos_no_flavor_test`, `:web_flavor_test`, `:web_no_flavor_test` | `appFlavor` is `paid` in a test run as an application with `flavor = "paid"` (on every platform, through the variant that inherits it from `:app_flutter_paid`), and null in one without |
| `:windows_pass_test` | the same two tests in a Windows app's window, each reported: the suite is driven through the app's VM service |
| `:windows_red_twin_test` | a failing integration test fails its target on Windows, and the JUnit report names the failing case. It wraps `:windows_red` (`manual`) in `outcome_test` |
| `:windows_crash_test` | an app that `exit(3)`s mid-test fails its target, and the output says `The Windows app exited with code 3` |
| `:windows_filter_test` | `--test_filter` runs one of the two cases of `:windows_pass_test` and no other |
| `:windows_golden_test`, `:windows_golden_mismatch_twin_test` | `matchesGoldenFile` compares with `goldens/windows/swatch.png` and passes; a golden that does not match fails, naming the file, and leaves the four pictures of the failure in the undeclared outputs, as on the other platforms |
| `:linux_pass_test` | the same two tests in a Linux app's window on an X server the test started, with the pinned Linux runtime's GTK, Mesa and fonts, each reported |
| `:linux_red_twin_test` | a failing integration test fails its target on Linux, and the JUnit report names the failing case. It wraps `:linux_red` (`manual`) in `outcome_test` |
| `:linux_crash_test` | an app that `exit(3)`s mid-test fails its target, and the output says `The Linux app exited with code 3` |
| `:linux_filter_test` | `--test_filter` runs one of the two cases of `:linux_pass_test` and no other |
| `:linux_golden_test`, `:linux_golden_mismatch_twin_test` | `matchesGoldenFile` compares with `goldens/linux/swatch.png` and passes; a golden that does not match fails, naming the file, and leaves the four pictures of the failure in the undeclared outputs |
| `:web_pass_test` | the same two tests in headless Chrome (a pinned Chrome for Testing shell), each reported: the suite is driven over the browser's DevTools protocol |
| `:web_red_twin_test` | a failing integration test fails its target in a browser too, and the JUnit report names the failing case. It wraps `:web_red` (`manual`) in `outcome_test` |
| `:web_filter_test` | `--test_filter` runs one of the two cases of `:web_pass_test` and no other |
| `:android_pass_test` | the same two tests on an Android emulator the test boots for itself (the pinned emulator and image of the host, the app built for the image's ABI), each reported: the suite is driven through the VM service `adb forward`ed from the device |
| `:android_red_twin_test` | a failing integration test fails its target on an emulator, and the JUnit report names the failing case. It wraps `:android_red` (`manual`) in `outcome_test` |
| `:android_filter_test` | `--test_filter` runs one of the two cases of `:android_pass_test` and no other |
| `:ios_pass_test` | the same two tests on an iOS simulator the test makes for itself, each reported |
| `:ios_filter_test` | `--test_filter` runs one of the two cases of `:ios_pass_test` and no other, and `xcrun simctl list` shows no `rules_flutter-*` simulator of that test afterwards (`outcome_test`'s `leaves_no_simulator`) |
| `:ios_red_twin_test` | a failing integration test fails its target on a simulator, the JUnit report names the failing case, and the simulator is deleted though the test failed. It wraps `:ios_red` (`manual`) |
| `:macos_golden_test`, `:web_golden_test`, `:android_golden_test`, `:ios_golden_test` | `matchesGoldenFile` in an integration test compares with the golden committed for the platform (`integration_test/goldens/<platform>/swatch.png`) and passes: the app sends the picture to the host runner, which compares it with the comparator every `flutter_test` here uses |
| `:web_golden_mid_frame_test` | a golden taken in a browser while the engine is still drawing the frames before it is the widget's own 64×64 picture, not the whole page: a slow picture holds the frames up so the last waits behind the other when `matchesGoldenFile` captures |
| `:web_golden_live_frames_test` | the same while the app draws frames no `pump` asked for (the `fullyLive` frame policy, behind the swatch a background slow to draw): no frame is drawn while `matchesGoldenFile` captures |
| `:macos_golden_mismatch_twin_test` and the `web_`, `android_` and `ios_` ones | a golden that does not match fails its target, the failure names the golden file (`Golden "goldens/<platform>/swatch.png": Pixel test failed, 100.00%, 4096px diff detected.`), and the four pictures of the failure are left in the test's undeclared outputs (`bazel-testlogs/<target>/test.outputs/failures/swatch_*.png`), where `flutter_test` leaves them. They wrap `:<platform>_golden_mismatch` (`manual`: the same swatch in another colour against the same golden) in `outcome_test`, whose `undeclared_outputs` checks the pictures |

The golden tests draw a flat, text-free square at a fixed logical size, so the
picture depends on no font and no window size; the goldens are still one per
platform (the test names the directory from `defaultTargetPlatform`, `web` for a
browser), because a golden is a function of the platform that rendered it, and
the day the swatch has text it will differ between them. They are regenerated
with `bazel run //:<platform>_golden_test -- --update-goldens`, which launches the
app as the test does and writes the golden into the source tree, naming the file
(`integration_test: wrote golden <path>`); under `bazel test` the flag is refused
(exit 64) like `flutter_test`'s. The comparison is made on the host by a
`flutter_tester` the runner starts when the first golden is asked for (the runner
has no `dart:ui`), so an app on a phone or in a browser compares exactly as one on
the desktop does. The update round trip, run for macOS: `bazel run
//:macos_golden_mismatch -- --update-goldens` rewrites `goldens/macOS/swatch.png`
as the orange swatch (the file's `shasum` changes), `bazel test
//:macos_golden_test` then fails with the pixel diff, and `bazel run
//:macos_golden_test -- --update-goldens` writes the blue one back, byte for byte
what is committed (`git status` shows nothing) and `bazel test
//:macos_golden_test` passes.

The web tests run in a headless browser and need no desktop session. macOS and Linux run them; on Linux the browser loads the pinned Linux runtime's libraries and runs without its sandbox. Windows skips them: they are not verified there.

The Android tests each boot an emulator of their own (the pinned emulator and
AOSP test image of the host: arm64-v8a on an Apple-silicon Mac, x86_64 on Linux
with KVM), from a cold start in 15 to 30 s, on a pair of the emulator ports
5554 to 5585 under a lock, with an `adb` server of the test's own that sees no USB
device: an attached phone is neither needed nor touched. The emulator is shut
down and its `adb` server stopped however the test ends; `pgrep -fl qemu-system`
shows none afterwards. Its output and the device's log are in
`bazel-testlogs/<test>/test.outputs/` (`emulator.log`, `logcat.txt`). Run them
once more on the phone after a change to the Android runner, which builds the
app for arm64-v8a and installs it on the attached device (left installed, as
`flutter test` leaves it: `adb uninstall com.example.integration_test_example`
after):

    bazel test //:android_pass_test //:android_filter_test //:android_red_twin_test \
        --@rules_flutter//flutter/integration_test:android_device=attached \
        --test_env=ANDROID_SERIAL=<serial>

Their app links `integration_test`'s Android library, so this workspace's
`rules_flutter_maven` install pins `androidx.test:runner`, `:rules`,
`espresso-core` and `guava` (the plugin's own build asks for `1.2+`, `1.2+`,
`3.3+` and `28.1-android`).

The iOS tests need nothing booted or attached: each makes a simulator
(`rules_flutter-<test>-<pid>-<start>`, an iPhone 16 on the newest iOS runtime;
`<pid>` and `<start>` are the runner's process id and start time in epoch seconds),
runs on it and deletes it, whether the test passed, failed or was killed by Bazel's
timeout (SIGTERM). A SIGKILL leaves one behind, which the next iOS test run deletes
(and logs: `deleting the simulator ... its run (process N) is gone`) because no
process N started at `<start>` is running; a simulator of a run that is still alive
is never touched. A simulator is
scheduled as two cores (`cpus` of `flutter_ios_simulator_runner`): the processes
under a booted simulator measured 15 CPU-seconds over the 20 seconds a test took
(0.75 of a core), not counting the host services it talks to.

The macOS tests take turns on the screen through the `macos-gui` lock
(`/tmp/rules_flutter-locks/`), so several at once is fine: a test that has to wait
says `waiting for macos-gui, held by another test`; two on one Android device take
turns on `android-<serial>` the same way. The Windows tests take no lock, which was
measured: two tests' windows at one origin (`windows_hold_a` and `windows_hold_b`,
each tapping once a second for forty seconds and awaiting a frame after each tap)
both finished all forty, so a window another covers keeps drawing, unlike macOS's.
They also ran from the VM's SSH logon, which has no visible desktop, as well as from
its console session, so the interactive session is for the screenshot, not for the
test (a host with no display adapter was not tried). CI builds this workspace, Android
apps included, and does not run it (it never runs a test that needs a GUI session or a
device).

Changing the integration test rules (`flutter/integration_test.bzl`,
`flutter/private/flutter_integration_*.bzl`, the support library in
`flutter/private/integration_test/support/`) or the runner
(`tools/dev_tool/lib/integration/`, `bin/integration_test_runner.dart`) takes this
workspace's `//...` on the platform it touches, and the platform's row below.

### Test code the e2e workspaces share

Each workspace is its own Bazel project, so a test in one cannot import a file
from another by relative path. There are three ways to avoid a copy, and a
fourth thing to do when none applies.

- **Checks and parsers that tests run on a built artifact** live in
  `//tools/e2e_testing`, a `dart_library` in the root module
  (`package:rules_flutter_e2e_testing`): the OK/FAIL log, finding a bundle in
  the runfiles, unpacking an `.app`/`.ipa`/`.apk`, the Linux and Windows bundle
  layouts, launching an app and waiting for its marker file. A workspace reaches
  it through the `local_path_override` for `rules_flutter` it already has: its
  `dart_test` lists `deps = ["@rules_flutter//tools/e2e_testing"]` and imports
  the package. Its own unit tests run in the root `bazel test //...`. It is
  excluded from the release archive. Put new shared test code there, not into a
  second copy.
- **Starlark** the workspaces share is a `.bzl` in the same package
  (`@rules_flutter//tools/e2e_testing:signing_twin.bzl`, which the iOS and macOS
  examples use to declare an extension signed two ways).
- **Standalone scripts** run by hand on a bare machine are under `e2e/_*_test/`
  (§ 6). They stay self-contained: `tools/vm` copies only that directory to a VM.
- **A file a workspace must hold itself**, because a test reads or edits it as
  the workspace's own (the `test_driver/` entrypoint the dev tool reloads in a
  copy of the workspace, native sources the dev loop watches by workspace path,
  patches Bazel applies to a module): each workspace keeps its copy, and
  `//tools/e2e_copy_guard:copies_identical_test` fails when copies differ. A new
  patch is covered by its name; any other file goes into
  `tools/e2e_copy_guard/mirrored.bzl`. `.bazelversion` is checked against the
  root's automatically, for every workspace.

### What CI covers

`.github/workflows/ci.yaml` runs, on every push and pull request:

- `bazel test //...` in the repository root (Linux);
- `bazel run @overhead//locks:check` (on macOS for the workspaces with Apple
  targets, on Linux for the rest), which fails on a stale or incomplete
  `MODULE.bazel.lock` in any workspace, see "Lock files" in § 1;
- the pre-commit hooks, the dev_tool unit tests, and the web smoke test (§ 5);
- `bazel test //...` in every e2e workspace (`build //...` where it has no test
  targets, or its tests need a desktop session or a device), on each operating
  system where it exercises something no other job does. A system can have its
  own command and tests in the table: `integration_test` builds on macOS and
  Windows, and on Linux tests the `:linux_*` and `:web_*` targets, which need
  no desktop. The table names the prefixes (`testsNamed`), not the targets: the
  plan reads every `<prefix>...test` target from the workspace's `BUILD.bazel`,
  so a new `web_*_test` runs in CI without a table edit, and a prefix that
  matches nothing fails the plan.

The last is a matrix of one job per workspace and system, named `E2E
(<workspace>, <runner>)`. It is generated: the `Plan E2E jobs` job runs
`tools/ci_matrix/e2e_matrix.dart`, and that table is the one place that says
where a workspace runs and why. A job costs runner time (a macOS minute costs
ten Linux ones), so it has to earn it. A workspace runs on a system only where it
exercises something there that nothing else in CI does, and its entry says what:
an OS-specific path (a runner, a toolchain, a bundle layout, a plugin's
implementation for that platform, how the host loads a native library), or, for
a workspace whose subject does not depend on the OS, its one run, on the cheapest
system that builds it. Every other system gets a reason: the job that covers it,
or that the system cannot build it. Building on a system is not a reason to run
there.

The run fails when the table and `e2e/` disagree, when a run gives no purpose,
or when one workspace gives two systems the same purpose. So a workspace added
without a decision (or removed without its entry) turns CI red rather than
quietly never running. A target pattern the table names that is in no target of the workspace's BUILD
file fails it too. A new workspace needs an entry; `bazel run //tools/ci_matrix`
finds a gap before a push.

| Workspace | Runs on | What each run adds | Not on |
|---|---|---|---|
| `smoke` | macOS, Linux, Windows | the BCR presubmit module, which BCR runs on each | |
| `hello_world` | macOS, Linux, Windows | the Tier-1 app over each `flutter create` runner; profile bundles on Linux and Windows; Android and web from each host | |
| `codegen` | macOS, Linux, Windows | Native Assets loaded by each host's `flutter_tester` | |
| `plugin_example` | macOS, Linux, Windows (the `:windows_*` tests and `:android_bundle_build_test`) | each platform's implementations of real pub plugins; on Windows also one arm64 APK, whose AAR resources are the longest paths aapt2 opens ("Windows and MAX_PATH") | |
| `ffi_example` | macOS, Linux, Windows | native libraries in each platform's bundle, and a plugin with a Dart plugin class and `native_deps` (`//plugin_class`) | |
| `cross_compile_example` | macOS (`build`) | the Mac-to-Linux cross toolchain | Linux: a native build is `hello_world`'s; Windows: no such pair |
| `macos_example`, `ios_example`, `multi_window_example` | macOS | Apple-only features | Linux, Windows: Apple-only |
| `integration_test` | macOS, Windows (`build`), Linux (`test` of the `:linux_*` and `:web_*` targets) | the integration test rules building the app and test of each case, the Android and iOS apps included on macOS; on Linux those tests running headless on the pinned Linux runtime, fetched with every file of it and of the Chrome that loads it checked against the oldest supported host; on Windows the Windows ones (the Android tests, which run on an emulator pinned for macOS and Linux only, are skipped there): most of its tests need a GUI session or a hypervisor, which CI never runs a test in | |
| `pub_resolve` | Linux | a monorepo's path pub packages and a fork of a hosted one, built from the workspace targets the lock maps (platform-neutral); its `:render_test` runs the app in the pinned headless Chrome with the pinned Linux runtime | macOS, Windows: the same again |
| `dual_hub`, `web_example`, `android_example` | Linux | their platform-neutral subject, once, on the cheapest runner; web_example's `:render_test` runs the app in the pinned headless Chrome with the pinned Linux runtime | macOS, Windows: the same again |
| `android_example` | Windows (also) | an Android build on a Windows host: `gen_snapshot.exe`, engine-strip path separators, rules_android JVMs without an up-front heap commit (the committed patch) | |
| `asset_bundle` | macOS | the `flutter_assets/` tree of every platform against `flutter build`'s, once | Linux, Windows: no other host can analyse its iOS targets |
| `desktop_example` | Linux, Windows | Tier-2 Linux rules on Linux, Tier-2 Windows rules on Windows | macOS: its targets are Linux-only or Windows-only |
| `package_assets` | Linux, macOS | on Linux the package link hooks over a release compile's recorded uses (platform-neutral, run once, on the cheapest runner); on macOS a hand-linked code asset and a data asset on the app's own package, loaded by the macOS app | Windows: the same again |

The table in `e2e_matrix.dart` is the source; if this one disagrees, that one is
right. The macOS and Linux jobs run exactly `bazel test //...` (`build` for
`cross_compile_example`), with the flags of `CI_BAZELRC` in ci.yaml, which
every setup-bazel step writes to the user's `.bazelrc` (a quiet log, and a
failing test's output in it), so a target the system cannot build must
carry `target_compatible_with` and is then skipped, not failed. The Windows jobs
run in a short output base (`<drive>/b`, "Windows and MAX_PATH" below), so
they build Android targets as the other two do. Tests on Windows locate their `data`
through `package:runfiles`, never `$TEST_SRCDIR/...` paths, since the runner has
no runfiles tree, and run no tool from `PATH` that the image lacks: an APK test
unpacks with Bazel's zipper (`Apk.fromRunfiles` in `//tools/e2e_testing`, which
needs the zipper's `data` and `ZIPPER_RUNFILE` `env`), as the Windows image has
no `unzip`.

Everything tagged `manual` or `exclusive` stays out of `bazel test //...`, so CI
never runs a test that needs a GUI session, a display adapter, a simulator, an
emulator or a device (`verify_macos_app_test`, the `*_runtime_test`s,
`verify_android_app_test`, the team-signing test that needs a provisioning
profile, and the like). Those are § 4. CI also runs on GitHub's runner images:
what they ship (Xcode, the Android SDK and NDK, MSVC) is what the jobs build
with.

### Windows and MAX_PATH

Two tools in an Android build cannot open a path of 260 characters or more:
aapt2 (it is not long-path aware, so `LongPathsEnabled` does not help it), and
the DLL loader for the hermetic Python interpreter's `_socket.pyd`. Bazel's
paths on Windows are `<output base>/execroot/_main/bazel-out/<config>/bin/...`,
and rules_jvm_external unzips each AAR to `.../bin/external/<repo>/_aar/unzipped/
resources/<artifact>/res/...`. The longest in `e2e/plugin_example` is
`.../androidx_appcompat_appcompat/res/interpolator/btn_checkbox_unchecked_mtrl_animation_interpolator_1.xml`,
233 characters below the execution root, which leaves 26 for the execution root
itself. `bazel test //...` there failed in `//impeller_shader:impeller_shader_build_test`
with `aapt2.exe ... error: file not found` on that path under
`--output_user_root=C:/b`, where the execution root is `C:\b\<8 hex>\execroot\_main\`
(29 characters, 262 in all).

The fix is an output base named in full and as short as a path can be:
`<workspace drive>/b`, an execution root of 20. The CI job sets it through
setup-bazel's `output-base` input. `--output_user_root` cannot do it there:
setup-bazel puts `startup --output_base=D:/_bazel` in `~/.bazelrc`, and a startup
option from an rc file beats the command line's. That default is 25 characters of
execution root, 258 in all: under the limit by one, which the next artifact
bump may take. `tools/ci_matrix/test/windows_paths_test.dart` checks that the job
names the base and that the arithmetic holds; when `plugin_example` gains a longer
resource, change the constant there and shorten nothing else. On a VM pass
`--output_base=C:/b` (`//tools/vm:run_e2e` does, `C:/b/<hash of the folder>`).

Separately, three rules_android genrules (`Configuration_proto_file` and two
more) used to fail the first build of a fresh Windows output base with `replace
Configuration.proto? [y]es, [n]o, [A]ll, [N]one, [r]ename: NULL`. Each ran
`unzip` on the aapt2 proto jar with the execution root as its working directory,
where nothing sandboxes an action on Windows, so the same genrule in a second
configuration found the file the first had left, and every rerun that found it
failed again until the file was deleted. It reproduced on all three fresh output
bases of the VM run above. rules_android 0.8.1 pipes the entry through `sed`
instead of extracting it.

### What the automated e2e tests cover

| Workspace | Key tests |
|-----------|-----------|
| smoke | Toolchain resolution for all platforms |
| hello_world | Kernel, AOT, application, and per-platform bundle builds; flutter_test; `bazel coverage` of a flutter_test (`//coverage/...`: workspace paths, a library in another package, `--instrumentation_filter`, the merged report; CI runs it on Linux); on Linux, Windows and macOS, a profile-mode bundle whose AOT snapshot is a profile one (`verify_linux_profile_bundle_test`, `verify_windows_profile_bundle_test`, `verify_macos_profile_bundle_test`); `reproducible_notices_<mode>_test`: each mode's `NOTICES.Z` gzip header names no host OS and no time (on every host, Windows included) |
| codegen | Per-file and aggregate dart_codegen, custom generators, hot-reload-with-codegen; `go_router_codegen` (`@rules_flutter//flutter/ext/go_router`) writing the routes `:routes_test` drives |
| ffi_example | Both FFI mechanisms — Native Assets (`add_plugin`, `@Native` asset-id bind) and `native_deps` (`mul_plugin`, conventional-path open) — bundle structure on macOS/Linux plus manual runtime proof on iOS simulator and macOS; and, in `//plugin_class`, a third: `native_deps` with a `dart_plugin_class` (`multiply_plugin`), with FFI plugin build + macOS/Linux bundle structure with `libmultiply.dylib`/`.so` |
| plugin_example | Real pub.dev plugins (`path_provider`, `url_launcher`, `package_info_plus`) plus the hand-written `:greeting_plugin` regression case; per-platform bundle builds; web plugin assertions via the e2e suite; macOS runtime verifier asserting the four plugin-result strings. See **Plugin verification matrix** below. |
| macos_example | Full macOS app build + bundle structure verification (Info.plist, ObjC symbols, framework linkage, AOT dylib, flutter_assets, and a native library built in a subdirectory of its package landing flat at `Contents/Frameworks/libsub.dylib`) |
| ios_example | iOS app build (requires Xcode) |
| asset_bundle | Every asset a pubspec declares reaches the `flutter_assets/` tree under the key, variants, stored name and platform set `flutter build` gives it: an application at the root and below it, a library below the root and in an external module, and pub packages served by a fixture registry (variants, directory entries, URI-encoded names, `platforms:` and `flavors:` (in builds of each flavor and of none), on Android, iOS, Linux, macOS, Windows and the web); the `NOTICES` asset (`NOTICES.Z` gzip, `NOTICES` on the web) holds the engine's licences, sorted as flutter_tools sorts them, with the licence of every package the program depends on among the entries (a `NOTICES` over a `LICENSE`, one text under several names as one entry, none for a package without a file or one the program does not use) and its `additional_licenses` after them. `hello_world`'s `licences_test` and the `licences_test` of `integration_test` read the registry the framework builds from it. |
| pub_resolve | A monorepo: the lock at `apps/greeter/pubspec.lock`, and the app's `path:` packages built from workspace targets `flutter_pub.from_lock(resolve = ...)` maps: a `flutter_library` with an asset, a hosted dependency (`intl`) replaced by a fork whose output differs, and a path dependency of its own (a `dart_library` named otherwise than the package). `:greeter_test` and `:render_test` (headless Chrome) read the greeting those three make; `:bundle_test` checks the asset is bundled at `packages/greeting/assets/greeting.txt` |
| web_example | Web app builds with web_assets: WASM with the default dart2js fallback (`:app_wasm`), WASM only (`:app_wasm_only`, `js_fallback = False`, no `main.dart.js`), and dart2js alone; `//int64:int64_app`, a WASM-only app dart2js cannot compile (`:int64_app_with_fallback`, the default, manual, is the proof it fails) |
| multi_window_example | Multi-window macOS + multi-scene iOS builds with FlutterEngineGroup; macOS bundle verification |
| android_example | Android APK build (3 approaches: flutter_android_app, Bazel-generated manifest, custom manifest) + APK content verification + web build |
| desktop_example | Linux desktop app (2 approaches: flutter_linux_app, Bazel-generated runner, with its window title) and Windows desktop app (3 approaches: flutter_windows_app, Bazel-generated runner, custom cc_binary), each with bundle structure verification |
| package_assets | Package link hooks over a release compile's recorded uses (data assets dropped and kept, native and web, a hook that fails the build, an app's own hook), and a code asset and a data asset declared on an app's own package (`//own_assets`), with a macOS runtime test |

### Plugin verification matrix

`e2e/plugin_example` exercises real pub.dev plugins — `path_provider` (federated, SwiftPM Apple, **jnigen Android** — path_provider_android ≥ 2.3 calls Java through `package:jni`, whose C support library `libdartjni.so` is built from source by the bundled `flutter/ext/jni` overlay and packaged at `lib/<abi>/` — pure-Dart Linux/Windows), `url_launcher` (federated, SwiftPM Apple, Kotlin Android, real C++ Linux/Windows, web Dart), `package_info_plus` (monolithic, every platform including web), `shared_preferences` (federated; its Android Gradle build declares `androidx.datastore` and `androidx.preference`, which must come from the workspace's `rules_flutter_maven` install; every platform including web), `audio_session` (curated `flutter/ext/` overlay), and `record_android` 1.5.1 (Android-only federated implementation used without its umbrella — regression case for a plugin that ships `android/src/main/res/` resources referenced as `R.drawable.ic_mic` and declares **no** Gradle dependencies, compiling purely against the embedding's exported androidx classpath) — plus the hand-written `:greeting_plugin` (regression case for pure-Bazel-deps plugins). `lib/main.dart` resolves a string from each plugin and renders + emits them on a single `plugin_example_results …` log line. Each platform's e2e check asserts the line is correct; empty/null/error content fails loudly.

| Assertion | Source | Expected |
|---|---|---|
| `appName=…` | `PackageInfo.fromPlatform()` | `Plugin Example` on macOS/iOS (from `CFBundleName` in the generated Info.plist), `plugin_example` on web (from the auto-generated `version.json`'s `app_name`). Failure means the `package_info_plus` registrant didn't fire on that platform. |
| `documentsPath=…` | `getApplicationDocumentsDirectory().path` (`kIsWeb`-guarded) | `/Users/…` on macOS, `/var/…` on iOS, `/home/…` on Linux, `C:\Users\…` on Windows, `/data/user/0/…` on Android, `web: not supported` on web. |
| `tempPath=…` | `getTemporaryDirectory().path` (`kIsWeb`-guarded) | Absolute path with the platform-appropriate prefix; web shows `web: not supported`. |
| `launchOk=launch ok` | `canLaunchUrl(Uri.parse('https://flutter.dev'))` | Exact `launch ok` on macOS/iOS/Linux/Windows/web. On Android the correct value is `launch denied`: `canLaunchUrl` is subject to package visibility and the app declares no `<queries>` for https VIEW intents (flutter create output ships untouched). Either way the channel responded — an `error:` value means the `url_launcher` registrant didn't fire. |
| `prefs=roundtrip ok` | `SharedPreferences.getInstance()`, `setString('e2e_key', <millisecond time>)`, then `getString` | Exact `roundtrip ok` on every platform. `mismatch …` means the write did not read back; `error:` means the registrant didn't fire. On Android a build failure naming missing `@rules_flutter_maven` artifacts means the workspace's `maven.install` lacks what the plugins' Gradle builds declare; `bazel run //:<android app>_maven_artifacts` prints the block for that app's plugins (`@<hub>//android:maven_artifacts` for every plugin of the build). |
| `greeting=Hello from GreetingPlugin!` | `//greeting_plugin:greeting_plugin` (regression case) | Exact match. |
| `recordHasPermission=…` | `MethodChannel('com.llfbandit.record/messages')` `create` + `hasPermission(request: false)` | `has=true` on Android (`verify_android_app_test` grants RECORD_AUDIO via `adb shell pm grant` first, which itself fails if the plugin's manifest didn't merge); `not supported` everywhere else. An `error:` value means the `record_android` registrant didn't fire or its resources failed to compile. |

| Platform | Where the assertion runs |
|---|---|
| Web | `plugin_example_e2e_test.dart`, group `Web e2e` (asserts the four strings from the app-output line the run emits). |
| macOS | `:verify_macos_app_test` (manual stdout check) plus the `macOS e2e` group of `tools/dev_tool/test/e2e/plugin_example_e2e_test.dart` (runs `:plugin_macos`, captures a screenshot via the dev_tool's HTTP control channel, asserts the PNG is well-formed and non-blank). Run with `bazel run //tools/dev_tool:e2e -- test/e2e/plugin_example_e2e_test.dart --plain-name="macOS"`. |
| iOS Simulator | `iOS Simulator e2e` group of the same file. Boot any iOS simulator first (`xcrun simctl boot <udid>`), then run `bazel run //tools/dev_tool:e2e -- … --plain-name="iOS Simulator"`. |
| Android | `:android_bundle_build_test` (build), `:verify_android_apk_test` (APK content of five builds: arm64-v8a, arm64-v8a under `-c dbg`, armeabi-v7a, x86_64 and all three at once, each holding exactly its ABIs' `libflutter.so`, `libapp.so`, `libdartjni.so` and `androidx.datastore`'s AAR library, ELF/ABI-valid, jni support classes in dex — runs in `bazel test //...`), `:verify_android_build_config_identity_test` (reads the plugins' generated `BuildConfig` classes from the dex of a debug, a profile and two release APKs: each is present and its `LIBRARY_PACKAGE_NAME` is its plugin's package), `:verify_android_build_config_mode_test` (the same classes say what Gradle's would for the mode: `DEBUG` true and `BUILD_TYPE` `debug` in a debug build, `profile` in a profile build, false and `release` in release), `:verify_android_app_test` (manual: installs the both-ABI APK on the emulator or device attached, RESUMED + crash-buffer fail-fast, asserts the `plugin_example_results` logcat line reports a real `/data/user/0/…` path from path_provider — proves jnigen plugin registration end to end), plus the `Android e2e` group. Pre-step: bring up a device — either USB-authorize a phone (`adb devices` shows `device`) or boot an emulator (`emulator -avd flutter_test &`). Run `verify_android_app_test` (here and in `android_example`) with `bazel test :verify_android_app_test --test_tag_filters= --test_output=all`, plus `--test_env=ANDROID_SERIAL=<serial>` when more than one device is attached (a phone and an emulator, say). With several attached and no `$ANDROID_SERIAL`, the test fails at once naming the attached devices and how to choose, rather than letting `adb install` refuse mid-test; a serial `adb` does not list in the `device` state (not attached, `offline`, `unauthorized`) fails the same way, and every `adb` call after that carries `-s <serial>` (`AdbApp.chooseDevice` in `tools/e2e_testing`). It needs no `adb` on `PATH`: it runs the `adb` of the `@androidsdk` repository, the Android SDK at `$ANDROID_HOME` (exported as above) that Bazel already resolves for the build, which the target names in `data` and hands to the test as `$ADB_RUNFILE` (`$(rlocationpath @androidsdk//:adb)`; `AdbApp.fromRunfiles`). A target missing either fails naming what to set, and an SDK without `platform-tools` fails naming the package. Separately, the dev tool's own Android e2e cases (`glass_plugin_e2e_test.dart` and `plugin_example_e2e_test.dart`) resolve their device via `AndroidDeviceProbe.detect()`, which asks the `adb` of the root's downloaded SDK that `//tools/dev_tool:e2e` hands the suite as `$FLUTTER_BAZEL_E2E_ADB` (the dev tool drives the device with its workspace's own `@androidsdk`), and run `:plugin_android_fat` against it; both emulator and connected-device paths must pass. That probe separates two outcomes a single nullable serial would collapse: `adb` running and listing nothing is the one legitimate skip, while an `adb` that cannot be run, exits non-zero, prints output it cannot parse, or lists only devices outside the `device` state (`unauthorized`, `offline`) **fails the test** naming the cause — a broken detector must not report itself as an empty bench. Set `$ANDROID_SERIAL` to choose between an attached phone and a booted emulator; naming one that `adb` does not offer in the `device` state is a failure, not a skip. The dev_tool screenshot goes through the platform — `adb screencap` on a physical device, the emulator console on an emulator (see "Why an emulator is captured through its console") — because Android declares `supportsFlutterScreenshot => false` (Impeller cannot encode one) and the `screenshot/flutter` endpoint refuses with `501`. |
| Linux | `:linux_bundle_build_test` (build only). Visual verification on the GCP VM is manual (see § Linux visual verification). |
| Windows | `:windows_bundle_build_test` (build only). Visual verification on the GCP VM is manual (see § Windows visual verification). |

The dev_tool screenshot is the dispositive end-to-end gate per platform: if Native Assets are broken the app crashes before drawing, and if plugin auto-wiring is broken `MissingPluginException` blanks the screen — both fail the non-blank PNG check (default threshold 4 KB, well above any blank/solid-color PNG).

An Android app links the plugins it depends on, and those only (`flutter_android_plugin_libs`). `:verify_android_plugin_scope_test` checks it on real APKs: `package_info_only_android` depends on `package_info_plus` alone, though the lock lists six other Android plugins, and its release APK, built once without R8 (each library dexed by rules_android's own aspect, which only follows `deps`, `exports` and `runtime_deps`, hence the `exports` the generated libraries and plugins list their Android libraries under) and once with it, defines no class of the others and declares no `RECORD_AUDIO`. `//flutter/tests:android_plugin_libs_test` checks the link and the per-app Maven check at analysis. `android_example`'s `:testonly_app_build_test` builds a `testonly` `flutter_android_app`.

### Plugin native code their own build makes (externalNativeBuild, cargokit, ffiPlugin)

Some pub packages compile C/C++ for Android via Gradle's
`externalNativeBuild` (CMake/ndk-build) — e.g. `package:jni`, whose
`libdartjni.so` every jnigen-based plugin loads with
`System.loadLibrary("dartjni")`. rules_flutter has no generic translation
for arbitrary Gradle native builds; instead:

1. A curated overlay reproduces the build with `cc_library` +
   `cc_shared_library` (compiled by the registered NDK toolchain for each
   platform of `--@rules_android//flags:android_platforms`) and ships the `.so` through
   `flutter_plugin.native_deps` behind a
   `select({"@platforms//os:android": …})`. The library flows through the
   existing transitive native-libs pathway into the APK's
   `lib/<abi>/`, for each ABI built, subject to the same ELF/ABI machine
   validation as every other packaged library. `flutter/ext/jni/1/` is the
   canonical example (note `shared_lib_name` must yield the exact filename
   `System.loadLibrary` resolves).
2. Packages declaring `externalNativeBuild` that no overlay handles fail
   the Android build at load time with a message pointing at
   `flutter_pub.plugin_overlays` — never a silently incomplete APK.
   Non-Android platforms are unaffected (the check lives in the spoke's
   `android/` sub-package, loaded only by an Android build of an app that depends on the package: the package's `flutter_pub_member` lists its `:lib` under `exports` in a `select()` on Android).

The same check covers every platform and the other ways a plugin's own
build makes a library (`flutter/private/unbuilt_native_code.bzl`): cargokit
in the Gradle script, the podspec or the `CMakeLists.txt`; any other podspec
script phase; a non-empty `<plugin>_bundled_libraries`; and `ffiPlugin: true`
for the platform. On iOS and macOS the platform's library is a
`flutter_unbuilt_plugin_library`, on which `flutter_apple_plugins_aggregator`
fails; on Linux and Windows the runner fails in `plugin_link_flags`.
`//flutter/tests:unbuilt_native_code_test` reads the build files of
`super_native_extensions` 0.9.1, `rhttp` 0.18.0 and `webcrypto` 0.6.0, and
checks that the macOS build of an app with such a plugin fails while its iOS
build does not.

### Curated code assets (no authoring needed)

A pub package shipping a build hook is first checked against rules_dart's curated registry (`@rules_dart//dart/ext:registry.bzl`). Where rules_dart provides a Bazel replacement — `sqlite3` today — `flutter_pub.from_lock()` attaches it to that package automatically, so an app depending on `drift` gets `libsqlite3` without naming it and without an overlay. `e2e/ffi_example` covers this end to end; its `verify_*_runtime_test` targets assert the library actually loaded.

A package with a hook that *nothing* replaces is recorded, and `flutter_application` fails when it reaches one — the alternative is a clean build whose `*.native_assets.json` is one entry short and which dies at runtime on an unresolved `@Native` symbol. Two ways out: write an overlay (below), or declare the hook irrelevant with `flutter_pub.from_lock(ignore_hooks = ["<pkg>"])` when the package's native code is genuinely unused in this build.

### Pub dependency cycles

Pub allows packages to depend on each other (`dio` imports `dio_web_adapter`, which imports `dio`); Bazel does not. A hosted package in a `flutter_pub.from_lock()` hub is therefore two repositories, made by the one module extension:

* its **source** repository, `flutter_pub__<pkg>` (one per package for the whole build, however many hubs list it): the package's files, its **member** (`flutter_pub_member`, or rules_dart's `pub_package_member` for a package with nothing of Flutter's in its pubspec), the per-platform plugin libraries (`<pkg>_apple_macos`, `<pkg>_linux`, ...), its `android/` sub-package and the facts it records for its library repository (`pubspec_dependencies.txt`, `flutter_pub_member.json`). A member has no dependencies.
* its **library** repository, `flutter_pub_lib__<pkg>` (`flutter_pub_library_repo`): it reads the pubspec dependencies of every package the package reaches, finds its dependency cycle with rules_dart's `dependency_cycle()` and builds the cycle as one `flutter_pub_library` over the members' labels, with the cycle's dependencies outside itself as `deps`. The cycle's first package by name owns the library; the others of the cycle alias it. A package in no cycle is a cycle of one, built as before. A cycle of several is built only where it is declared: by the root module's `flutter_pub.cycle()`, which must be exactly the cycle at the build's versions, or by another module's or rules_dart's curated ones (`curated_cycles()`), which apply only where they are exactly the cycle. `pub_cycles.bzl` checks the declarations' form when the module is read and passes them through `flutter_pub_index`; `dependency_cycle()` fails on an undeclared cycle or a wrong root declaration, naming the declaration to write.

A Flutter SDK package other than `package:flutter` (`flutter_test`, `integration_test`, `flutter_driver`, ...) is built the same way, with `packages/<pkg>` of the pinned Flutter source tarball as its files in place of a hosted archive (`flutter_source_files`, linked in by `flutter_pub_package`). `lock_entry_kind.bzl` says which entries these are: every `sdk` entry but `flutter` and `sky_engine`, never by a list of names. Their Android libraries link into the Android apps that depend on them, as any plugin's does (`integration_test`'s needs `androidx.test`, Espresso and Guava in the app's `maven.install`).

`@<hub>//:<pkg>` is the package's library. The lock's other entries (`package:flutter`, which `flutter_framework_package` builds, and the stubs for entries nothing supplies) are one repository each, `flutter_pub__<pkg>`, which is their library. `flutter_pub_index` holds the package names of every lock once for all of them, so no repository's attributes grow with the locks. `@<hub>//:<pkg>` is an alias to the shared repository; a hub holds exactly the packages its own lock(s) list.

`flutter_pub_library` reads its members' providers itself: a `DartInfo` with one package record per member (each keeps its name, `package_root` and language version, so `package_config.json` cannot tell it from packages built one to a target) and a `FlutterInfo` that merges what each member contributes (plugin, native libraries, assets, fonts, shaders). A cycle can mix Flutter members and rules_dart's.

Not every case has a cycle's answer. A package built from an overlay is its own whole target and cannot be built with others, so an overlay in a cycle is an error at the fetch of its library, naming the package. `pub_cycle_e2e_test.dart` covers the cases.

### Native Assets overlay authoring

Pub packages that ship a `hooks/build.dart` Dart-Native-Assets build hook (e.g. `package:objective_c`) and have no curated entry get translated to Bazel-native equivalents under `flutter/ext/<pkg>/<major>/BUILD.bazel.tpl`. The template is loaded by `flutter_pub_package` for any package whose name + major version matches. It replaces the package's whole target in its source repository (`flutter_pub__<pkg>`), and the package's library is that target; for that reason a package built from an overlay cannot be in a dependency cycle (see "Pub dependency cycles"), and the fetch of its library says so.

Template substitutions: `{PKG}` (the package name), `{VERSION}` (the resolved version), `{LANGUAGE_VERSION}` (derived from the package's own `environment.sdk`), `{DEPS}` (the package's dependencies, as the labels of their libraries, intersected with the lock), and `{LICENSE}` (the `license_file = "LICENSE",` line of the package's `dart_package_metadata`, or nothing for a package with no `NOTICES` or `LICENSE`).

Substitution rewrites comment text too, so a comment that names a placeholder gets rewritten along with the code — write `PKG`, not `{PKG}`, in prose. `{HUB_NAME}` is gone (a package is one repository for the whole build, not one per hub): a template that writes it fails the fetch.

Three of those are mandatory (the first two as values a template must not write out by hand, `{LICENSE}` as a placeholder it must write):

* `{LANGUAGE_VERSION}` — the package's `environment.sdk` is the only place its language version is declared.
* `{DEPS}` — the package's pubspec is the only place its dependencies are declared, and deriving them is also what keeps a template from naming a repo the hub never created.

* `{LICENSE}` — written on its own line among the attributes of the template's `dart_package_metadata`. An overlay replaces the generated target wholesale, so a template without it drops the package's licence from every program's `NOTICES`; the fetch fails.

The first two exist because a template directory serves a whole version range, so a hand-written copy drifts on the package's next release with no build error to catch it. `objective_c` 9.5.0 is the worked example: its hook stopped using `native_toolchain_c`, so the package dropped it from `dependencies`, the lock stopped carrying it, the hub stopped creating the package's repositories — and `flutter/ext/objective_c/9/`, which serves all of 9.x, was still asking for `@<hub>__native_toolchain_c` (then a repository per hub). Consumers got an unknown-repo error naming neither `objective_c` nor the overlay.

For the same reason, prefer a `glob()` over a named source file when the file's existence varies across the range the directory serves — `test/util.c` in the `objective_c` overlay, which 9.5.0 deleted.

Procedure:

1. Locate the package's hook source under `~/Library/Caches/bazel/_bazel_<user>/.../external/*+flutter_pub__<pkg>/hook/build.dart`. Read what it builds (file glob, link mode, target platforms, copts).
2. Reproduce the build with `cc_shared_library` + `objc_library` (Apple) / `cc_library` (other platforms). Set `shared_lib_name` to the file name the library ships under (`<basename>`): the application bundles it under that name, and on iOS wraps it in a framework named after it.
3. Wrap the output in rules_dart's `dart_code_asset(name = "<pkg>_native_asset", asset_id = "package:<pkg>/<basename>", file = ":_<pkg>_dylib")`, constrained to the supported platforms with `target_compatible_with`. Platforms whose libraries differ in name (`lib<x>.so`, `<x>.dll`) set `shared_lib_name` with a `select()`.
4. Declare the package's facts on a `dart_package_metadata(name = "pubspec-metadata", package_name = "{PKG}", code_assets = select({...}), language_version = "{LANGUAGE_VERSION}", {LICENSE})`, and hang a `flutter_plugin(name = "<pkg>", package = ":pubspec-metadata", platforms = [])` over it; the empty `platforms` is right for a package that is "pure Dart" from pub's perspective. `code_assets` stands in for the hook: every program that depends on the package gets its assets, as under `flutter build`. The `select()` decides which asset targets an application sees: list exactly the ones that belong to the platform being built, and `//conditions:default: []` for the rest.
5. Drop the template at `flutter/ext/<pkg>/<major>/BUILD.bazel.tpl`. The next `bazel run @rules_flutter//flutter/pub -- get` + Bazel build picks it up automatically.

If the build fails at runtime with `Couldn't resolve native function "<symbol>"`, the most common cause is the `cc_shared_library`'s `install_name` not matching the asset id's basename — set `user_link_flags = ["-Wl,-install_name,@rpath/<basename>"]` on Apple targets. See `flutter/ext/objective_c/9/BUILD.bazel.tpl` for the canonical example.

## 4. Manual tests

These require a GUI environment and are skipped by `bazel test //...`.

### macOS runtime smoke test

Launches the app, polls for a window, and verifies dimensions > 100x100. Catches window sizing bugs (e.g. the 1x32 collapsed-window bug). It needs an unlocked screen; it wakes a sleeping display itself.

It also reads the app's stdout for `macos_example_native sum=7 difference=3`, which `main()` prints only after calling into both bundled native libraries: `libadd.dylib` (built at its package root) and `libsub.dylib` (built at `vendor/lib/` in its package). The window check cannot see this on its own — a library that fails to load throws in `main()` before `runApp`, and the runner still opens its 800x632 window (measured with the library renamed out of reach).

```sh
cd e2e/macos_example
bazel test :verify_macos_app_test --test_tag_filters= --strategy=TestRunner=standalone
```

**When to run:** After any change to macOS runner code (`flutter/private/runners/macos/`) or to what the macOS bundle carries (`flutter_macos_application.bzl`).

**`System Events reports no windows for any process` is usually the session, not your grant.** The test reads windows through System Events, which answers "no windows" (`-1719`) for every process, while reporting accessibility as enabled, in three different situations that look identical from the error alone. The failure therefore reads the session (`tools/macos_gui_session/lib/macos_gui_session.dart`) and says which one it is:

| It prints | Meaning | Remedy |
|---|---|---|
| `The screen is locked` | The login window is up. Measured 2026-11-03: `pmset displaysleepnow` locks this Mac at once (`sysadminctl -screenLock status` says "immediate"), and System Events returned `-1719` for the enumeration with the display awake and the grant intact. | Unlock the Mac. A harness cannot. |
| `The display is asleep and stayed asleep` | The panel is off. | The test wakes it itself and holds it awake for its run (`caffeinate -d -u`, tied to the test's pid): `-d` keeps an awake display awake, `-u` wakes a dark one. This message means that did not work; wake the Mac by hand. |
| `The test runner is not trusted for Accessibility` | `AXIsProcessTrusted` is false for the runner. | Grant the terminal or IDE in System Settings > Privacy & Security > Accessibility, then `killall "System Events"`. |
| `... yet System Events reports no windows` | Unlocked, awake and trusted, and System Events still cannot answer. | `killall "System Events"` and re-run, then `bazel shutdown` and re-run from the terminal. Measured 2026-09-18: in a workspace whose Bazel server had first been started by `flutter_bazel run`, the test failed this way while `osascript -e 'tell application "System Events" to count processes'` answered from the same terminal; after `bazel shutdown` it passed. The same message once appeared on 2026-11-03 on a fresh server with a live, trusted session and passed on the next run after `bazel shutdown`. Probably the same cause as the next sentence, not proven for that run. Measured later that day on a Mac with load above 50: System Events failed the old whole-machine enumeration (`processes whose background only is false`) 12 runs out of 12 with `-1719` "Invalid index" or `-10000`, because the process list changed while it was read; the old check read that error as "no windows". The enumeration now reads each process separately and reports an error as an error (`System Events did not answer the window enumeration: …`). If it still says so, the Mac is too busy to ask: re-run when the builds have finished (`bazel shutdown` frees the machine of a server's actions, which is probably why it "cured" the run). |

Before the hold existed, a sleeping display produced the old "Grant accessibility access to the test runner" advice on a machine whose grant was fine; `caffeinate -u -t 3` made the same test pass.

`e2e/_macos_test/verify_macos_app.dart` (below) holds the display the same way and prints the same diagnosis when no window appears. It carries its own copy of the probe because `tools/vm` copies that directory alone to bare machines.

### Running GUI tests on another Mac

The tests and runs that open windows can open them on a second Mac, so they do
not take over the screen of the one you build on. Bazel, the builds and the dev
tool stay here; only the finished program runs there. The other Mac needs the
same OS and CPU as this one (it is checked), an unlocked screen, and ssh access
without a password prompt (`ssh -o BatchMode=yes <host> true` succeeds). Nothing
is built or installed on it.

**A `verify_*_test` (or any test) on the other Mac:** run it under
`//tools/e2e_testing:ssh_test_runner`.

```sh
cd e2e/macos_example
bazel test :verify_macos_app_test --test_tag_filters= --strategy=TestRunner=standalone \
  --run_under=@rules_flutter//tools/e2e_testing:ssh_test_runner \
  --test_env=RULES_FLUTTER_TEST_HOST=<ssh destination>
```

Bazel starts the runner in the test's place. The runner copies the test's
runfiles to a fresh temporary directory on the host (`rsync --copy-unsafe-links`,
about 100 MB for `verify_macos_app_test`, and the runfiles manifest is rewritten
to point at the copies), runs the test's command there with the environment
Bazel gave it, its paths moved into that directory (`TMPDIR` too, so an
unpacked bundle goes with it), streams the output to the test log, copies back
what the test wrote under its test-log directory, and removes the directory.
The exit code is the test's. A timeout or Ctrl-C stops the test's process
group on the host before the runner exits. The same flags work for
`e2e/plugin_example` and `e2e/package_assets` (with
`//own_assets:verify_macos_app_test`; add `-c dbg` for its second mode). A host name belongs in your
`.bazelrc.user`, not in a checked-in file, for example as
`test:gui_host --run_under=@rules_flutter//tools/e2e_testing:ssh_test_runner --test_env=RULES_FLUTTER_TEST_HOST=<host>`.

**A dev tool web run whose Chrome opens on the other Mac:** point
`CHROME_EXECUTABLE` at `//tools/e2e_testing:ssh_chrome`.

```sh
bazel build //tools/dev_tool:flutter_bazel //tools/e2e_testing:ssh_chrome
cd e2e/web_example
CHROME_EXECUTABLE=../../bazel-bin/tools/e2e_testing/ssh_chrome \
RULES_FLUTTER_CHROME_HOST=<ssh destination> \
  ../../bazel-bin/tools/dev_tool/flutter_bazel run -t :app_wasm -d chrome --machine
```

The dev tool starts `ssh_chrome` with Chrome's command line. It runs the host's
Chrome over ssh on a fresh profile there, forwards the dev server's port to the
host's loopback (`ssh -R`), so the page loads from the same
`http://localhost:<port>` URL, and forwards Chrome's debugging port back
(`ssh -L`), so the port Chrome announces answers here. Hot reload, hot restart,
the agent commands and CDP screenshots go through those forwards. Stopping the
run quits that Chrome and removes its profile. To see the page, capture the
host's screen: `ssh <host> screencapture -x /tmp/shot.png`, then copy it back.

**What cannot run there:** the dev tool's macOS-desktop runs. `MacOSDevice`
starts the bundle on the machine the tool runs on, reads its VM service address
from the app's output and captures it with a local helper, so a hot reload or
restart check of a macOS app has to run where the tool and its builds are.
The same holds for the macOS cases of the dev tool's e2e suite (§2). Its web
cases find Chrome the same way, through `CHROME_EXECUTABLE`, but the suite has
not yet been run with `ssh_chrome`. Its iOS-simulator cases open no window on
this Mac if the simulator is booted with `xcrun simctl boot` and Simulator.app
is left closed.

**An iOS simulator app on the other Mac:** build it here and install it there.
The simulator runs debug builds only, so build with `-c dbg`:

```sh
cd e2e/plugin_example
bazel build -c dbg --ios_multi_cpus=sim_arm64 :plugin_ios
scp bazel-bin/plugin_ios.ipa <host>:/tmp/ && ssh <host> 'cd /tmp && unzip -oq plugin_ios.ipa &&
  xcrun simctl boot <udid>; xcrun simctl bootstatus <udid> -b;
  xcrun simctl install <udid> Payload/plugin_ios.app && xcrun simctl launch <udid> com.example.plugin'
ssh <host> 'xcrun simctl spawn <udid> log show --last 2m --predicate "process == \"plugin_ios\"" | grep plugin_example_results'
```

The app is built for iOS 15.0 and later, so an older simulator runtime on the
host than the one Xcode here ships is fine.

### FFI runtime tests (iOS simulator, macOS, Linux, Windows)

Behavioral verification that the native-library mechanisms work at runtime:
`add()` binds via `@Native` asset-id resolution (`dart_code_asset` →
`--native-assets` kernel manifest), `mul()` raw-opens its conventional path
(`native_deps`), sqlite3 arrives as a pub package's code asset, two asset ids
share one counter library, and `negate()` comes from a code asset whose library
is a prebuilt file. The app writes
`ffi_example_result add(3,4)=7 mul(3,4)=12 sqlite=HELLO shared=2 negate(5)=-5`
to its temp dir; the tests read it back (via `simctl get_app_container` on
iOS).

```sh
cd e2e/ffi_example
bazel test :verify_ios_simulator_test --test_tag_filters= --strategy=TestRunner=standalone
bazel test :verify_macos_runtime_test --test_tag_filters= --strategy=TestRunner=standalone
# Linux (headless boxes need Xvfb; XAUTHORITY must pass through):
xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 \
  bazel test :verify_linux_runtime_test --test_tag_filters= \
    --strategy=TestRunner=standalone \
    --test_env=DISPLAY --test_env=XAUTHORITY --test_env=LIBGL_ALWAYS_SOFTWARE
# Windows (needs a display adapter — on GCP create the VM with --enable-display-device):
bazel test :verify_windows_runtime_test --test_tag_filters= --strategy=TestRunner=standalone
```

**When to run:** After any change to native-assets manifest emission
(`flutter_native_assets.bzl`), native-library
bundling (`flutter_ios_native_frameworks`, `flutter_macos_native_libs`), or
kernel compilation flags.

`e2e/package_assets/own_assets` checks the same at runtime for
assets its app's own package declares: a `dart_code_asset` and a
`dart_data_asset`, the second read with `rootBundle`. The app prints
`native_assets_synthetic canary=0x42424242 blob=native-assets-synthetic-data-blob-v1`
before `runApp`. Run it in both modes:

```sh
cd e2e/package_assets
bazel test //own_assets:verify_macos_app_test --test_tag_filters= --strategy=TestRunner=standalone
bazel test //own_assets:verify_macos_app_test -c dbg --test_tag_filters= --strategy=TestRunner=standalone
```

### macOS visual verification

Launches the app binary directly, captures stdout/stderr, takes a screenshot, and prints structured JSON output. The screenshot file can be opened for visual verification.

```sh
cd e2e/macos_example && bazel build :app
# Extract the app
mkdir -p /tmp/macos_app && unzip -oq bazel-bin/app.zip -d /tmp/macos_app
# Run the diagnostic
dart run ../../e2e/_macos_test/verify_macos_app.dart /tmp/macos_app/app.app "Flutter App"
```

**The dev tool brings the app to the front itself.** After a macOS run's app is
up it is activated, because a process started as a bare executable is not made
frontmost, and on a Mac with Stage Manager its window sits in the strip as a
thumbnail (about 113x138 pt) rather than at the size the app asked for — or
comes out black in a capture once another app has come forward. Two ways, in
order, because neither works everywhere: `open` on the bundle, which needs no
permission but needs LaunchServices to know the process (over ssh it fails with
`-600`, procNotFound); then System Events setting the process frontmost by pid,
which needs the **Automation** permission above and, with that undecided,
blocks, so it is killed after ten seconds. If both fail the run carries on and
logs `macos_app_not_activated` with `openExitCode`, `openStderr`,
`systemEventsExitCode` and `systemEventsStderr` (or `systemEventsError`) as
fields. Found by the amorphous_ui session on a MacBook Air over ssh; on a
machine with a desktop session and no Stage Manager the app comes to the front
by itself and neither step is needed.

**Over ssh, launch with `open`.** Running the app binary directly in an ssh
session, with no window-server session of its own, gives a 134x129 window off
the left edge of the screen, and `lifecycleState` stays null: the main window
never appears. `open -n /tmp/macos_app/app.app --args ...` gives a proper one.
(Found on a MacBook Air by the amorphous_ui session; not reproduced on a
machine with a logged-in desktop.)

### Hot reload / hot restart (manual)

**MANDATORY** (CLAUDE.md verification policy item 6) for any change to the
dev_tool reload paths: `tools/dev_tool/lib/run_command.dart`,
`vm_service_client.dart`, `hot_reload/**`, `session.dart`. There is
intentionally **no automated assertion** for reload correctness — a weak
`expect(result, isNotNull)` smoke test stays green through real regressions. The
bar is "I have seen the new text render in the macOS window."

**Keep the window visible, and read the text rather than diffing bytes.** No
settling step is needed before the screenshot: `app.hotReload` already waits for
the first frame after the new kernel lands (`_applyAndVerify` in
`vm_service_client.dart`).

**Visible** means visible: ScreenCaptureKit enumerates with
`onScreenWindowsOnly: true`, so a window outside that set is **not capturable at
all** and `screenshot/native` fails outright rather than returning a stale
picture. There is no reload verdict to read off an image that does not exist,
and a visible window is the state that reliably keeps the window in that set.

Read the new text off the image rather than diffing bytes, because a byte-diff
against an earlier capture passes on any incidental change — a caret blink, a
clock — and so cannot tell a reload that landed from one that did not.

Verify all four:

1. **Race**: send `app.hotReload` *immediately* on the `app.started` event
   (no delay). Must return a success message, not
   `{"error":"Hot reload is still starting up."}` or
   `{"error":"No frontend server available"}`.
2. **Hot reload**: edit `lib/main.dart` visible text → `app.hotReload` →
   screenshot shows the new text.
3. **Hot restart**: edit again → `app.restart` with `fullRestart: true` → screenshot shows the
   change. Hot restart re-runs `main()` (engine `runInView`), so it must also
   reflect a change made *inside `main()`* (e.g. a value computed there) that a
   hot reload deliberately does NOT — verify a `main()`-level edit too.
4. **Agent surface after restart**: after a full `app.restart`, `app.getText` must
   still succeed. On native the `ext.rules_flutter.*` extensions are registered
   by the generated plugin registrant the engine invokes before `main()` on
   every root-isolate launch; if this errors with `Unknown method`, the
   registrant trio (`--source` ×2 + `-Dflutter.dart_plugin_registrant`) is
   missing from the dev tool's frontend_server invocation. The web route in is
   different — the dev tool's generated entrypoint registers them itself — and
   `agent_e2e_test.dart`'s Chrome case covers it, so there is no manual step.

**Source-assembled (codegen) apps** — also verify against `e2e/codegen :app_macos`.
This is the coverage for apps that mix hand-written + generated sources, including
**dependency packages** that do so:
- app package `codegen_e2e`: `lib/user.dart` + `:user_json` → `lib/user.g.dart`
  (a generated `part`);
- dep `dep_part`: a generated `part` (`lib/settings.dart` + `:settings_gen`);
- dep `dep_lib`: a generated **standalone imported library** (`lib/catalog.dart`
  imports `lib/catalog.g.dart`).

`lib/main.dart` renders a value from all three in `build()`, so regenerated output
is reload-observable. Verify:
- **Codegen reload (the real flow — edit a codegen INPUT)**: add a field to
  `dep_lib/lib/catalog.dart` → `app.hotReload` → the regenerated output renders
  (`fields:name` becomes `fields:name,email`). The dev tool runs `bazel build` of
  the flutter_application (`refreshGenerated`) to regenerate `*.g.dart`, then the
  normal diff invalidates the changed library by its `package:` URI.

  **`catalog.dart`, and a non-nullable field with a default** — e.g.
  `final String email;` with `const Catalog(this.name, [this.email = 'e'])`. Two
  constraints leave exactly this edit, and neither is about the dev tool:

  - Every generator in this fixture discovers fields with
    `final\s+\w+\s+(\w+);` (`tools/json_generator.dart`,
    `dep_lib/tools/catalog_generator.dart`), which cannot match a **nullable**
    `final String? email;` — the type carries a `?`. A nullable field
    regenerates nothing at all, so the step passes only against an assertion
    that was never going to fail.
  - A **non-nullable** field is unreadable off an instance canonicalized before
    the reload: `main()` builds `const User('Ada Lovelace', 36)`, the VM gives
    the stale instance null in the new slot, and the next frame throws `type
    'Null' is not a subtype of type 'String'`. It also walks into the
    `app.restart` hang tracked as a known issue, so the session has to be
    killed. That is Dart's hot-reload semantics, not this repo's.

  `catalog.g.dart` is a top-level const list of field **names**, and
  `Catalog.fieldSummary` joins those names without reading an instance field —
  so a non-nullable added field there regenerates observable output and never
  touches the stale slot.

  **`app.waitFor`'s `text` selector is exact equality on the widget's own
  string** (`flutter/private/dev_tool_support/agent.dart`), not a substring
  search: wait for `{name: Grace Hopper, age: 45}`, not `Grace Hopper`. A
  `waitFor` that finds nothing answers with a top-level `error` and **no**
  `result`, so any check shaped `response['result']?['error'] == null` reads a
  miss as a pass.
- **Hot restart over codegen**: edit the `User(...)` in `main()` → `app.restart` with `fullRestart: true` →
  the change renders and all generated code (app + deps) still resolves.
- **Dependency source edit**: edit a dep's hand-written source (e.g.
  `dep_part/lib/settings.dart`) → reload → renders. This exercises the
  `SourceUriResolver`, which keys every first-party source (app **and** deps) by its
  `package:` URI from the build-emitted `sourcePackages` — a dep edit must NOT be
  keyed `file://` (it would be silently dropped).

> **Gotcha — never edit or revert a source while a build is in flight.** An
> edit→revert cycle that straddles a build poisons bazel's action cache: the action
> is left cached against one input digest while holding output built from different
> content, and that stale output survives every later build (reproducible with pure
> `bazel build`; a clean cache always re-runs). This is **not** specific to
> generator scripts, and editing a codegen *input* is not immune — see
> [Stale staged sources (a poisoned action cache)](#stale-staged-sources-a-poisoned-action-cache)
> for the signature, the one-command diagnosis, and the fix.

Requires a `local_path_override` for `rules_dart` in `e2e/codegen/MODULE.bazel`
until the new rules_dart (`generate_dev_package_config` + `source_packages`) ships
in a release.

**Watch mode (filesystem-watcher-driven reload).** Machine mode defaults the watcher
off; pass `--watch` to drive reloads from on-disk edits instead of explicit
`app.hotReload` commands. Edit `lib/main.dart` and a **dependency** source on disk →
the watcher debounces and reloads → the change renders. Automated guard:
`tools/dev_tool/test/e2e/watch_reload_e2e_test.dart` (run via `bazel run //tools/dev_tool:e2e`). It
waits on the `app.reloadResult` protocol event for each edit — asserting the reload
succeeded and recompiled the edited package — and then on `app.waitFor` for the exact
new string, so a slow reload, a failed reload and a dead watcher are three different
failures rather than one silent one. Every on-disk
edit fires a debounced build, so the revert rule in
[Stale staged sources (a poisoned action cache)](#stale-staged-sources-a-poisoned-action-cache)
applies to each one — wait for the reload to complete before reverting.

**Release/AOT codegen run.** `bazel build //:app_macos -c opt` (release/AOT), launch
the extracted `.app`, and capture its window (e.g. the bundled
`//tools/macos_screenshot:screenshot --pid <pid>`): the generated output from the
app package + both dep packages must render. This verifies that the release kernel
compile, which finds each package's hand-written and generated files across the
source tree and `bazel-out` (`--filesystem-root` for each), and gen_snapshot after
it, run all generated code — distinct from the dev tool's compiler, and from the
`build_test`s which only compile.

Tests the full dev tool hot reload cycle: launch app, take screenshot, edit source, hot reload, take screenshot, verify the change rendered, revert source.

```sh
cd e2e/macos_example

# 1. Start the dev tool with --machine for structured JSON events on stdout.
#    Run the built binary (`bazel build //tools/dev_tool:flutter_bazel` in the
#    root first): under `dart run` the bundled macOS screenshot tool is missing
#    and screenshot/native answers "Could not find bundled macOS screenshot tool".
../../bazel-bin/tools/dev_tool/flutter_bazel run -t :app -d macos --machine &

# 2. Read stdout for the app.started event (contains appId) and
#    http_control_channel event on stderr. Its `endpoints` each carry a `url`
#    that already includes the token; the token is a query parameter, never an
#    Authorization header.

# 3. Take a screenshot (screenshot/flutter answers 501 under Impeller)
curl -s "http://localhost:PORT/sessions/APPID/screenshot/native?token=TOKEN" \
  -o /tmp/before.png

# 4. Edit lib/main.dart (change visible text)

# 5. Hot reload
curl -s -X POST "http://localhost:PORT/command?token=TOKEN" \
  -H "Content-Type: application/json" -d '{"method": "app.hotReload"}'

# 6. Take another screenshot (should show the changed text)
curl -s "http://localhost:PORT/sessions/APPID/screenshot/native?token=TOKEN" \
  -o /tmp/after.png

# 7. Revert the source change and stop the dev tool.
#    Revert only AFTER the reload response from step 5 has arrived — for codegen
#    apps that response is what tells you the build it triggered has finished.
#    Reverting mid-build poisons the action cache: see "Stale staged sources".
```

**When to run:** After any change to the dev tool, frontend server integration, or hot reload logic.

**Known issues:**
- `app.hotReload` may report "no changes detected" if the file watcher already auto-reloaded the change. This only happens when the file watcher is enabled (terminal mode default); `--machine` disables it by default.

**Note:** the dev tool owns DDS (starts it on the app's raw VM service and routes both its own VM client and DevTools through it), so `_flutter.screenshot` works with DevTools enabled; `--no-devtools` is not needed.

### Stale staged sources (a poisoned action cache)

A web app's package that mixes hand-written and generated sources is assembled into a
`*.pkgsrcs` tree artifact (rules_dart's `assemble_source_dir`, via bazel-lib's
`copy_to_directory`) so the web compilers see one real `rootUri`. (A native app's
kernel compile reads such a package in place, from the source tree and `bazel-out`
both, and stages nothing; the race below can still leave a stale kernel cached, and
the fix there is the same: remove that one output and rebuild.) That staged
tree can keep content from a superseded build **while the source tree is clean**,
and bazel will go on replaying it. It reads exactly like a broken checkout or a
broken dev tool; it is neither.

**Signature.** Two entry points, one cause:

- *Loud* — a compile error citing a path under
  `bazel-out/<config>/bin/<target>.<package>.pkgsrcs/…` quoting code that is not in
  the source file, with `git status` clean.
- *Quiet* — the staged content is stale but still valid, so the build is green, the
  reload reports success, and the app renders the old code. Nothing names a file.

Neither responds to `touch` (bazel invalidates on content digest, not mtime, so
rewriting identical bytes is a no-op) or to `bazel shutdown` (the action cache is on
disk, not in the server). Only the configurations you actually built are affected — a
`-c dbg` session leaves the `fastbuild` tree clean. But a package is staged once per
configuration, and the macOS runner adds min-OS-transitioned `*-ST-*` configs, so a
single session can leave several copies behind: check every one rather than assuming
plain `-c dbg`.

**Diagnose — diff the staged copy against its source.** For the loud variant the
error names the staged path; for the quiet variant, diff the file you just edited.
The build-emitted package config gives the mapping with no guessing:
`__web_app_branches.package_config.json` carries each package's staged `*.pkgsrcs`
root.

```sh
cd e2e/codegen

# Loud variant — the error names the exact staged path; diff that one file.
diff dep_part/lib/settings.dart \
  bazel-out/darwin_arm64-dbg/bin/__web_app_branches.dep_part.pkgsrcs/lib/settings.dart

# Quiet variant — nothing names a configuration, so check every staged copy.
for t in bazel-out/*/bin/__web_app_branches.dep_part.pkgsrcs; do
  diff -q dep_part/lib/settings.dart "$t/lib/settings.dart"
done
```

Any difference while `git status` is clean is this bug. Confirm with `--explain`:
in the poisoned state the copy action does not appear in the log at all, because it
is an action-cache hit — only the downstream compile re-runs, and fails identically
every time.

```sh
bazel build :web_app -c dbg --explain=/tmp/explain.log --verbose_explanations
grep pkgsrcs /tmp/explain.log   # poisoned: no output
```

**Fix — delete that one tree and rebuild.**

```sh
TREE=bazel-out/darwin_arm64-dbg/bin/__web_app_branches.dep_part.pkgsrcs   # the one the diff flagged
chmod -R u+w "$TREE" && rm -rf "$TREE"
bazel build :web_app -c dbg
```

`--explain` then reports `Executing action 'Copying files to directory
__web_app_branches.dep_part.pkgsrcs': action changed since cached execution.` **Do not reach for
`bazel clean`** (forbidden — see CLAUDE.md): removing one output directory forces
one action to re-run, where `bazel clean` discards the whole cache to repair a
single entry.

**Cause.** Bazel digests a source file when Skyframe evaluates its file state, but a
local action reads that file from disk when it *executes* — the macOS sandbox stages
symlinks to the live file, so `--spawn_strategy=sandboxed` does not close the gap.
Change the file in between and bazel records the action as `{inputs: pre-edit digest,
outputs: post-edit content}`. Restore the source to its pre-edit state and the
recorded inputs match *and* the recorded outputs match the stale tree on disk, so the
action is a cache hit from then on. The downstream compile failure is not cached, so
it re-runs against the stale tree and reproduces the same error forever.

Bazel names this hazard itself, in the help for `--guard_against_concurrent_changes`
(default `lite`): *"the cache may be polluted when a source file is changed while an
action that takes it as an input is executing."* That guard only checks inputs before
**remote-cache uploads**; this repo configures no remote or disk cache, so the local
action cache is unguarded.

This is not a rules_flutter, rules_dart, or bazel-lib bug, and not a property of
`copy_to_directory` or of tree artifacts — bazel does detect a tree artifact mutated
behind its back, warm server or cold, and re-runs the copy. The mechanism is a
per-action input-digest race and so is input-agnostic: no kind of input, generator
script or plain library source, is immune.

**Prevention — know the danger window.** Reload handling itself runs a build:
`refreshGenerated` invokes `bazel build` inside `app.hotReload`/`app.restart` for
codegen apps, and watch mode fires a debounced build on every on-disk edit. Never
revert a fixture edit until the build it triggered has finished. In `--machine` mode
the `app.hotReload`/`app.restart` **response** is that signal — the pipeline awaits
`refreshGenerated` before answering. Under `--watch`, wait for the reload-completed
event after each edit. Never revert on a timer.

**Upstream asks:**

1. *Bazel* — extend `--guard_against_concurrent_changes` to local action-cache
   writes, not only remote-cache uploads. The check that would have prevented this
   is already implemented; it just is not applied to the local cache.
2. *rules_dart* — add a staleness validation action inside `assemble_source_dir`, or
   expose a labelled handle to the assembled tree. The `.pkgsrcs` tree is an
   unlabelled sub-artifact of a helper function, so no consumer can write a bazel
   test that looks at it. A validation action taking both the staged tree and the
   source files as declared inputs would be sound by cache semantics — a poisoned
   copy leaves it with an input combination it has never cached, so it re-executes
   and fails loudly.

An on-disk sweep outside bazel is *not* a substitute: diffing every `*.pkgsrcs` tree
against its source root flags every target you simply have not rebuilt yet, which is
legitimate staleness rather than this bug.

### Android release (manual)

`verify_android_release_test` checks what `flutter_android_release` signs; this checks that it runs. With the phone attached and `ANDROID_SERIAL` set to it, in `e2e/android_example`, with a scratch key outside the repository (never commit one):

```sh
K=$(mktemp -d)
printf 'storePassword=throwaway123\nkeyPassword=throwaway123\nkeyAlias=upload\nstoreFile=%s/upload.jks\n' "$K" > "$K/key.properties"
bazel run :app_release -- create-key --key-properties="$K/key.properties"
bazel run :app_release -- --key-properties="$K/key.properties" --output-dir="$K/out"

# The bundle, as Play would serve this phone: split APKs signed with the key.
JAVA=$(bazel info output_base)/external/rules_java++toolchains+remotejdk25_macos_aarch64/bin/java
# bundletool with the Kotlin runtime its install-apks needs, from the runfiles
# of the bundle's own `bazel run`.
bazel build :app_bundle
BT_CP=$(jq -r '.bundletoolClasspath | map("bazel-bin/app_bundle.runfiles/" + .) | join(":")' \
    bazel-bin/app_bundle.android_bundle_install.json)
bt() { "$JAVA" -cp "$BT_CP" com.android.tools.build.bundletool.BundleToolMain "$@"; }
# The SDK's adb and aapt2 for this Mac, from the runfiles of the same run.
ADB=$(jq -r '"bazel-bin/app_bundle.runfiles/" + .adb' bazel-bin/app_bundle.android_bundle_install.json)
AAPT2=$(jq -r '"bazel-bin/app_bundle.runfiles/" + .aapt2' bazel-bin/app_bundle.android_bundle_install.json)
$ADB uninstall com.example.flutterapp
bt build-apks --bundle="$K/out/app-release.aab" --output="$K/out/device.apks" \
    --connected-device --device-id=$ANDROID_SERIAL --adb=$ADB \
    --aapt2=$AAPT2 \
    --ks="$K/upload.jks" --ks-pass=pass:throwaway123 --ks-key-alias=upload
bt install-apks --apks="$K/out/device.apks" --adb=$ADB --device-id=$ANDROID_SERIAL
$ADB shell am start -W -n com.example.flutterapp/.MainActivity
$ADB exec-out screencap -p > /tmp/release_aab.png

# The APK.
$ADB uninstall com.example.flutterapp
$ADB install "$K/out/app-release.apk"
$ADB shell am start -W -n com.example.flutterapp/.MainActivity
$ADB exec-out screencap -p > /tmp/release_apk.png

# `bazel run` of the bundle: debug-signed, installed through bundletool.
$ADB uninstall com.example.flutterapp
bazel run -c opt :app_bundle
$ADB shell am start -W -n com.example.flutterapp/.MainActivity
$ADB exec-out screencap -p > /tmp/bundle_run.png
$ADB uninstall com.example.flutterapp
```

Each screenshot shows "Hello from Flutter Android!", `native add(19, 23) = 42` and `shared counter = 2`. Uninstall at the end: an app signed with the scratch key blocks the debug-signed installs of the other device tests.

### Android mobile-install (manual)

`bazel mobile-install` is rules_android's; nothing in `bazel test //...` runs it, and a Bazel test cannot run another Bazel command against a device. This checks that a `flutter_android_app` installs, renders and takes an edit through it. With the phone attached and `ANDROID_SERIAL` set to it, `adb` on your PATH, in `e2e/android_example`:

```sh
bazel mobile-install //:app
adb exec-out screencap -p > /tmp/mi_1.png
# Change 'Hello from Flutter Android!' in lib/main.dart, then:
bazel mobile-install //:app
adb exec-out screencap -p > /tmp/mi_2.png
git checkout lib/main.dart
bazel mobile-install -c dbg //:app
adb exec-out screencap -p > /tmp/mi_dbg.png
```

Each run ends with `Finished deploying changes. Launching app`. The first screenshot and the debug one show "Hello from Flutter Android!", `native add(19, 23) = 42` and `shared counter = 2`; the second shows the edited text over the same two lines. A black screenshot is a locked phone: unlock it, or read `adb logcat -d | grep " flutter "` for the `android_example shared=2` line `main()` prints. If analysis fails with "Unable to infer Java package", `flutter_android_app` has stopped passing its `namespace` as the `android_binary`'s `custom_package`.

### The test VMs

The VM tooling is overhead's (`@overhead//vm`, in rules_dart's `overhead/`):
creating a VM, reaching it, copying to it, and running the e2e suites on it.
`//tools/vm` holds what is particular to this repository on top of it: the
Windows auto-logon session, display device, Python/dxcam and PsExec, the Linux
GTK and Xvfb packages, the Dart SDK `@rules_dart//dart` resolves to, the Defender
exclusions for this repository's builds, and which folders run (from
`tools/ci_matrix/e2e_matrix.dart`).

```sh
bazel run //tools/vm:run_e2e -- <vm-name> [--windows] \
    [--folders=.,e2e/hello_world] [--keep-going] [--rules-dart=../rules_dart]
```

The VM gets the **committed** tree: commit before each run. Each folder runs
what `ci.yaml` runs on that system, with CI's 120-minute limit; on a timeout the
runner ends that folder's Bazel server, so its build does not run on into the
next folder's. With `--rules-dart`, that checkout's committed HEAD goes over
too and every folder builds against it. The tree is at `C:\src\rules_flutter`
(Windows) or `~/src/rules_flutter` (Linux). `--remote-cache=<url>` shares a
Bazel cache between VMs. Delete a VM when done:
`gcloud compute instances delete <vm-name> --quiet`.

### Linux visual verification (GCP VM)

Cross-compile a Linux debug bundle from macOS, deploy to a GCP VM, and verify the Flutter UI renders.

```sh
# 1. Cross-compile (requires LLVM toolchain — use cross_compile_example)
cd e2e/cross_compile_example && bazel build :cross_linux

# 2. Create a Linux VM
bazel run //tools/vm:create_linux_vm -- flutter-linux-test

# 3. Deploy and verify
bazel run //tools/vm:deploy_bundle -- flutter-linux-test e2e/cross_compile_example/bazel-bin/cross_linux

# 4. Clean up
gcloud compute instances delete flutter-linux-test --quiet
```

**When to run:** After any change to Linux runner code, engine selection, or bundle assembly.

**What the check actually asserts:** that a window titled with the bundle's
name (the built-in runner's default title; pass `--title` for another) appears
(not merely that some window exists — the Xvfb root window always does), and
that a capture of it differs from the blank display measured before launch. It
fails loudly if the runner dies on a missing library, or maps a window and
paints nothing.

**Three things the VM needs, all handled by `//tools/vm:create_linux_vm` and
`verify_linux_app.dart`** — each fails silently when missing:
- `libgtk-3-0` is **not** in the Ubuntu cloud image; without it the runner exits
  with `libgtk-3.so.0: cannot open shared object file`.
- Flutter's GTK embedder renders through EGL, which ignores
  `LIBGL_ALWAYS_SOFTWARE` and tries DRI3 — unavailable under Xvfb.
  `GALLIUM_DRIVER=llvmpipe` is what actually selects software rendering; without
  it the window appears and stays empty.
- `scrot` (which `verify_linux_app.dart` still uses on the VM, next to
  `xdotool`) refuses to replace an existing file unless given `--overwrite`, so
  a polled screenshot silently keeps reporting the first frame it ever
  captured.

### Windows visual verification (GCP VM)

Build natively on a Windows VM, take a DXGI screenshot — fully automated over SSH (no RDP needed).

The create script sets up auto-logon via sysprep specialize, so an interactive console session exists at boot. PsExec launches apps in that session and `dxcam` captures DXGI screenshots.

```sh
# 1. Create a Windows VM (auto-logon, MSVC, Python, dxcam, PsExec)
bazel run //tools/vm:create_windows_vm -- flutter-windows-test

# 2. Deploy bundle and verify (automated — screenshot downloads locally)
bazel run //tools/vm:deploy_bundle -- flutter-windows-test <bundle_path> --windows

# 3. Clean up
gcloud compute instances delete flutter-windows-test --quiet
```

**What the check asserts:** that the app is still running after the wait,
and that it shows a visible top-level window with a non-empty client area. A
crash at launch fails it with the exit code (`0xC0000005` is an access
violation), and so does a runner that never parents the Flutter view in a
window of its own, as the engine creates the view in a message-only window
until a runner does. `deploy_bundle` exits non-zero on either.

**`e2e/desktop_example`'s three Windows apps** are built on the VM, since a
Windows bundle needs MSVC and, but in debug mode, a Windows host's
`gen_snapshot`. Build them with the workspace's tests, then check each where it
was built with `--on-vm`:

```sh
bazel run //tools/vm:run_e2e -- flutter-windows-test --windows \
  --folders=e2e/desktop_example --rules-dart=../rules_dart
for app in windows_app windows_bazel_runner_app windows_custom_runner_app; do
  bazel run //tools/vm:deploy_bundle -- flutter-windows-test \
    'C:\src\rules_flutter\e2e\desktop_example\bazel-bin\'$app --windows --on-vm
done
```

Their `bazel test` covers only that they build. The custom runner
(`windows_custom_runner_app`, a `cc_binary` over the engine's C API) shares no
code with the other two, so it has to be run to be checked. Run all three after
any change to the Windows runner, the engine's `CcInfo`, the bundle layout, or
`custom_runner/windows.cc`.

**Key details:**
- `--enable-display-device` is mandatory — provides virtual GPU for D3D
- GDI `CopyFromScreen` captures D3D/Flutter surfaces as **black** — must use DXGI (`dxcam`)
- Console resolution is 800x600
- Files are written to `C:\temp\` (shared), not user profile dirs

**When to run:** After any change to Windows runner code, engine selection, or bundle assembly.

### Windows build speed on a VM

Create the VM with `--machine-type=n2-standard-16 --disk-size=200GB`; the script puts
the boot disk on `pd-ssd`. The default `pd-standard` disk makes an Android build look
hung: rules_android's Python tools (`aar_resources_extractor`, `aar_native_libs_zip_creator`
and others) unpack a ~2000-file runfiles tree into `%TEMP%` for every action and delete
it on exit, and on a standard disk (about 650 IOPS, 7-12 ms latency, queue length 12,
measured) each of those actions took 3 to 10 minutes of waiting with no CPU use. The
same `e2e/android_example` `build //...` was still at 4,400 of 4,760 actions after more
than an hour there, and finished in 9 minutes with `%TEMP%` on SSD. `startup` options
and Defender exclusions do not change that. If a VM already exists on a standard disk,
attach a `pd-ssd` data disk and set `TEMP` and `TMP` to a directory on it before
running Bazel.

### Windows integration tests (GCP VM)

`e2e/integration_test`'s Windows targets run on the VM above, with two additions to what
the visual verification installs:

- **rules_dart's checkout.** The committed pin lags the tree (a build loads
  `runtime_reset`, which the pinned release lacks): ship the sibling checkout to
  `C:\rules_dart` and build with `--override_module=rules_dart=C:/rules_dart
  --lockfile_mode=off`, as the workstation's `.bazelrc.user` does.
- **A short output base**, `--output_base=C:/b/<n>` (§ "Windows and MAX_PATH").

The first build takes about eight minutes. `build //...` works from a Windows host: the Android
integration tests' runner takes the `adb` of the downloaded SDK for the host (`adb.exe`), and CI
builds this workspace on Windows. Run the tests by name, as they need the console session:

```sh
bazel --output_base=C:/b/2 test //:windows_pass_test //:windows_filter_test \
  //:windows_red_twin_test //:windows_crash_test //:windows_golden_test \
  //:windows_golden_mismatch_twin_test
```

A test's window is created in the session the test runs in. To see it, run Bazel in the
console session (`PsExec64.exe -accepteula -i 1 -u testuser -p <password> cmd /c <script>`,
the script writing Bazel's output to a file, as `//tools/vm:deploy_bundle` does) and
take a DXGI screenshot while a test holds its window up (`dxcam` through `PsExec -i 1`,
`e2e/_windows_test/dxgi_screenshot.py` is the capture). The window's title is the
runner's, `hello_world`. The console is
800x600, so a 1280x720 window is clamped to 804x581 physical pixels.

**When to run:** After any change to the integration test rules or the runner for Windows
(`flutter_windows_integration_test`, `WindowsDevice`, `tools/dev_tool/lib/integration/`).

### Linux integration tests (GCP VM)

`e2e/integration_test`'s Linux and web targets need no desktop and no library of
the host's beyond glibc and libstdc++, so they run on a stock Ubuntu 24.04 VM with
none of the packages the visual verification installs: create it with only `gcc`,
`g++`, `git`, `unzip`, `zip` and `curl`, and check that `ldconfig -p` lists no
`libgtk-3`, `libnss3` or `libEGL`, which is what makes a pass mean the runtime
supplied them. Run them on an x86_64 VM (`n2-standard-16`) and an arm64 one
(`t2a-standard-8`), as each architecture has its own runtime and Chrome.

- **No Android SDK or NDK on arm64.** The workspace downloads them on x86_64.
  Google publishes neither for an arm64 Linux host, so on arm64 copy the Linux
  and web targets into a scratch workspace that declares only `rules_flutter`,
  `rules_dart` and the `flutter` extension.
- **rules_dart's checkout**, shipped beside the tree and named with
  `--override_module`, as on Windows.

```sh
bazel test //:linux_pass_test //:linux_filter_test //:linux_red_twin_test \
  //:linux_crash_test //:linux_golden_test //:linux_golden_mismatch_twin_test \
  //:web_pass_test //:web_filter_test //:web_red_twin_test //:web_golden_test \
  //:web_golden_mid_frame_test //:web_golden_live_frames_test \
  //:web_golden_mismatch_twin_test
```

and web_example's `:render_test`. The first run fetches the runtime (about 160
Debian packages, 350 MB unpacked) and checks it (`FlutterLinuxRuntimeCheck`).

**When to run:** After any change to the integration test rules or the runner for
Linux (`flutter_linux_integration_test`, `LinuxDevice`,
`tools/dev_tool/lib/integration/`), to the runtime (`flutter_linux_runtime*.bzl`,
`flutter/private/tools/linux_runtime.dart`), or to its pins.

### Profile mode on Linux and Windows (GCP VM)

`gen_snapshot` cannot cross-compile AOT between desktop OSes, so a profile (or
release) desktop bundle is built on the VM itself, in the same workspaces as
above (`e2e/desktop_example`), not on the Mac. Ship the
committed tree the way `//tools/vm:run_e2e` does (overhead's runner packs it
with `git archive` from a scratch repository, so `export-ignore` does not drop
`e2e/`), then on the VM:

```sh
bazel build -c opt --@rules_flutter//flutter:profile //:linux_app   # //:windows_app on Windows
```

On Windows add `--output_base=C:/b` (MAX_PATH) and run bazel from a
scheduled task or another process that outlives the SSH session; the first
build takes about ten minutes. Run the bundle as the visual check does (Xvfb and
`scrot` on Linux, `dxgi_screenshot.py` through PsExec on Windows), and confirm
it is a profile build and not a release one:

- The Dart VM service answers. Linux prints `The Dart VM service is listening on
  ...`. The Windows runner has no console, so start the app with
  `FLUTTER_ENGINE_SWITCHES=2`, `FLUTTER_ENGINE_SWITCH_1=vm-service-port=8181` and
  `FLUTTER_ENGINE_SWITCH_2=disable-service-auth-codes`, then connect to
  `ws://127.0.0.1:8181/ws`.
- The main isolate lists the `ext.flutter.profile*` service extensions. A
  release engine serves no VM service at all.
- `libapp.so` / `app.so` and the engine library differ in size from a
  `-c opt` build without the flag.

#### What CI covers of profile mode

CI builds profile mode on both hosts, so a regression that stops the profile
build or ships a release snapshot in it fails a push, not a VM session. The
`E2E (hello_world, ubuntu-latest)` and `E2E (hello_world, windows-latest)` jobs
run `bazel test //...` in `e2e/hello_world`, which includes
`verify_linux_profile_bundle_test` and `verify_windows_profile_bundle_test`.
Each builds `hello_world_linux` or `hello_world_windows` through `flutter_profile_build`
(`-c opt --@rules_flutter//flutter:profile`, whatever the command line says),
downloading the profile engine and building the profile AOT snapshot, then
checks the snapshot. The Dart VM records the mode it was built for at the start
of every AOT snapshot: `release` from Flutter's profile `gen_snapshot`,
`product` from its release one. The test fails unless the bundle's `libapp.so`
(Linux) or `data/app.so` (Windows) says `release`.

On macOS, `bazel test //...` in `e2e/hello_world` runs
`verify_macos_profile_bundle_test`, the same check on `hello_world_macos`'s
`App.framework/App`, wherever that workspace's tests run on a Mac.

CI does not start the app, so it does not show that the VM service answers or
that the main isolate lists the `ext.flutter.profile*` extensions; the manual
checks above still cover those. The profile build is exercised through
`hello_world`; `e2e/desktop_example` runs in CI (see
"What CI covers" in § 3) but do not build profile mode.

## 5. Web rendering verification

Web rendering is verified from Dart: as a `bazel test` in `e2e/web_example`, and through the dev tool as part of the e2e
suite. There is no browser-test toolchain in this repo and no `npx` step.

| Check | Where | What it proves |
|-------|-------|----------------|
| Render, as a test | `e2e/web_example`, `bazel test :render_test` (macOS, Linux) | The app run in a pinned headless Chrome (Chrome for Testing) with an integration test as its program (`flutter_web_integration_test`, `integration_test/render_test.dart`). Three cases, each its own entry in Bazel's report: the screen's text read back out of the widget tree (the engine booted and the framework built the tree), the text of a widget fed by `assets/message.txt` (the asset bundle resolved: a bundle that boots and paints but cannot resolve its assets, or left one out, shows an empty label), and a tap that reaches the app. This is the check that used to be run by hand; it needs no flags and no dev tool, and fails on a blank page. It is skipped where the browser is not verified (Windows). |
| Render | `web_smoke_e2e_test.dart` | Reads text back out of a keyed widget over the agent surface. Answering proves the framework built the tree *and* resolved the asset bundle behind it — a bundle that boots, answers the VM service and paints nothing fails here. |
| Plugins on web | `plugin_example_e2e_test.dart` (`Web e2e`) | The four `plugin_example_results` strings on web, where each plugin takes a different path than on desktop (`package_info_plus` reads a generated JS manifest, `path_provider` has no web implementation, `url_launcher` goes through `window.open`). |
| Templating / defines | `custom_boot/test/verify_templating_test.dart` | Substitution outcomes in the built bytes: web defines resolved, kept placeholders survived, `buildConfig` emitted, no `{{` left. |
| WASM-only layout | `web_example/test/verify_compiler_flags_test.dart` | A `js_fallback = False` bundle ships no `main.dart.js` and its build config lists the WASM build alone; the default lists the JS build second. Analysis tests in `flutter/tests/web_test.bzl` (`_wasm_only_bundle`, `_js_fallback_bundle`) pin the same on the actions: no dart2js action runs with `js_fallback = False`, and the default runs one. |
| Browsers by hand | `app_wasm` (default), `app_all_browsers`, `app_wasm_only` | Safari is on this Mac (`/Applications/Safari.app`) and `safaridriver` needs 'Allow remote automation' enabled in its settings, a user step. Without it: serve the bundle from a small server that logs requests and fronts `flutter_bootstrap.js` with a probe that reports `crossOriginIsolated`, workers started and console warnings back to the server, run `open -a Safari <url>`, and capture **only Safari's window** (`screencapture -x -o -l<window id>`, the id from `CGWindowListCopyWindowInfo` filtered to Safari; a bare `screencapture` takes the whole desktop). Expect: default bundle in Safari fetches `main.dart.js`; `wasm_browsers` naming `webkit` fetches `main.dart.wasm` and `skwasm_heavy.*`; `js_fallback = False` with the default allow-list shows the message. Chrome needs no probe: `Page.captureScreenshot` over CDP on headless Chrome. |
| Per-compiler code | `flutter/tests/web_test.bzl` (`_per_compiler`, `_per_compiler_dev`, `_branch_inputs`, `_branch_config_*`), `flutter/tests/web_compiler_test.bzl`, `web_per_compiler_e2e_test.dart` | Each compile reads its own branch: the dart2wasm compile the `wasm` variant of a dependency and the dart2js compile the `js` one, the icon scan and the other once-per-bundle inputs the primary's, and in a debug build the dev package config the `js` one (`_per_compiler*`). Each branch's package config names each package once (`_branch_config_*`) and the bundle writes none itself, which is what two package configs in one target would collide on (`_branch_inputs`). `web_compiler_test.bzl` shows where generated files land, the configuration they were built in: a `flutter_native_library`, what `flutter_gen_l10n` generates, and a `runtime_independent` library or plugin are in the plain build's configuration under both compilers (built once), while a library or plugin that is not independent is built for each (the control). The generated SDK spokes say `runtime_independent = True` (`flutter_framework_package_test.bzl` for `package:flutter`; the others go through the pub writer), and a pub package's library, `flutter_pub_library`, resets the web platform itself, as rules_dart's `pub_library` does. The end-to-end test draws each variant in Chrome |
| Allow-list, message, renderer files | `web_example/test/verify_compiler_flags_test.dart`; `web_test.bzl` (`_wasm_browsers_bootstrap`, `_renderer_files_*`) | `wasm_browsers` reaches the bootstrap as an exact `wasmAllowList`, the bootstrap catches a load failure and shows a message, and a bundle ships a local `canvaskit/` only with `use_local_canvaskit` or in a debug build, holding only its renderers' files (skwasm family, CanvasKit family, or both) and never the `.symbols` maps, which ride the `symbols` output group. The runtime claim behind that (nothing fetches a `.symbols` file, and the dev loop fetches `canvaskit/chromium/canvaskit.{js,wasm}` from the bundle) was checked by reading `performance.getEntriesByType('resource')` over CDP on a `flutter_bazel run -d chrome` and `--wasm` run; redo it if the loader changes. By hand, in Chrome: `//:app_no_blink` (Chromium left out) shows the message rather than a blank page; a WASM-only bundle with `useLocalCanvasKit` renders served with and without COOP/COEP, requesting only `canvaskit/skwasm.js` and `skwasm.wasm`. A browser extension's tab shows a cross-origin-isolated skwasm page blank, bundle or no bundle; drive Chrome over CDP (`Page.captureScreenshot`) for that check. |
| Local CanvasKit | `web_example/test/verify_compiler_flags_test.dart` | `useLocalCanvasKit` is declared, so the renderer loads from the app origin rather than gstatic.com — the regression a strict `script-src 'self'` exposes. |

```sh
bazel run //tools/dev_tool:e2e -- test/e2e/web_smoke_e2e_test.dart
```

## 6. Standalone diagnostic scripts

These are not Bazel tests — they're standalone Dart scripts for manual investigation.

| Script | Purpose | Usage |
|--------|---------|-------|
| `e2e/_macos_test/verify_macos_app.dart` | Launch macOS app, verify window, screenshot | `dart run <script> <app.app> [title]` |
| `e2e/_linux_test/verify_linux_bundle.dart` | Verify Linux bundle directory structure | `dart run <script> <bundle_dir> [native_libs...]` |
| `e2e/_linux_test/verify_linux_app.dart` | Launch Linux GTK app under Xvfb, verify window, screenshot | `dart run <script> <bundle_dir> [title]` |
| `e2e/_windows_test/verify_windows_bundle.dart` | Verify Windows bundle directory structure | `dart run <script> <bundle_dir> [native_libs...]` |
| `e2e/_windows_test/verify_windows_app.dart` | Launch Windows app, verify window via PowerShell | `dart run <script> <bundle_dir> [title]` |
| `e2e/_windows_test/dxgi_screenshot.py` | Launch app, check it runs and shows a window, DXGI screenshot (captures D3D/Flutter) | `python <script> <exe_path> <output.png> [wait_s]` |
| `e2e/_compare/compare_artifacts.dart` | Diff flutter build vs bazel build outputs | `dart run <script> <flutter_dir> <bazel_dir>` |
| `tools/dev_tool/tool/concurrent_sessions.dart` | Two `flutter_bazel run` sessions in one workspace vs one (control) | `dart run <script> [solo\|pair] [edits]` |

`concurrent_sessions.dart` targets a race that does not reliably reproduce.
Read a passing `pair` as "the collision did not happen in this run", not as "it
cannot": the race is timing-dependent and the generated-sources half of it is
unfixed. Run `solo` alongside it as the control. Like the rest of this table it
runs on the `dart` on `PATH`, and this one resolves the dev tool's pub workspace,
so that `dart` has to be ≥ 3.13 and belong to a Flutter SDK (§ 2 says why the e2e
runner needs both).

## Quick reference: what to test when

| Change area | Minimum test scope |
|-------------|-------------------|
| Starlark rules (`flutter/*.bzl`) | Root `//...` + all e2e workspaces |
| macOS runner (`flutter/private/runners/macos/`) | macos_example `//...` + manual runtime test |
| Linux runner / bundle (`flutter/private/*linux*`) | desktop_example (on Linux), cross_compile_example, GCP VM visual test |
| Windows runner / bundle (`flutter/private/*windows*`) | desktop_example (on Windows), GCP VM visual test |
| Windows integration tests (`flutter_windows_integration_test`, `WindowsDevice`) | `e2e/integration_test`'s Windows targets on the GCP VM (§ Windows integration tests), desktop_example `//...` on Windows, and the platform-neutral integration row |
| Linux integration tests and the Linux runtime (`flutter_linux_integration_test`, `LinuxDevice`, `flutter_linux_runtime*`, `linux_runtime_pins.bzl`, `tools/update_linux_runtime`) | `e2e/integration_test`'s `:linux_*` and `:web_*` targets and web_example's `:render_test` on the x86_64 and arm64 GCP VMs (§ Linux integration tests), desktop_example `//...` on Linux, and the platform-neutral integration row |
| Desktop engine selection (debug/profile/release) | cross_compile_example `bazel build :cross_linux` + verify on VM |
| Profile mode (`flutter:profile` selects, profile engine repos) | Root `//...`, macOS and a device by hand, hello_world `//...` on Linux and Windows (CI does this), and the profile run on the Linux and Windows VMs (§ Profile mode on Linux and Windows) |
| Integration tests (`flutter/integration_test.bzl`, `flutter/private/flutter_integration_*.bzl`, `flutter/private/integration_test/support/`, `tools/dev_tool/lib/integration/`, `bin/integration_test_runner.dart`) | `e2e/integration_test` `//...` on each platform the change touches (macOS, with an unlocked screen, for macOS desktop; the Windows VM for Windows; macOS for web; for Android, the emulator tests on macOS, and on the attached phone with `--@rules_flutter//flutter/integration_test:android_device=attached` and `ANDROID_SERIAL` when the Android runner changed), dev_tool unit, plus the platform's row; for web, `e2e/web_example` `:render_test` and the Web support row |
| The `flutter_test` runner and its suite protocol (`flutter/private/tools/flutter_test_runner.dart`, `flutter/private/tools/lib/`: tag selection, `--test_filter`, shards, the no-tests failure) | Root `//...`, `e2e/integration_test` `//...` (its `tags_*` and `no_tests_test` outcome tests, and `web_*`), dev_tool unit |
| `bazel coverage` of a `flutter_test` (the runner's `CoverageRun` and `collectCoverage`, `COVERAGE_ATTRS` and `test_coverage` in `flutter_program_test.bzl`, a rule's `instrumented_files_info`) | Root `//...`, and in `e2e/hello_world` the coverage commands of § 3 |
| `flutter_application_variant` (`flutter/private/flutter_application_variant.bzl`, `flutter_program_inputs` in `common.bzl`) | Root `//...`, macos_example `//...` and `bazel run //tools/dev_tool:e2e -- test/e2e/main_outside_lib_e2e_test.dart --plain-name="macOS"`, which reloads and restarts a variant; plus the macOS manual runtime test |
| Dart compilation / AOT | hello_world, ffi_example, macos_example |
| Asset bundling | hello_world, plugin_example |
| Shader compilation, bundling or hot reload, or how a workspace plugin is wired | `glass_plugin_e2e_test.dart` on every platform it covers, and plugin_example's `//impeller_shader:app_flutter_sksl_required_test`: with SkSL required, the shader compile of `:app_flutter_sksl_required` (`manual`, since it does not build) fails, saying the shader does not compile for Skia |
| Web support | web_example `//...` (a WASM-only bundle, an `Int64List` app that keeps the dart2js fallback through a per-compiler `select()`, and `:render_test`, the render check in headless Chrome) + `web_smoke_e2e_test.dart` (render) + `web_per_compiler_e2e_test.dart` (both programs of a per-compiler app, in Chrome) + `plugin_example_e2e_test.dart` (plugins on web) + `native_libs_reload_e2e_test.dart`'s web group if the change touches `native_modules` or the web reload arms |
| FFI / native deps / native assets | ffi_example (incl. manual iOS-sim + macOS runtime tests, and `//plugin_class`), `package_assets` (incl. `//own_assets:verify_macos_app_test`, manual, in debug and release) |
| Data assets and link hooks (`dart_data_asset` handling, `link_hook_assets` on package metadata, `flutter_build_assets`' data assets) | root `//flutter/tests:data_asset_test`, `package_assets` `//...` with and without `-c dbg` plus its `//own_assets:verify_macos_app_test` |
| Plugins | plugin_example, ffi_example (`//plugin_class`) |
| Apple add-to-app (`flutter/private/apple_add_to_app.bzl`, `flutter_apple_xcframeworks.bzl`, `flutter_apple_plugin_xcframeworks.bzl`, `flutter_apple_registrant.bzl`, `apple_xcframeworks_*.bzl`, `flutter_plugin.bzl`'s Apple entries, `flutter_apple_plugin_library.bzl`, the `apple_*` tools) | Root `//flutter/private/tools/...`, plugin_example's `:add_to_app_{ios,macos}_{debug,release}[_signed]_test` (layout, modules, signatures, Swift package), **and** its `manual` Xcode hosts with a booted simulator and an unlocked screen: `bazel test :add_to_app_ios_host_debug_test :add_to_app_macos_host_debug_test :add_to_app_macos_host_release_test --test_tag_filters=`, whose screenshots are in each test's `test.outputs/` |
| Android release (`flutter_android_release`, `flutter_android_app`'s `app_bundle`/`bundle_config`/`proguard_specs`, `flutter/android_proguard_rules.pro`, `flutter/android_bundle_config.pb.json`, `release_transition.bzl`, `android_release.dart`, `flutter_android_bundle_install.bzl`, `android_bundle_install.dart`) | Root `//...` (`android_release_test`), android_example `//...` (`verify_android_release_test` signs with a key it makes), plugin_example `//...` for an R8 change, **and** "Android release (manual)" in § 4: both signed installs render on the phone |
| `flutter_android_app`'s `android_binary` arguments (`custom_package`, `assets`), `flutter_android_bundle`'s outputs, or a bump of `rules_android` | android_example `//...` **and** "Android mobile-install (manual)" in § 4 |
| Android add-to-app (`flutter_android_aar`, `flutter_android_aar.bzl`, `android_aar.dart`, `android_maven_repo.dart`, `maven_repo.dart`, `zip_archive.dart`, `android_aar_install.dart`, `flutter_plugin_platform.group`, and the pub spokes' reading of it in `android_plugin_maven.bzl`) | Root `//...` (`android_aar_test`, `android_maven_repo_test`, `android_aar_install_test`, `android_plugin_maven_test`), plugin_example `//...` (`verify_android_aar_test` checks the layout, POMs and AARs in release and debug, and a workspace plugin under its declared `group` (`//glass_app:glass_module_aar`); `//glass_app:no_group_aar_test` checks the failure when `group` is missing; custom_engine's `//:aar_of_local_engine_refused_test` checks that the module's AAR refuses an engine that is not the release's; `verify_android_aar_resolves_test` resolves every coordinate against the repository, the engine POMs MODULE.bazel pins and `@rules_flutter_maven`'s lock), plugin_example `//... --config=deep` (`gradle_host_test` builds the Gradle host app of `add_to_app_host/android` offline against the debug, profile and release repositories, with Gradle, the Android Gradle plugin and its Maven artifacts pinned by MODULE.bazel and the lock `bazel run --config=deep //:record_gradle_host_repository` writes, and checks each APK's native libraries per ABI, dexed plugin classes and merged manifest), **and** `bazel run` of `//:plugin_module_aar` in `-c dbg`, profile and `-c opt` into one repository: the three modes' `maven-metadata.xml` and the printed host steps |
| Android ABI selection (`flutter_android_engine`, `flutter_android_bundle`, `flutter_android_build`, `AndroidDevice` ABI in `device.dart`) | Root `//...`, android_example, hello_world and plugin_example `//...` (force-run `verify_android_apk_test`), dev_tool unit **and** `flutter_bazel run` on the attached phone (arm64-v8a) and on an x86_64 emulator, which must each launch the app |
| Toolchain / SDK, or any action's inputs from the Dart SDK | smoke, hello_world, and `//flutter/tests:sdk_inputs_test` with `//flutter/tests/sdk_sets:sdk_sets_test` (see § "SDK inputs") |
| Reconciling several locks, or which extension makes which repository (`pub_reconcile.bzl`, the `flutter` extension in `flutter/extensions.bzl` and the `pub` extension in `flutter/pub/extensions.bzl`) | Root `//flutter/tests:pub_reconcile_test`, `bazel run //tools/dev_tool:e2e -- test/e2e/pub_versions_e2e_test.dart` (its fix-command case shows `bazel run @rules_flutter//flutter/pub` running while the locks disagree, which needs every repository the runner reaches to come from `flutter`), `e2e/dual_hub` `//...`, and `bazel run @overhead//locks:check` |
| Naming a lock's `path` packages (`pub_resolve.bzl`, `flutter_resolved_package.bzl`, `resolved_package.bzl`, `resolve`, `build_from_pubspec` and `ignored` in `flutter/private/pub_extension.bzl`, `fetch_local_package` in `flutter_pub_package.bzl`) | Root `//flutter/tests:pub_resolve_test` and `:pub_reconcile_test`, `bazel run //tools/dev_tool:e2e -- test/e2e/pub_resolve_e2e_test.dart test/e2e/pub_path_package_e2e_test.dart test/e2e/pub_inputs_properties_e2e_test.dart`, `e2e/pub_resolve` `//...` (its `:render_test` is the render check), and plugin_example's `:verify_android_registrant_test`, `:verify_android_apk_test` and `:ignored_package_test` (a Kotlin-only `path` plugin built from its pubspec into the APK, and an ignored one) |
| `flutter_pub.annotation` (`pub_settings.bzl`, `annotated_requirements` in `android_plugin_maven.bzl`, `android_deps` in `flutter_pub_package.bzl`) | Root `//flutter/tests:pub_settings_test`, `:android_plugin_maven_test` and `:flutter_pub_package_test`, `bazel run //tools/dev_tool:e2e -- test/e2e/pub_inputs_e2e_test.dart` (the refusals and the spoke it writes), and plugin_example `:annotated_android_build_test` (the Kotlin compiles against the annotated artifact) and `:verify_android_maven_artifacts_test` (the app's report lists it) |
| Reading a pubspec (`flutter_pubspec.bzl`, a `read_pubspec` call in `flutter_pub_package.bzl` or `flutter_framework_package.bzl`) | Root `//flutter/tests:flutter_pubspec_test` and `:flutter_framework_package_test` (the projection of `fields`, on dict inputs), hello_world and plugin_example `//...`, **and** `bazel run //tools/dev_tool:e2e -- test/e2e/pubspec_reading_e2e_test.dart test/e2e/framework_pubspec_e2e_test.dart test/e2e/pub_inputs_e2e_test.dart test/e2e/pub_inputs_properties_e2e_test.dart test/e2e/pub_cycle_e2e_test.dart test/e2e/sdk_source_e2e_test.dart` (what the repository rules do with the pubspecs they read, which no Starlark unit test can run) |
| How a pub package's files are linked in (`link_pub_files` and the BUILD file it prefixes, in `flutter_pub_package.bzl`; `flutter_source_files.bzl`), or anything `bazel vendor` would vendor differently | Root `//...`, hello_world `//...`, **and** `bazel run //tools/dev_tool:e2e -- test/e2e/pub_vendor_e2e_test.dart` (a build from the vendored directory in a new output base, after the vendoring one is deleted) |
| Anything that downloads (`download*` in a repository rule, `ARTIFACT_CHECKSUMS` / `source_sha256` / `CHROME_FOR_TESTING` in `versions.bzl`, `flutter_source_files`, `flutter_chrome_for_testing`, `update_flutter_version`, `update_chrome_for_testing`) | Root `//flutter/tests:download_digests_test` (every table digest is 64-hex, for every version, host, target and mode the macros iterate, and for each host's Chrome for Testing archive; `bazel run //tools/update_chrome_for_testing` reprints the Chrome entry, so it also shows the pinned digests are the ones the archives have) and `//flutter/tests:pinned_test` (what counts as a digest) and `//flutter/tests:chrome_runner_build_test` (this host's Chrome for Testing shell downloads, verifies and unpacks) and `//tools/download_guard/...` (every `download*` call in `//flutter` passes its digest through `pinned()`, which refuses a missing or malformed one before the request; a hosted pub package is fetched by rules_dart's `pub_archive_files`; a call to rules_dart's `fetch_pub_archive` is accepted only when it is loaded from `@rules_dart//dart/pub:pub_lock_package.bzl` and given a `sha256`), **and** `bazel run //tools/dev_tool:e2e -- test/e2e/digest_pinned_e2e_test.dart test/e2e/digest_missing_e2e_test.dart test/e2e/pub_archive_e2e_test.dart test/e2e/sdk_source_e2e_test.dart test/e2e/pub_vendor_e2e_test.dart` (what a fetch does with a good, a bad and a missing digest, and what a Flutter SDK package's fetch from the source tarball does with a package that is, and is not, in it; needs no device; the generated workspace resolves its modules from Bazel's registry or repository cache) |
| A new or removed e2e workspace, or where one runs in CI (`tools/ci_matrix/e2e_matrix.dart`, `.github/workflows/ci.yaml`) | `bazel run //tools/ci_matrix` (fails on a gap) and `bazel test //tools/ci_matrix/...` |
| A new package with a `BUILD` that loads a repo only development has (a dev dependency of `MODULE.bazel`), or a change to `ignore_directories` in `REPO.bazel` | `bazel run //tools/consumer_archive`, then `cd e2e/external_module` and both `bazel query "@rules_flutter//..."` and `bazel build --nobuild "@rules_flutter//..."` must succeed (the archive is committed state only, and omits what `.gitattributes` trims); put such a package in `ignore_directories` |
| The bazelrc preset (`tools/preset.bazelrc`, or a bump of overhead) | `bazel run @overhead//preset`, then `bazel run @overhead//preset -- --check` |
| Maven artifacts (a `maven.install` in any `MODULE.bazel`, or a bump of `rules_android` or `rules_jvm_external`) | `bazel run //tools/maven_locks -- --refresh` on every Android workspace (hello_world, plugin_example, android_example, custom_engine, integration_test) and `.`, then `bazel run --lockfile_mode=off @overhead//locks:refresh` on each, and `bazel run //:record_gradle_module_metadata` in plugin_example if its lock changed — see "Maven lock files" in § 1 |
| dev_tool (unit) | `bazel test //tools/dev_tool/...` (already covered by root `//...`) |
| dev_tool (e2e) | `bazel run //tools/dev_tool:e2e`, see § 2 |
| dev_tool reload paths (`run_command.dart`, `vm_service_client.dart`, `hot_reload/**`, `session.dart`, `reload_pipeline.dart`) | dev_tool unit + e2e **and** manual hot reload **and** hot restart — see "Hot reload / hot restart (manual)" |
| dev_tool native-library checks (`native_libs_watch.dart`, `native_libs_verdict.dart`, `native_libs_fingerprint.dart`, `native_libs_relauncher.dart`, `native_sources.bzl`, `flutter/android_bundle_parts.bzl`, `flutter/macos_bundle_parts.bzl`, `flutter/ios_bundle_parts.bzl`, `flutter/linux_bundle_parts.bzl`, `flutter/windows_bundle_parts.bzl`, `flutter/private/bundle_parts.bzl`, `flutter_native_library`, the `nativeLibs` / `nativeLibContracts` / `nativeLibSources` fields of `_dev_config.json`, `code_asset_libraries.bzl`, and what a moved contract does when a `hot_patch` builder covers the library) | `native_libs_reload_e2e_test.dart` (a reload delivered and a reload withheld) **and** `relaunch_e2e_test.dart` (a restart relaunching) **and** `android_restart_e2e_test.dart` (the same on Android, where a restart must also build no APK) **and** `native_hot_patch_e2e_test.dart`'s last case (an app that runs no build of its own, where only the declared sources can see a native edit) — the halves of one contract, and no unit test can reach any of them |
| Native hot patching (`native_hot_patcher.dart`, `native_hot_patch_tool.dart`, `native_patch_delivery.dart`, `native_image_identity.dart`, `flutter/native_hot_patch.bzl`, `flutter_native_library.hot_patch`, `dev_tool_support/native_patch.dart`) | dev_tool unit **and** `native_hot_patch_e2e_test.dart` (macOS) **and** `relaunch_e2e_test.dart` **and** the manual device check — a native edit patched into the app on the iOS simulator, an iOS device and Android, see "Native hot patch on devices (manual)" |
| Keys (`key_press.dart`, `app.pressKey` in `agent_command.dart`, `pressKeyOverCdp` in `device.dart`, `ext.rules_flutter.pressKey` in `dev_tool_support/agent.dart`) | dev_tool unit **and** `press_key_e2e_test.dart` (macOS, Chrome DDC, Chrome `--wasm`). Changes to the browser channel (`browser_extension_channel.dart`) or the page bridge also need `web_e2e_test.dart`. The framework route on iOS, Android, Linux and Windows has no e2e: check it by hand on the device you changed it for |
| dev_tool app-output forwarding (`app_log.dart`, `app_log_sink.dart`, `cdp_console.dart`, `vm_service_logs.dart`, `device.dart` launch paths) | dev_tool unit + e2e **and** the manual per-platform checks below |
| dev_tool screens and screenshots (`screen.dart`, `devicectl_screens.dart`, `Device.screenshot`, the `screenshot/native` and `screens` endpoints) | dev_tool unit **and** `ios_simulator_e2e_test.dart` and `plugin_example_e2e_test.dart`'s iOS case on the iPhone Duo simulator **and** the manual posture check in "Multi-screen screenshots (manual)" |
| dev_tool iOS device paths (`mdns_vm_service_discovery.dart`, `IOSDevice` in `device.dart`) | dev_tool unit **and** manual hot reload + hot restart on hardware, **wired and wireless** — see "iOS hardware (manual)" |
| New or changed analysis coverage (a target's `srcs` glob or `main`, a new `manual` tag, a new `analysis_options.yaml`) | Root `//...` **and** the probe — see § 1 |
| `flutter_test` compile flags, runfiles or kernel mode (`flutter/private/flutter_test.bzl`, `flutter_program_test.bzl`) | Root `//...`, hello_world `//...` (the `asserts_fire_test` and `widget_creation_test` variants) **and** the by-hand const-violation builds in § "`flutter_test` build modes" |
| Golden comparator (`flutter/private/goldens/`, `flutter_test.bzl` bootstrap) | Root `//...` + codegen `//...` **and** the manual regeneration round trip below. `service.dart` and the integration test runner's golden handling (`tools/dev_tool/lib/integration/golden_*.dart`, the support library's `_golden.dart`) also take `e2e/integration_test`'s golden tests on each platform touched and the round trip in its section |
| Everything | All sections above |

### SDK inputs

An action names the Dart SDK files its tool reads (rules_dart's `SDK_FILE_SETS`,
through `FlutterSdkInfo.sdk_files`), not the SDK's ~1,050 files and 650 MB.
Two tests hold that, and neither replaces the other:

- `//flutter/tests:sdk_inputs_test` reads each action's inputs and fails on any
  SDK file outside the set for its tool. A new action that takes the whole SDK
  fails it.
- `//flutter/tests/sdk_sets:sdk_sets_test` runs the kernel compile, the
  front end, `dart script.dart`, `dart compile js` and
  `dart compile wasm` against real *copies* of exactly those files. A sandboxed
  build cannot show a set that is too small: the sandbox links its inputs, and
  `dart` finds the VM and its snapshots beside the link's target, which is the
  whole SDK. Only a copy (or a remote executor) has nothing else. A green
  sandboxed build is no evidence a set is enough.

A tool that needs another file is a missing entry in the action's set, found
by the second test, not a reason to take the whole SDK.

### Dual-hub package sharing

`e2e/dual_hub` runs two pub hubs over two lock files that agree on `path`
(1.9.1) and differ on `clock` (1.1.2 in `//hub_a`, 1.1.3 in `//hub_b`). Both
locks state the same SDK constraint, so the packages derive the same
`language_version` and the package version is the only thing that differs.

`flutter_pub.from_lock` builds one repository per package for the whole build,
at the highest version any lock records. `hub_a` is behind on `clock`, so both
hubs' `:clock` is the 1.1.3 library, and the build warns that one of the root's
locks was raised.
`bazel test //...` there covers:

- `:bins_test` builds `//agreeing:agreeing_bin` (`path` from both hubs) and
  `//upgraded:upgraded_bin` (`clock` from both), each in a package of its own
  directory. They are binaries because the
  duplicate-record check runs wherever a package_config is assembled
  (`collect_packages`: `dart_binary`, `dart_test`, `package_config`,
  `dart_web_application`, `dart_analysis_options`, the codegen `library_deps`
  path) and `dart_library` itself never dedups, so a `build_test` over a bare
  library proves nothing.
- `:shared_libraries_test` proves the sharing, which a build cannot (two
  repositories at one version build too): a `genquery` of the libraries the
  hubs' `:clock` and `:path` alias, compared with `shared_libraries.golden`,
  one line each for `flutter_pub_lib__clock` and `flutter_pub_lib__path`. Two
  repositories would print four lines and fail.

A raised root lock under `flutter_pub.settings(check_direct_dependencies =
"error")` fails the `pub` extension, so every hub of a workspace holding one
would fail (the toolchain, from the `flutter` extension, and `bazel run
@rules_flutter//flutter/pub`, still work): that case, the command it names
fixing it, the levels below `"error"`, locks of a dependency module, and the
others that fail the extension (sources, registries, digests, two `resolve`
maps, a dependency's `ignore_hooks`), are `tools/dev_tool/test/e2e/pub_versions_e2e_test.dart`, over
generated workspaces. The runner is the toolchain's `dart` running a script that
imports only the Dart libraries, so it reaches no repository of either pub
extension (`bazel cquery 'deps(//flutter/pub)'` lists none from `rules_flutter`'s
or rules_dart's `pub`); the e2e runs the command both with and without a
conflict in rules_dart's own `pub` over the same locks.

The root workspace has the same shape: `dev_tool_deps` (the tools' one lock)
beside whatever a lock of a consumer adds. In a consumer's build it is another
module's lock, so raising it says nothing.

### `flutter_test` build modes

A `flutter_test` has to behave as `flutter test` does on the same code, however
it is built: per-library kernel modules (the default) or one whole-program
compile (`--@rules_dart//dart:modular_kernel=false`), under `-c fastbuild` or
`-c dbg`. `e2e/hello_world` declares each test below once, and
`build_variant_tests` (`build_variant_test.bzl`) adds the other three builds as
`<name>_dbg`, `<name>_whole_program` and `<name>_dbg_whole_program`. They run in
`bazel test //...`.

- `asserts_fire_test` — an `assert` trips in the test's own file, in a
  dependency's library, in an initializer list and in the framework.
- `widget_creation_test` — a widget built in the test knows where
  (`WidgetInspectorService.isWidgetCreationTracked`, `debugIsWidgetLocalCreation`,
  the inspector's `creationLocation`), as under `flutter test`'s
  `--track-widget-creation`.

`//flutter/tests:widget_creation_flag_test` is the analysis half of that, for
`flutter_application`: a debug or profile build compiles with `--track-widget-creation`, a release
build does not. A debug build also records it in `rules_flutter.build_info`
(the dev tool's recompiles pass it too).

`//flutter/tests:flutter_test_runfiles_test` is the analysis half: a test's
runfiles hold nothing from the Dart SDK or the patched SDK, which only a compile
opens.

A constant that breaks a `const` constructor's `assert` must not compile, as
under `flutter test`. The programs that hold one, `//:const_violation_entry`
(the constant in the test's own file) and `//:const_violation_dep` (in a
library it depends on, which in the modular build compiles apart), are
`manual`, since they do not build. These tests run their compile instead:

| Test | What it validates |
|---|---|
| `//:const_violation_entry_test` and `//:const_violation_dep_test`, with `_dbg`, `_whole_program` and `_dbg_whole_program` of each (`build_variant_tests`) | the program's compile fails with `Constant evaluation error` and `This assertion failed with message: Positive: -1 is not positive`, in each of the four builds: the entry compile (`DartEntryKernel`) in the modular build, which fails with the error the library's own module compile recorded, and the whole-program compile (`DartKernel`) without it. Each is a `compile_fail_test` (`tools/e2e_testing/compile_fail_test.bzl`), which runs the target's own action at test time, over its declared inputs, and goes red when the compile succeeds or fails otherwise |

### Golden regeneration (manual)

`e2e/codegen`'s `//:golden_test` and `//:golden_undeclared_test` cover the
comparator under `bazel test`: that one is installed, that a missing golden
fails, that a declared golden is found while an undeclared one is not, and that
diffs reach `bazel-testlogs`. What they cannot cover is `update()`, which writes
to the source tree — a test action has no source tree, and a committed golden
that this host's rendering matches would be a machine-specific artifact that
fails on another OS.

So the write path is checked by hand, on a **scratch** target with a golden path
nothing else uses. Never point it at a committed fixture: regeneration would
rewrite that fixture to this machine's rendering, which is exactly what the
suite avoids committing.

```sh
cd e2e/codegen
# ... add a scratch flutter_test with data = glob(["test/goldens/**"]) and a
# matchesGoldenFile('goldens/scratch_only.png') that nothing else references.

bazel run //:scratch_golden_test -- --update-goldens
#  → "flutter_test: wrote golden <workspace>/e2e/codegen/test/goldens/scratch_only.png"

bazel test //:scratch_golden_test
#  → PASSED. Regenerate-then-compare on the same host is the whole bar; it is
#    NOT evidence the PNG would match on another OS.

bazel test //:scratch_golden_test --test_arg=--update-goldens
#  → FAILED, exit 64, "only works under bazel run".

# Then delete the scratch target, its source, and the generated PNG.
```

### App output forwarding (manual)

Unit tests cover the buffering, filtering and routing; they cannot prove that a
real device's output actually arrives. Each launch path has its own log source
(see README § Dev Tool → App output), so each one needs its own check. The bar
is **"I saw the app's own output in my terminal"**, not "the tests passed".

```sh
# macOS — the reference case. plugin_example prints `plugin_example_results …`
# from a FutureBuilder, i.e. well after the VM service comes up.
cd e2e/plugin_example
flutter_bazel run -t :plugin_macos -d macos
#  → expect the `plugin_example_results …` line, and output that keeps
#    flowing rather than stopping right after the VM-service line.

# Machine mode: app output must travel as app.log and stdout must stay pure.
flutter_bazel run -t :plugin_macos -d macos --machine \
  | tee /tmp/machine.log >/dev/null
grep -c '"event":"app.log"' /tmp/machine.log     # > 0
grep -vc '^\[{' /tmp/machine.log                 # 0 — no raw text on stdout
```

Then per platform: `-d chrome` (both DDC and `--wasm`), `-d ios-simulator`,
`-d ios` on attached hardware, and an Android device or emulator. On Android
also confirm a deliberately thrown Java exception shows up as
`E/AndroidRuntime` — an adb-level `flutter:I *:S` filter silences those
entirely, so their absence looks like normal operation.

Finally, check the pipe-pressure case: run an app that prints continuously well
past 64 KB and confirm it neither stalls nor dies. An unread pipe is the failure
mode that only shows up under sustained logging.

### Native hot patch on devices (manual)

`native_hot_patch_e2e_test.dart` covers macOS. On a device the same reload
also signs the patch (iOS device), copies it through `simctl`'s shared
filesystem, `devicectl` or `adb`, and loads it from the app's own container, and
none of that is reachable from the host test. Check it by hand whenever
`native_patch_delivery.dart`, `dev_tool_support/native_patch.dart` or a device's
`nativePatchDelivery` changes.

The fixture is `e2e/ffi_example`'s patchable `mul`: `native/mul.c`,
`native/mul_body.h`, `native/mul_hot_patch.c`, `c_hot_patch.bzl`,
`tools/c_patch_tool.dart`, and the `mul_*` targets in its `BUILD.bazel`. The
iOS simulator runs it in place:

```sh
cd e2e/ffi_example
flutter_bazel run -t //:ffi_ios -d ios-simulator
```

For Android and a physical iPhone, copy those files and targets into a copy of
`e2e/android_example` or `e2e/ios_example` (`//:app_device`), add
`:mul_native` to the app's `native_deps`, and render `mul(3, 4)` in a widget's
`build` with `DynamicLibrary.open('libmul.so')` (Android) or
`DynamicLibrary.open('mul.framework/mul')` (iOS).

On each: wait for `native_hot_patch_armed` in the log, read the `mul` line,
change `return a * b;` to `return a * b + 1000;`, press `r`, and confirm:

- the reply names `nativePatched` and the line reads 1012 **on screen**
  (`app.getText`, or a screenshot);
- the reload took about a second — measured 0.43 s on the iOS simulator, 0.47 s
  on the Android emulator, 1.2 s on an iPhone 12 Pro over USB (signing and the
  `devicectl` copy), against a relaunch of 16 s and 27 s on the last two;
- undoing the edit and pressing `r` brings back 12 (`nativeReverted`; on the
  Android emulator the fixture answered with a fresh `nativePatched` instead,
  because its rebuilt patch library did not compare equal to the launch copy —
  the value is still 12);
- editing `native/mul.h` withholds the reload, and `R` relaunches.

The shared counter checks state on a device the same way. In `e2e/ffi_example`
the iOS simulator runs it in place; for Android, copy `native/counter*.h`,
`native/counter*.c`, `native/hot_patch_router.h`, `c_hot_patch.bzl`,
`tools/c_patch_tool.dart` and the `counter*`/`count_*_native` targets into the
copy of `e2e/android_example`, whose counter is already served under two ids,
and render `ffi_example`'s `_SharedCounter` (`lib/main.dart`) there, bumping
through the two `@Native` bindings in `lib/shared_counter_ffi.dart`. Tap `bump A` (it reads 3), change `count += 1;` in `native/counter.c` to
`count += 10;`, reload, and tap `bump A` then `bump B`: they read 13 and 23. A
reading of 10 is the patch counting on state of its own.

On an iPhone the patch is signed with the certificate that signed the app, read
out of the installed `.app`. A signing failure answers `nativePatchFailed` with
`codesign`'s own message; an unsigned or ad-hoc signed patch is what the device
refuses with "missing code signature".

### Multi-screen screenshots (manual)

The iPhone Duo simulator has two built-in screens, and the app draws on the one
its posture turns on: LCD when folded, LCD-1 half open or open. Nothing but
DeviceHub's posture buttons changes the posture, so a unit test cannot, and the
recorded `devicectl` output in `test/fixtures/devicectl_displays/` only proves
the rules, not that the real simulator behaves as recorded.

1. Boot the Duo (`xcrun simctl boot <udid>`) and run an example app on it with
   `flutter_bazel run -d ios-simulator` (or the `ios_simulator_e2e_test.dart`
   case, which leaves it folded).
2. Folded: `curl` `/sessions/<appId>/screens` and `screenshot/native`. The list
   has one `active: true` (LCD) and the PNG is the app, 1398x2034.
3. Open DeviceHub (`open -a /Applications/Xcode.app/Contents/Applications/DeviceHub.app`)
   and click the open-posture button. Repeat: `active` has moved to LCD-1 and the
   PNG is the app on LCD-1, 2007x2853. Look at the PNG: a black one means the
   wrong screen.
4. `screenshot/native?screen=LCD` in that posture returns the black, powered-off
   screen: naming a screen is taken at its word.
5. The same on a one-screen simulator (iPhone 17), where `active` is `null` and
   a bare request still captures the app. Quitting DeviceHub shuts the simulator
   down.
6. On an attached iPhone: `screens` lists its own screen and, when the phone
   reports one, a `wireless` display; a bare screenshot is the phone's own screen.

### iOS hardware (manual)

The simulator and a physical device find the VM service by different mechanisms
(log stream vs mDNS advertisement), and a wired device and a wireless one differ
again in how that service is reached, so passing on one proves nothing about the
others. All three need checking whenever `IOSDevice` or
`mdns_vm_service_discovery.dart` changes.

```sh
cd e2e/ios_example   # needs device/BUILD.bazel and the --//:device_profile line in .bazelrc.user — see device.example/

flutter_bazel run -t //:app -d ios-simulator   # log-stream discovery
flutter_bazel run -t //:app_device -d ios      # mDNS (+ iproxy when wired)
```

For each: confirm the app renders, then press `r` (hot reload) and `R` (hot
restart) and confirm the change appears on screen. "The tool printed
`Reloaded`" is not the bar — the UI is.

For the wireless case, unplug the cable with the device paired for network
debugging (Xcode > Window > Devices and Simulators > *Connect via network*) and
confirm `xcrun devicectl list devices` reports `transportType: localNetwork`
before running — the same `-d ios` command then takes the wireless path. A
wireless launch must pass `--vm-service-host=0.0.0.0` and dial the device's own
address; a wired one must do neither. If the device has never been used this way
it will prompt for Local Network permission once — accept it, then re-run.

One launch that renders proves little about the debugger. The JIT breakpoint
can lose a page when threads race (see README "Debugger stops"), so a regression
shows up as some launches freezing, not all of them. After changing how `IOSDevice`
drives lldb, launch once and then relaunch several times with a native edit
before each `R`, and confirm every relaunch renders the new value. Before the fix
about half of a dozen launches froze on an iOS 27 iPhone; with it, 11 of 11
worked.

Then stop the run with Ctrl-C, and once during a launch as well, and confirm
nothing is left: `pgrep -x iproxy`, `pgrep -x lldb` and `pgrep -x devicectl`
print nothing, and `xcrun devicectl device info processes --device <udid>` no
longer lists the app.

Budget the time: starting a debug build under the JIT breakpoint costs more than
a host launch, and the mDNS query only resolves once the app is up. On a recent
iPhone with a healthy Xcode install, resume to first log is **~8 s wired and
~40 s wireless**; a hot restart costs the same again, while a hot reload is
quick on both. A "still waiting" note appears at 45 s.

Minutes, not seconds, means a host fault — most often an incomplete Xcode symbol
copy starving lldb of the on-disk shared cache. The 5-minute wired / 15-minute
wireless budgets in `IOSDevice` are sized for that degraded case on purpose, so
do not read them as estimates of a healthy launch.

If a run does exhaust its budget, read the error — it names the advertisements
it saw and which host sent each, which distinguishes "the app never started"
from "that was the copy running in a simulator on this Mac."

Do not reach for `dns-sd` to decide whether the phone is advertising: it answers
from mDNSResponder, which sees records the tool's raw multicast socket cannot,
and holds records that are not live at all. Over USB, CoreDevice proxies the
device's records in as local-only registrations that no multicast socket can see
by design, so the two channels legitimately disagree. Booted iOS simulators also
leave stale `_dartVmService` registrations on `lo0` with no app running and no
phone attached. Check the interface index on each `Add` line before believing
any of it.

The `/logs` control endpoint is exercised by
`tools/dev_tool/test/e2e/plugin_example_e2e_test.dart`; to check it by hand,
tail it, then poll `nextCursor` twice and confirm the pages neither overlap nor
gap.
