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
```

### Proving an analysis target is not vacuous

A `dart_analyze_test` that reports clean proves nothing until you have seen it
go red. Nothing checks that its operand stages the files you believe it covers,
so a target covering *nothing* passes exactly as quietly as one covering
everything. Prove coverage by making a deliberate diagnostic appear — a
transient file whose only content is an unused import — and confirming the
target fails **at that file's own path**, then restoring and confirming green.

Which probe discriminates depends on the operand's shape, because
`DartAnalyzableInfo` carries `[main] + srcs`:

* **Operand carries `srcs`** → drop the probe in as a new, *unimported* file.
  Unimported is what makes it proof: an imported one is reached through `main`'s
  own closure, so the target goes red whether or not `srcs` carries it.
* **Operand is `main`-only** — a `main` and no `srcs`
  (`//tools/update_flutter_version`, `//tools/pip_lock_guard:pip_facts_test`) →
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

There is deliberately no `dart_fix` target in this repo. If one is ever added,
**the reviewed diff is the deliverable, not a green build** — never `bazel run`
it and take the result.

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
- **Linux is the odd one out.** macOS and Windows bundle a native helper;
  Linux shells out to `scrot` from `PATH`, so capture fails on a host that
  lacks it. That is the same hermeticity gap as the `zip` dependency below,
  and it is unfixed.

**Upstream ask**: rules_python's bootstrap should read
`RUNFILES_MANIFEST_FILE` rather than only deriving a directory from it. That
is the general fix for any `py_binary` spawned from another binary's runfiles
on Windows.

### Two root tests shell out to host binaries

`//tools/dev_tool:native_libs_fingerprint_test` runs `zip`, resolved from
`PATH`. macOS ships it, and so does GitHub's `ubuntu-latest` runner image, so
this is invisible in both places the suite normally runs — but a plain Ubuntu
cloud image ships only `unzip`, and the test then fails with
`ProcessException: No such file or directory`. `tools/vm/create_linux_vm.dart`
installs `zip` so our own Linux VMs match CI.

The verdict therefore depends on the host image. Making it hermetic means a
`zip` from the build graph, not a PATH lookup.

### Every `dart_format_test` pins `language_version`

`dart_format_test` handed loose `srcs` formats at `latest` — the newest language
version the SDK knows — unless the target says otherwise. `dart format` run by
hand, or by an IDE, instead takes the version from the
`.dart_tool/package_config.json` pub wrote from the package's `sdk:` constraint.
While those two agree the default is invisible; when they diverge the check
demands a style the package's own formatter will never produce, and no edit can
make both happy.

They diverged at Dart 3.13, which rewraps a long `typedef`. Every package here
declares `sdk: ^3.12.0`, so every `dart_format_test` carries
`language_version = "3.12"` to match. Two rules follow:

- A new `dart_format_test` sets `language_version` to its package's `sdk:`
  lower bound. Only a `dart_format_test` with `target =` may leave it off — that
  form takes the version from the `dart_library` instead, and setting both is an
  error.
- Raising a `pubspec.yaml`'s `sdk:` constraint means raising the matching
  `language_version`, and reformatting whatever the new style moves.

### A green sweep does not test the published rules_dart pin

The repo root and all fourteen `e2e/*` workspaces carry a gitignored
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
Flutter Dart is downloaded but only as the `dart_sdk_files` filegroup, not as a
registered toolchain. So Dart source using an API newer than rules_dart's Dart
builds clean locally and fails on CI, whenever the sibling checkout carries a
newer Dart than the published pin.

**Check any new or changed `dart_binary` like this** — it must *compile*, not
merely load:

    mv .bazelrc.user .bazelrc.user.aside
    bazel build --lockfile_mode=error //path/to:target
    mv .bazelrc.user.aside .bazelrc.user

In an `e2e/*` workspace, replace the file with `common --lockfile_mode=off`
rather than removing it: those workspaces' committed `MODULE.bazel.lock` files
are written by an older Bazel, and `--lockfile_mode=error` trips on that
unrelated staleness before it gets anywhere near your change.

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
dart run tools/dev_tool/tool/e2e.dart
```

It forwards its arguments to `dart test`, so scoping works as usual — any
positional argument replaces the default `test/e2e/` path:
```sh
dart run tools/dev_tool/tool/e2e.dart --plain-name="macOS"
dart run tools/dev_tool/tool/e2e.dart test/e2e/agent_e2e_test.dart
```

### Why a runner rather than a bare `dart test`

Because `dart test` has a way of finishing without running the suite that looks
exactly like success. With `package:test` 1.31 — the version `pubspec.lock`
resolves, not the `^1.25.0` the pubspec asks for:

| condition | exit | verdict |
|---|---|---|
| version solving fails (runner too old) | 65 | loud |
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

Zero tests ran; the shell was told everything is fine. Nine of the seventeen
e2e files are `skip:`-gated on `Platform.isMacOS`, so on any other host each of
them "passes" having executed nothing.

`tool/e2e.dart` closes that by reading `dart test`'s machine-readable result
stream instead of its exit code, and failing when the number of tests that
actually *ran* is zero. It also asserts its own `Platform.version` up front and
then runs the suite on `Platform.resolvedExecutable`, so the `dart` that was
checked is necessarily the `dart` that runs — see the next section.

One trap worth naming if you ever parse that stream yourself: a skipped test
reports `result: "success"` in the JSON reporter, for backwards compatibility.
The predicate for "ran and passed" is `result == "success" && !skipped
&& !hidden`.

### The `dart` that runs the e2e suite must be 3.12 or newer

The suite is run by whatever `dart` is first on your `PATH`, and that is not a
property of this repo. `tools/dev_tool` depends on `dwds >=27.1.0`, which
declares `SDK >=3.12.0-307.0.dev`, so an older Dart fails version solving
before a single test runs:

```
Because flutter_bazel_dev_tool depends on dwds >=27.1.0 which requires SDK
version >=3.12.0-307.0.dev, version solving failed.
```

The Flutter toolchain this repo pins ships a new enough one (3.12.1 at the
current pin). Put it first:

```sh
export PATH="$(ls -d "$(bazel info output_base)"/external/*flutter+flutter_*/dart-sdk/bin | head -1):$PATH"
dart --version   # expect 3.12 or newer
```

The glob spans both repo-name shapes: `+flutter+flutter_<platform>` when
rules_flutter is the main module (which it is here), and
`rules_flutter++flutter+flutter_<platform>` from a consumer workspace.

The unit tests are unaffected — Bazel resolves the toolchain for them.

**A too-old Dart does not exit 0.** `dart test` exits **65** on a
version-solving failure. What loses that 65 is the *consumer*: a shell reports the tail of a
pipeline, so `dart test … | tee log` or `| head` leaves `$?` at 0 with
`PIPESTATUS` at `65 0`. A reader who judges by what scrolled past sees no
failing test names and calls it green.

`tool/e2e.dart` removes both halves. It checks its own `Platform.version` before
spawning anything, so the diagnosis is one sentence naming the wrong `dart`:

```
$ PATH="/path/to/an/old/sdk/bin:$PATH" dart run tools/dev_tool/tool/e2e.dart
e2e: this suite needs Dart 3.12 or newer, and you are on 3.11.4.
  the dart that would have run it: …/dart-sdk/bin/dart
```

and it runs the suite on `Platform.resolvedExecutable`, so `PATH` is never
consulted for the run itself and cannot disagree with what was checked.

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

### The Android SDK/NDK variables must be exported too

`plugin_example` registers the NDK toolchain, so **every** test that builds in
that workspace fails without `ANDROID_HOME` and `ANDROID_NDK_HOME` — including
its macOS, iOS and Chrome groups, because toolchain resolution fetches the
repository regardless of the target being built. The failure arrives as a
`Build failed with exit code 1` under half a second, which reads like a broken
dev tool rather than a missing variable:

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/<version>"   # versioned dir, not ndk/
```

§ 3 has the full explanation, including why `.bazelrc` needs `--repo_env` for
these rather than `--action_env`.

Which failure you see depends on how warm the workspace's output base is. A
test using `editableWorkspace` copies the workspace to a fresh temp directory,
so its output base has never been built and the dev tool's *first* bazel
command — the `bazel fetch` that materializes the Flutter toolchain repo before
anything is compiled — is what hits the missing variable; the run reports
`Error in fail: Either the ANDROID_NDK_HOME environment variable or …` together
with the `cd … && bazel fetch …` that produced it. A *warm* in-tree workspace
shows the `Build failed with exit code 1` above instead, because the toolchain
repo is already on disk and the first thing to need the NDK is the build.

### macOS permission prerequisites

Two e2e groups drive the OS, not just the app, and macOS gates both behind
permissions granted to **the terminal (or IDE) that launches the tests** —
neither can be granted programmatically. Grant them in
System Settings → Privacy & Security:

| Permission | Needed by | Symptom when missing |
|---|---|---|
| **Screen Recording** | `macos_e2e_test.dart` and `multi_window_e2e_test.dart` native-screenshot tests (ScreenCaptureKit) | Test **fails**: `No window titled … Available titles: []` — with the permission missing, `SCShareableContent` still returns windows but their titles come back empty. Not every native-screenshot failure is this one; see "The display must be awake for the native-screenshot tests" below, and read the helper's own message, which names the windows it found |
| **Accessibility** | `agent_e2e_test.dart` occlusion test, which minimizes the app window via `AXMinimized` | Test **skips**, after `osascript` refuses in well under a second: `agent_e2e: could not set AXMinimized=true — exit 1: … not allowed assistive access` |
| **Automation** (System Events) | the same test, same `osascript` call | Test **skips**, after the bound expires: `agent_e2e: could not set AXMinimized=true — timed out`. Unlike a refusal this one has no error to return — with the permission undecided, the AppleEvent send simply blocks — so the call is given ten seconds and then killed |

These dependencies are essential rather than incidental: there is no way to
capture a real window without Screen Recording, and no way to get a window off
screen — the state the occlusion regression is about, in which an agent must
still get a bounded answer and the tap must still be delivered — without
OS-level window control. Stubbing either would mean the test no longer
exercises the behaviour it exists to guard.

Note the asymmetry: a missing Screen Recording permission fails loudly, while
missing window-control permissions skip. That skip is what `tool/e2e.dart`
exists to keep visible — it names every skipped test on its own line and refuses
to report a pass for a run in which nothing executed, so the skip cannot be the
whole of a "green" suite. It is still worth reading those lines: a scoped run
that skips its one interesting test is caught, but a full sweep that skips one
of forty-five is a real result with a hole in it.

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
caffeinate -d -u dart run tools/dev_tool/tool/e2e.dart
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
window enumeration, an awake display — so a skip or a failure there can be about
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
| `web_e2e_test.dart` | Any (needs Chrome) | WASM + JS `--screenshot` (CDP), `--machine` screenshot, and what a `--wasm` run tells a client: `app.webLaunchUrl` carries the served address, and the `app.*` agent surface is absent from `/commands` rather than present and refusing |
| `web_define_e2e_test.dart` | Any (needs Chrome) | A `web_defines` value in a `bootstrap_js` template reaches the running page — read off `window` over CDP, with a rendered `screenshot/native` and no service worker beside it. The dev loop must serve the build's bootstrap rather than generate one of its own, or the define works on `bazel build` and does nothing under `-d chrome` |
| `ios_simulator_e2e_test.dart` | macOS | `--screenshot` (simctl), `--machine` screenshot |
| `machine_protocol_e2e_test.dart` | macOS | Protocol lifecycle events, unknown-method error (reload/restart correctness is manual — see "Hot reload / hot restart (manual)") |
| `attach_e2e_test.dart` | macOS | Launch app externally → attach → VM service connects; a hot reload and a hot restart driven over the machine protocol, the restart asserting a `main()`-level edit took effect (attach shares `run`'s reload pipeline, so it gets the orchestrator, asset tracking and codegen refresh). The reload case builds the app with a `--dart-define` attach is never given: the recompile keeps it only because the pipeline reads the defines off the running app. Two cases kill the app instead of driving it, on either side of the pipeline being assembled — both must end the run the same way (exit 0, naming the app as gone), because which side a death lands on is not something the user can see |
| `dart_defines_e2e_test.dart` | macOS | `--dart-define` reaches the app (comma-in-value intact) and survives a hot reload (frontend_server -D replay) |
| `asset_reload_e2e_test.dart` | macOS + Chrome + iOS sim | Editing `assets/message.txt` mid-run reaches the UI over an **explicit `app.hotReload`**: the tracker decides a build is warranted, the bundle is rebuilt, the changed bytes go up the devFS, and the app re-reads them without restarting. The browser case asserts both halves — the module server hands out the new bytes, and `app.getText` reads the repainted label. The iOS-simulator case is the only one that can catch a wrong assets tree: rules_apple's split transition puts the running app's tree in a config no command line can name, and on macOS both trees hold identical bytes, so watching the wrong one is invisible there. **Runs no watcher** — these launch `--machine` without `--watch`, so the watcher never starts and its accept-this-path predicate is never built. Watch-driven asset delivery has no e2e here or anywhere; that predicate's *parts* are unit-covered only (`source_watcher_test.dart` 'a custom filter widens what reaches the pipeline'; the `watches()` cases in `asset_bundle_test.dart`) |
| `start_paused_e2e_test.dart` | macOS + Chrome | `--start-paused` really holds `main()` (asserted from the isolate's own `pauseEvent`, and on web from the framework being absent), an `app.*` command answers instead of hanging, and resuming starts the app |
| `agent_e2e_test.dart` | macOS + Chrome | Full `app.*` agent surface (tap/enterText/getText/…), and that it still works **after `app.restart`** (engine-hook registrant re-registers extensions). The Chrome case takes the other route in — the build stages the agent source and the dev tool's synthetic entrypoint registers it — and issues every command from `app.started` onward, which on web is before the VM service, the extensions or the widget tree exist |
| `reload_after_failure_e2e_test.dart` | macOS | A rejected hot reload does not wedge the resident compiler — the next reload still answers and `app.restart` recovers the session. Runs over `e2e/codegen`, which makes it the only automated check that a **source-assembled** app re-registers the engine's pre-main plugin registrant: the dev compiler feeds that registrant as a `file://` `--source` while a multi-root file system is mounted for the app's own package, and the post-restart `app.waitFor` can only be answered by extensions that registrant brought up. With the registrant suppressed, this test fails |
| `watch_reload_e2e_test.dart` | macOS | The **filesystem watcher** (`--watch`) reload path — one of three tests that deliberately run the watcher — the others are `initial_compile_recovery_e2e_test.dart` and `dev_build_recovery_e2e_test.dart`; every other reload test issues an explicit `app.hotReload`. Two guards. (1) Over `e2e/codegen`: an edit to a **dependency package's** source must key to a `package:` URI through the build-emitted `sourcePackages`, or the watcher drops the path before the pipeline sees it and nothing reloads at all — silently, which is the whole difficulty. With that URI dropped from the watcher's list, the test fails with `Saw 0 app.reloadResult event(s)`. (2) Over `e2e/hello_world`: an edit made the instant `app.started` arrives still reloads, pinning that the watcher is created before the app launches rather than inside the session loop, where the startup window swallows the edit outright. Also asserts `--machine --watch` writes no prose onto the JSON-RPC stdout stream (the `log`-callback regression). **Not** the plugin registrant, deliberately: a hot reload never re-runs the engine's pre-main registrant hook, so that path is reached only by `reload_after_failure_e2e_test.dart`'s restart |
| `initial_compile_recovery_e2e_test.dart` | macOS | A session whose **first** compile failed still reloads. Breaks `hello_world/lib/main.dart` inside the window the initial compile reads it in — on the `package_roots_stabilized` log line, after the launch build and before the compile — then fixes it and requires the watcher-driven reload to land and the app to render the fix. Also pins the reload in between as *answering* with the compiler's diagnostics, and `initial_compile_failed` as carrying `recoverable: true` (JSON mode drops the human `text`, so that field is all a machine client gets). Without the fix, the reload afterwards fails with `Initial compile failed; hot reload is unavailable.` |
| `dev_build_recovery_e2e_test.dart` | macOS | A session whose **launch-time `bazel build`** failed still reloads — one step earlier than the row above, on the wider window. The assembler builds the flutter_application (whose `DefaultInfo` carries the app kernel under `is_debug`) before it starts any compiler, so a source that does not compile fails it; between `run`'s own launch build and this one sits an entire app launch, which is the window a developer saving a typo while the app comes up actually lands in. Breaks `hello_world/lib/main.dart` on the `resolving_toolchain` log line — the last thing logged before the cquery and the build, and **not** the build's own `bazel_command` record, since an edit racing bazel's file read is a coin flip whose lost half lands in the *other* recovery path. Asserts `dev_build_failed` carrying `recoverable: true` (JSON mode drops the human `text`), that it does not name the frontend server, and that the fix reloads and renders. Every edit is derived from the pristine file and asserted to have changed something, so a no-op edit cannot pass |
| `relaunch_e2e_test.dart` | macOS | `app.restart`'s **relaunch** branch: edits `ffi_example/native/mul.c` so the rebuilt dylib differs, then asserts the HTTP control channel survives the process swap and the relaunched app answers on it. The only test that reaches this branch — it needs a real native-library change |
| `plugin_example_e2e_test.dart` | macOS/iOS-sim/Android/Chrome | Plugin apps render non-blank frames; Dart plugin registration survives `app.restart` (macOS); web plugins register in both DDC and `--wasm` dev mode (Chrome) |

### Dev tool screenshot mechanisms

| Device | Debug mode (VM service) | Profile/release (no VM service) |
|--------|------------------------|---------------------------------|
| macOS | bundled ScreenCaptureKit helper (always) | same |
| Linux | `scrot` (always) | same |
| Windows | bundled `dxcam` DXGI helper (always) | same |
| Android (physical) | `adb screencap` (always) | `adb screencap` |
| Android (emulator) | `adb emu screenrecord screenshot` (always) | same |
| iOS Simulator | `simctl io screenshot` (always) | `simctl io screenshot` (always) |
| iOS device | pymobiledevice3 DVT (always) | pymobiledevice3 DVT (always) |
| Chrome/Web | CDP `Page.captureScreenshot` (always) | N/A (web is always debug) |

Note: `_flutter.screenshot` captures only the Flutter widget tree (no OS chrome); the platform tools capture the full screen or window. The three desktop rows name the helper each `Device.screenshot` actually resolves out of runfiles (`tools/{macos,windows}_screenshot/screenshot`, and plain `scrot` on Linux). Windows must use DXGI, not GDI, which captures a Flutter surface as black (§ 4).

Every cell says "always": at the pinned Flutter, **no** device can do `_flutter.screenshot`. Impeller cannot encode a compressed screenshot, and there is no engine screenshot on web at all. They all declare `supportsFlutterScreenshot => false`, so the control channel's `screenshot/flutter` endpoint answers `501` naming `screenshot/native` instead of passing back an engine error that reads as transient.

**Android** answers the RPC with `(-32000) Could not capture image screenshot`. **The three desktop platforms** refuse it since the Flutter 3.47.2 engine, where each embedder's Impeller default flipped on — macOS `FlutterDartProject.enableImpeller` `NO` → `YES`, Linux `FlDartProject.enable_impeller` introduced as `TRUE`, Windows `FlutterWindowsEngine` resolving its `Default` switch to enabled. macOS is measured (`macos_e2e_test.dart` asserts the refusal directly); Linux and Windows are read from those embedder sources, not from a run.

### Stopping a run: signals release what it holds

`SIGTERM` and `SIGINT` (Ctrl-C) run the same shutdown `daemon.shutdown` does —
the app stops, the browser and its temp profile go, the resident compiler
closes — and the tool then exits `143` or `130`. Signal a second time to exit
at once without waiting for the rest.

A leaked profile is not merely wasted bytes — see the `ChromeSession` docs on
why an orphaned browser can serve a screenshot that makes a broken run look
fine.

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
page is up, and the run fails if the page does not come back reporting it.

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
cd e2e/dual_hub && bazel test //...
cd e2e/hello_world && bazel test //...
cd e2e/codegen && bazel test //...
cd e2e/ffi_example && bazel test //...
cd e2e/ffi_plugin_example && bazel test //...
cd e2e/plugin_example && bazel test //...
cd e2e/macos_example && bazel test //...
cd e2e/ios_example && bazel test //...
cd e2e/multi_window_example && bazel test //...
cd e2e/android_example && bazel test //...
cd e2e/web_example && bazel test //...
cd e2e/linux_example && bazel test //...    # Linux-only (target_compatible_with)
cd e2e/windows_example && bazel test //...  # Windows-only (target_compatible_with)
```

**Platform notes:**
- macOS-only targets (macos bundle tests, ios_example) are skipped on other platforms via `target_compatible_with`.
- Linux-only targets (linux bundle tests, linux_example) are skipped on macOS/Windows.
- Windows-only targets (windows_example) are skipped on macOS/Linux.
- `android_example` and `hello_world` (Android targets) require `ANDROID_HOME` to be set to the Android SDK path (e.g. `export ANDROID_HOME=$HOME/Library/Android/sdk` on macOS) and `ANDROID_NDK_HOME` to the NDK path (e.g. `export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/<version>`, the versioned directory, not its `ndk/` parent). Any workspace that registers the NDK toolchain needs both even for non-Android targets, because toolchain resolution fetches the repository. In a `.bazelrc` these need `--repo_env`, not `--action_env` — repository rules never see `--action_env`.
- Android workspaces whose plugins declare `<uses-permission>` in their library manifests (e.g. `record_android`'s RECORD_AUDIO) need `common --merge_android_manifest_permissions` in `.bazelrc`: Bazel's manifest merger strips library permissions by default, while AGP always merges them. The flag matters only for **plugin library** manifests — the app's own debug INTERNET permission comes from `flutter_android_app`'s variant-manifest merge (below) and needs no flag.
- `flutter_android_app` merges `android/app/src/debug/AndroidManifest.xml` (where `flutter create` declares `android.permission.INTERNET`) into `-c dbg` APKs only, mirroring Gradle's variant merge. Debug APKs therefore host the Dart VM service out of the box; release APKs stay permission-free. `plugin_example`'s and `hello_world`'s flutter-create manifests are kept pristine to cover this path; `android_example` declares INTERNET in its hand-written `src/main` manifest and has no variant manifests, covering the no-op path. `verify_android_apk_test` in `plugin_example` is mode-aware: it asserts INTERNET present + `kernel_blob.bin` under `-c dbg`, and INTERNET absent + `libapp.so` in default (release) builds.
- Android builds need no platform flags: `flutter_android_bundle` transitions the application to the Android platform matching its `android_abi`, and packaging hard-fails on any non-ELF native library. `verify_android_apk_test` in `e2e/android_example` asserts every packaged `.so` is ELF with the ABI's machine type, and that every androidx class the engine needs at runtime (including the profileinstaller → concurrent-futures → listenablefuture chain) is defined in the APK's dex — so a missing runtime dep fails in CI without an emulator.
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
- `cross_compile_example` is the one workspace where **`bazel test //...` fails
  by construction**, so it is not in the § 3 sweep list and not in CI. Its
  `.bazelrc` pins `--platforms=linux_x64` for every command, and Bazel then
  finds no test toolchain whose execution platform satisfies a Linux *target*
  platform on a macOS host — an analysis failure that aborts the build rather
  than skipping a test. Verify its two targets separately:
  ```sh
  cd e2e/cross_compile_example
  bazel build :cross_linux                                              # the cross-compiled bundle
  bazel test :app_analyze_test :format_test --platforms=@platforms//host  # lint + format
  ```
  The analysis is host-side and needs no Linux; on a Linux host the pin *is*
  the host platform and the override is unnecessary. `:app_analyze_test` must
  not carry `target_compatible_with = ["@platforms//os:linux"]` to skip itself:
  the pin *satisfies* that constraint, so it only breaks the override.

### What the automated e2e tests cover

| Workspace | Key tests |
|-----------|-----------|
| smoke | Toolchain resolution for all platforms |
| hello_world | Kernel, AOT, application, and per-platform bundle builds; flutter_test |
| codegen | Per-file and aggregate dart_codegen, custom generators, hot-reload-with-codegen |
| ffi_example | Both FFI mechanisms — Native Assets (`add_plugin`, `@Native` asset-id bind) and `native_deps` (`mul_plugin`, conventional-path open) — bundle structure on macOS/Linux plus manual runtime proof on iOS simulator and macOS |
| ffi_plugin_example | FFI plugin build + macOS/Linux bundle structure with `libmultiply.dylib`/`.so` |
| plugin_example | Real pub.dev plugins (`path_provider`, `url_launcher`, `package_info_plus`) plus the hand-written `:greeting_plugin` regression case; per-platform bundle builds; web plugin assertions via the e2e suite; macOS runtime verifier asserting the four plugin-result strings. See **Plugin verification matrix** below. |
| macos_example | Full macOS app build + bundle structure verification (Info.plist, ObjC symbols, framework linkage, AOT dylib, flutter_assets) |
| ios_example | iOS app build (requires Xcode) |
| web_example | Web app builds (dart2wasm + dart2js) with web_assets |
| multi_window_example | Multi-window macOS + multi-scene iOS builds with FlutterEngineGroup; macOS bundle verification |
| android_example | Android APK build (3 approaches: flutter_android_app, Bazel-generated manifest, custom manifest) + APK content verification + web build |
| linux_example | Linux desktop app (2 approaches: flutter_linux_app, Bazel-generated runner) + bundle structure verification |
| windows_example | Windows desktop app (3 approaches: flutter_windows_app, Bazel-generated runner, custom cc_binary) + bundle structure verification |

### Plugin verification matrix

`e2e/plugin_example` exercises real pub.dev plugins — `path_provider` (federated, SwiftPM Apple, **jnigen Android** — path_provider_android ≥ 2.3 calls Java through `package:jni`, whose C support library `libdartjni.so` is built from source by the bundled `ext/jni` overlay and packaged at `lib/<abi>/` — pure-Dart Linux/Windows), `url_launcher` (federated, SwiftPM Apple, Kotlin Android, real C++ Linux/Windows, web Dart), `package_info_plus` (monolithic, every platform including web), `audio_session` (curated `ext/` overlay), and `record_android` 1.5.1 (Android-only federated implementation used without its umbrella — regression case for a plugin that ships `android/src/main/res/` resources referenced as `R.drawable.ic_mic` and declares **no** Gradle dependencies, compiling purely against the embedding's exported androidx classpath) — plus the hand-written `:greeting_plugin` (regression case for pure-Bazel-deps plugins). `lib/main.dart` resolves a string from each plugin and renders + emits them on a single `plugin_example_results …` log line. Each platform's e2e check asserts the line is correct; empty/null/error content fails loudly.

| Assertion | Source | Expected |
|---|---|---|
| `appName=…` | `PackageInfo.fromPlatform()` | `Plugin Example` on macOS/iOS (from `CFBundleName` in the generated Info.plist), `plugin_example` on web (from the auto-generated `version.json`'s `app_name`). Failure means the `package_info_plus` registrant didn't fire on that platform. |
| `documentsPath=…` | `getApplicationDocumentsDirectory().path` (`kIsWeb`-guarded) | `/Users/…` on macOS, `/var/…` on iOS, `/home/…` on Linux, `C:\Users\…` on Windows, `/data/user/0/…` on Android, `web: not supported` on web. |
| `tempPath=…` | `getTemporaryDirectory().path` (`kIsWeb`-guarded) | Absolute path with the platform-appropriate prefix; web shows `web: not supported`. |
| `launchOk=launch ok` | `canLaunchUrl(Uri.parse('https://flutter.dev'))` | Exact `launch ok` on macOS/iOS/Linux/Windows/web. On Android the correct value is `launch denied`: `canLaunchUrl` is subject to package visibility and the app declares no `<queries>` for https VIEW intents (flutter create output ships untouched). Either way the channel responded — an `error:` value means the `url_launcher` registrant didn't fire. |
| `greeting=Hello from GreetingPlugin!` | `//greeting_plugin:greeting_plugin` (regression case) | Exact match. |
| `recordHasPermission=…` | `MethodChannel('com.llfbandit.record/messages')` `create` + `hasPermission(request: false)` | `has=true` on Android (`verify_android_app_test` grants RECORD_AUDIO via `adb shell pm grant` first, which itself fails if the plugin's manifest didn't merge); `not supported` everywhere else. An `error:` value means the `record_android` registrant didn't fire or its resources failed to compile. |

| Platform | Where the assertion runs |
|---|---|
| Web | `plugin_example_e2e_test.dart`, group `Web e2e` (asserts the four strings from the app-output line the run emits). |
| macOS | `:verify_macos_app_test` (manual stdout check) plus the `macOS e2e` group of `tools/dev_tool/test/e2e/plugin_example_e2e_test.dart` (runs `:plugin_macos`, captures a screenshot via the dev_tool's HTTP control channel, asserts the PNG is well-formed and non-blank). Run with `dart run tools/dev_tool/tool/e2e.dart test/e2e/plugin_example_e2e_test.dart --plain-name="macOS"`. |
| iOS Simulator | `iOS Simulator e2e` group of the same file. Boot any iOS simulator first (`xcrun simctl boot <udid>`), then run `dart run tools/dev_tool/tool/e2e.dart … --plain-name="iOS Simulator"`. |
| Android | `:android_bundle_build_test` (build), `:verify_android_apk_test` (APK content: `libdartjni.so` present + ELF/ABI-valid, jni support classes in dex — runs in `bazel test //...`), `:verify_android_app_test` (manual: install on emulator/device, RESUMED + crash-buffer fail-fast, asserts the `plugin_example_results` logcat line reports a real `/data/user/0/…` path from path_provider — proves jnigen plugin registration end to end), plus the `Android e2e` group. Pre-step: bring up a device — either USB-authorize a phone (`adb devices` shows `device`) or boot an emulator (`emulator -avd flutter_test &`). The test resolves the device via `AndroidDeviceProbe.detect()` and runs `:plugin_android` against it; both emulator and connected-device paths must pass. That probe separates two outcomes a single nullable serial would collapse: `adb` running and listing nothing is the one legitimate skip, while an `adb` that cannot be run, exits non-zero, prints output it cannot parse, or lists only devices outside the `device` state (`unauthorized`, `offline`) **fails the test** naming the cause — a broken detector must not report itself as an empty bench. Set `$ANDROID_SERIAL` to choose between an attached phone and a booted emulator; naming one that `adb` does not offer in the `device` state is a failure, not a skip. The dev_tool screenshot goes through the platform — `adb screencap` on a physical device, the emulator console on an emulator (see "Why an emulator is captured through its console") — because Android declares `supportsFlutterScreenshot => false` (Impeller cannot encode one) and the `screenshot/flutter` endpoint refuses with `501`. |
| Linux | `:linux_bundle_build_test` (build only). Visual verification on the GCP VM is manual (see § Linux visual verification). |
| Windows | `:windows_bundle_build_test` (build only). Visual verification on the GCP VM is manual (see § Windows visual verification). |

The dev_tool screenshot is the dispositive end-to-end gate per platform: if Native Assets are broken the app crashes before drawing, and if plugin auto-wiring is broken `MissingPluginException` blanks the screen — both fail the non-blank PNG check (default threshold 4 KB, well above any blank/solid-color PNG).

### Android plugin native source builds (externalNativeBuild)

Some pub packages compile C/C++ for Android via Gradle's
`externalNativeBuild` (CMake/ndk-build) — e.g. `package:jni`, whose
`libdartjni.so` every jnigen-based plugin loads with
`System.loadLibrary("dartjni")`. rules_flutter has no generic translation
for arbitrary Gradle native builds; instead:

1. A curated overlay reproduces the build with `cc_library` +
   `cc_shared_library` (compiled by the registered NDK toolchain via the
   Android bundle's platform transition) and ships the `.so` through
   `flutter_plugin.native_deps` behind a
   `select({"@platforms//os:android": …})`. The library flows through the
   existing transitive native-libs pathway into the bundle's
   `native_libs.jar` at `lib/<abi>/`, subject to the same ELF/ABI machine
   validation as every other packaged library. `ext/jni/1/` is the
   canonical example (note `shared_lib_name` must yield the exact filename
   `System.loadLibrary` resolves).
2. Packages declaring `externalNativeBuild` that no overlay handles fail
   the Android build at load time with a message pointing at
   `flutter.plugin_overlays` — never a silently incomplete APK.
   Non-Android platforms are unaffected (the check lives in the spoke's
   `android/` sub-package, loaded only via the hub's Android aggregator).

### Curated code assets (no authoring needed)

A pub package shipping a build hook is first checked against rules_dart's curated registry (`@rules_dart//dart/ext:registry.bzl`). Where rules_dart provides a Bazel replacement — `sqlite3` today — `flutter.pub()` attaches it to that package automatically, so an app depending on `drift` gets `libsqlite3` without naming it and without an overlay. `e2e/ffi_example` covers this end to end; its `verify_*_runtime_test` targets assert the library actually loaded.

A package with a hook that *nothing* replaces is recorded, and `flutter_application` fails when it reaches one — the alternative is a clean build whose `*.native_assets.json` is one entry short and which dies at runtime on an unresolved `@Native` symbol. Two ways out: write an overlay (below), or declare the hook irrelevant with `flutter.pub(ignore_hooks = ["<pkg>"])` when the package's native code is genuinely unused in this build.

### Native Assets overlay authoring

Pub packages that ship a `hooks/build.dart` Dart-Native-Assets build hook (e.g. `package:objective_c`) and have no curated entry get translated to Bazel-native equivalents under `ext/<pkg>/<major>/BUILD.bazel.tpl`. The template is loaded by `flutter_pub_package` for any spoke whose package name + major version matches.

Template substitutions: `{HUB_NAME}` (the user's `flutter.pub(name = ...)`), `{PKG}` (the package name), `{VERSION}` (the resolved version), `{LANGUAGE_VERSION}` (derived from the package's own `environment.sdk`), and `{DEPS}` (the package's dependencies, as spoke labels, intersected with the lock).

Substitution rewrites comment text too, so a comment that names a placeholder gets rewritten along with the code — write `HUB_NAME`, not `{HUB_NAME}`, in prose.

Two of those are mandatory, and the repo rule fails the fetch if a template writes the value out by hand instead:

* `{LANGUAGE_VERSION}` — the package's `environment.sdk` is the only place its language version is declared.
* `{DEPS}` — the package's pubspec is the only place its dependencies are declared, and deriving them is also what keeps a template from naming a repo the hub never created.

Both exist because a template directory serves a whole version range, so a hand-written copy drifts on the package's next release with no build error to catch it. `objective_c` 9.5.0 is the worked example: its hook stopped using `native_toolchain_c`, so the package dropped it from `dependencies`, the lock stopped carrying it, the hub stopped creating the spoke — and `ext/objective_c/9/`, which serves all of 9.x, was still asking for `@<hub>__native_toolchain_c`. Consumers got an unknown-repo error naming neither `objective_c` nor the overlay.

For the same reason, prefer a `glob()` over a named source file when the file's existence varies across the range the directory serves — `test/util.c` in the `objective_c` overlay, which 9.5.0 deleted.

Procedure:

1. Locate the package's hook source under `~/Library/Caches/bazel/_bazel_<user>/.../external/<hub>__<pkg>/hook/build.dart`. Read what it builds (file glob, link mode, target platforms, copts).
2. Reproduce the build with `cc_shared_library` + `objc_library` (Apple) / `cc_library` (other platforms). Set `shared_lib_name` to something *different* from the bundle filename — `flutter_native_asset` symlinks the cc output to `<bundle_filename>` in its own package, and matching names collide.
3. Wrap the output in `flutter_native_asset(name = "<pkg>_native_asset", asset_id = "package:<pkg>/<basename>", link_mode = "dynamic_loading_bundle", library = ":_<pkg>_dylib", bundle_filename = "<basename>")`, constrained to the supported platforms with `target_compatible_with`. Platforms that need a different `bundle_filename` (`lib<x>.so`, `<x>.dll`) get their own target; platforms that agree on every attribute share one.
4. Hang a `flutter_plugin(name = "<pkg>", platforms = [], native_assets = select({...}))` over them. Even though the package is "pure Dart" from pub's perspective, the empty-`platforms` plugin shape is what carries the native-assets entry into `FlutterInfo` for the application's manifest. The `select()` is what decides which asset targets an application sees: list exactly the ones that belong to the platform being built, and `//conditions:default: []` for the rest. Two targets claiming the same `asset_id` in one build fail analysis.
5. Drop the template at `ext/<pkg>/<major>/BUILD.bazel.tpl`. The next `bazel run @rules_flutter//flutter:pub -- get` + Bazel build picks it up automatically.

If the build fails at runtime with `Couldn't resolve native function "<symbol>"`, the most common cause is the `cc_shared_library`'s `install_name` not matching the asset id's basename — set `user_link_flags = ["-Wl,-install_name,@rpath/<basename>"]` on Apple targets. See `ext/objective_c/9/BUILD.bazel.tpl` for the canonical example.

## 4. Manual tests

These require a GUI environment and are skipped by `bazel test //...`.

### macOS runtime smoke test

Launches the app, polls for a window, and verifies dimensions > 100x100. Catches window sizing bugs (e.g. the 1x32 collapsed-window bug).

```sh
cd e2e/macos_example
bazel test :verify_macos_app_test --test_tag_filters= --strategy=TestRunner=standalone
```

**When to run:** After any change to macOS runner code (`flutter/private/runners/macos/`).

### FFI runtime tests (iOS simulator, macOS, Linux, Windows)

Behavioral verification that both native-library mechanisms work at runtime:
`add()` binds via `@Native` asset-id resolution (`flutter_native_asset` →
`--native-assets` kernel manifest), `mul()` raw-opens its conventional path
(`native_deps`). The app writes
`ffi_example_result add(3,4)=7 mul(3,4)=12` to its temp dir; the tests read
it back (via `simctl get_app_container` on iOS).

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
(`flutter_native_assets.bzl`, `flutter_native_asset.bzl`), native-library
bundling (`flutter_ios_native_frameworks`, `flutter_macos_native_libs`), or
kernel compilation flags.

### macOS visual verification

Launches the app binary directly, captures stdout/stderr, takes a screenshot, and prints structured JSON output. The screenshot file can be opened for visual verification.

```sh
cd e2e/macos_example && bazel build :app
# Extract the app
mkdir -p /tmp/macos_app && unzip -oq bazel-bin/app.zip -d /tmp/macos_app
# Run the diagnostic
dart run ../../e2e/_macos_test/verify_macos_app.dart /tmp/macos_app/app.app "Flutter App"
```

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
3. **Hot restart**: edit again → `app.restart` → screenshot shows the
   change. Hot restart re-runs `main()` (engine `runInView`), so it must also
   reflect a change made *inside `main()`* (e.g. a value computed there) that a
   hot reload deliberately does NOT — verify a `main()`-level edit too.
4. **Agent surface after restart**: after `app.restart`, `app.getText` must
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
  string** (`flutter/private/agent_extensions/agent.dart`), not a substring
  search: wait for `{name: Grace Hopper, age: 45}`, not `Grace Hopper`. A
  `waitFor` that finds nothing answers with a top-level `error` and **no**
  `result`, so any check shaped `response['result']?['error'] == null` reads a
  miss as a pass.
- **Hot restart over codegen**: edit the `User(...)` in `main()` → `app.restart` →
  the change renders and all generated code (app + deps) still resolves.
- **Dependency source edit**: edit a dep's hand-written source (e.g.
  `dep_part/lib/settings.dart`) → reload → renders. This exercises the
  `PackageUriResolver`, which keys every first-party source (app **and** deps) by its
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
`tools/dev_tool/test/e2e/watch_reload_e2e_test.dart` (run via `tool/e2e.dart`). It
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
app package + both dep packages must render. This verifies the release `.pkgsrcs`
assembly + gen_snapshot path co-locates and compiles all generated code at runtime —
distinct from the dev multi-root path, and from the `build_test`s which only compile.

Tests the full dev tool hot reload cycle: launch app, take screenshot, edit source, hot reload, take screenshot, verify the change rendered, revert source.

```sh
cd e2e/macos_example

# 1. Start the dev tool with --machine for structured JSON events on stdout
dart run ../../tools/dev_tool/bin/flutter_bazel.dart run \
  -t :app -d macos --machine &

# 2. Read stdout for the app.started event (contains appId) and
#    http_control_channel event on stderr. Its `endpoints` each carry a `url`
#    that already includes the token; the token is a query parameter, never an
#    Authorization header.

# 3. Take a screenshot
curl -s "http://localhost:PORT/sessions/APPID/screenshot/flutter?token=TOKEN" \
  -o /tmp/before.png

# 4. Edit lib/main.dart (change visible text)

# 5. Hot reload
curl -s -X POST "http://localhost:PORT/command?token=TOKEN" \
  -H "Content-Type: application/json" -d '{"method": "app.hotReload"}'

# 6. Take another screenshot (should show the changed text)
curl -s "http://localhost:PORT/sessions/APPID/screenshot/flutter?token=TOKEN" \
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

An app package that mixes hand-written and generated sources is assembled into a
`*.pkgsrcs` tree artifact (rules_dart's `assemble_source_dir`, via bazel-lib's
`copy_to_directory`) so the Dart toolchain sees one real `rootUri`. That staged
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
The two build-emitted package configs give the mapping with no guessing:
`app.package_config.json` carries each package's staged `*.pkgsrcs` root, and
`app.dev_package_config.json` carries the same package's source root as
`org-dartlang-app:///<dir>`.

```sh
cd e2e/codegen

# Loud variant — the error names the exact staged path; diff that one file.
diff dep_part/lib/settings.dart \
  bazel-out/darwin_arm64-dbg/bin/app.dep_part.pkgsrcs/lib/settings.dart

# Quiet variant — nothing names a configuration, so check every staged copy.
for t in bazel-out/*/bin/app.dep_part.pkgsrcs; do
  diff -q dep_part/lib/settings.dart "$t/lib/settings.dart"
done
```

Any difference while `git status` is clean is this bug. Confirm with `--explain`:
in the poisoned state the copy action does not appear in the log at all, because it
is an action-cache hit — only the downstream compile re-runs, and fails identically
every time.

```sh
bazel build :app -c dbg --explain=/tmp/explain.log --verbose_explanations
grep pkgsrcs /tmp/explain.log   # poisoned: no output
```

**Fix — delete that one tree and rebuild.**

```sh
TREE=bazel-out/darwin_arm64-dbg/bin/app.dep_part.pkgsrcs   # the one the diff flagged
chmod -R u+w "$TREE" && rm -rf "$TREE"
bazel build :app -c dbg
```

`--explain` then reports `Executing action 'Copying files to directory
app.dep_part.pkgsrcs': action changed since cached execution.` **Do not reach for
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

### Linux visual verification (GCP VM)

Cross-compile a Linux debug bundle from macOS, deploy to a GCP VM, and verify the Flutter UI renders.

```sh
# 1. Cross-compile (requires LLVM toolchain — use cross_compile_example)
cd e2e/cross_compile_example && bazel build :cross_linux

# 2. Create a Linux VM
dart run tools/vm/create_linux_vm.dart flutter-linux-test

# 3. Deploy and verify
dart run tools/vm/deploy_bundle.dart flutter-linux-test e2e/cross_compile_example/bazel-bin/cross_linux

# 4. Clean up
gcloud compute instances delete flutter-linux-test --quiet
```

**When to run:** After any change to Linux runner code, engine selection, or bundle assembly.

**What the check actually asserts:** that a window *titled "Flutter"* appears
(not merely that some window exists — the Xvfb root window always does), and
that a capture of it differs from the blank display measured before launch. It
fails loudly if the runner dies on a missing library, or maps a window and
paints nothing.

**Three things the VM needs, all handled by `create_linux_vm.dart` and
`verify_linux_app.dart`** — each fails silently when missing:
- `libgtk-3-0` is **not** in the Ubuntu cloud image; without it the runner exits
  with `libgtk-3.so.0: cannot open shared object file`.
- Flutter's GTK embedder renders through EGL, which ignores
  `LIBGL_ALWAYS_SOFTWARE` and tries DRI3 — unavailable under Xvfb.
  `GALLIUM_DRIVER=llvmpipe` is what actually selects software rendering; without
  it the window appears and stays empty.
- `scrot` refuses to replace an existing file unless given `--overwrite`, so a
  polled screenshot silently keeps reporting the first frame it ever captured.

### Windows visual verification (GCP VM)

Build natively on a Windows VM, take a DXGI screenshot — fully automated over SSH (no RDP needed).

The create script sets up auto-logon via sysprep specialize, so an interactive console session exists at boot. PsExec launches apps in that session and `dxcam` captures DXGI screenshots.

```sh
# 1. Create a Windows VM (auto-logon, MSVC, Python, dxcam, PsExec)
dart run tools/vm/create_windows_vm.dart flutter-windows-test

# 2. Deploy bundle and verify (automated — screenshot downloads locally)
dart run tools/vm/deploy_bundle.dart flutter-windows-test <bundle_path> --windows

# 3. Clean up
gcloud compute instances delete flutter-windows-test --quiet
```

**Key details:**
- `--enable-display-device` is mandatory — provides virtual GPU for D3D
- GDI `CopyFromScreen` captures D3D/Flutter surfaces as **black** — must use DXGI (`dxcam`)
- Console resolution is 800x600
- Files are written to `C:\temp\` (shared), not user profile dirs

**When to run:** After any change to Windows runner code, engine selection, or bundle assembly.

## 5. Web rendering verification

Web rendering is verified from Dart, through the dev tool, as part of the e2e
suite. There is no browser-test toolchain in this repo and no `npx` step.

| Check | Where | What it proves |
|-------|-------|----------------|
| Render | `web_smoke_e2e_test.dart` | Reads text back out of a keyed widget over the agent surface. Answering proves the framework built the tree *and* resolved the asset bundle behind it — a bundle that boots, answers the VM service and paints nothing fails here. |
| Plugins on web | `plugin_example_e2e_test.dart` (`Web e2e`) | The four `plugin_example_results` strings on web, where each plugin takes a different path than on desktop (`package_info_plus` reads a generated JS manifest, `path_provider` has no web implementation, `url_launcher` goes through `window.open`). |
| Templating / defines | `custom_boot/test/verify_templating_test.dart` | Substitution outcomes in the built bytes: web defines resolved, kept placeholders survived, `buildConfig` emitted, no `{{` left. |
| Local CanvasKit | `web_example/test/verify_compiler_flags_test.dart` | `useLocalCanvasKit` is declared, so the renderer loads from the app origin rather than gstatic.com — the regression a strict `script-src 'self'` exposes. |

Running the web checks needs a `dart` of 3.12+ on `PATH` (see § 2) and, for
`plugin_example`, `ANDROID_HOME` / `ANDROID_NDK_HOME` — its workspace-level
analysis loads the Android repo rule whichever target you build.

```sh
dart run tools/dev_tool/tool/e2e.dart test/e2e/web_smoke_e2e_test.dart
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
| `e2e/_windows_test/dxgi_screenshot.py` | Launch app + DXGI screenshot (captures D3D/Flutter) | `python <script> <exe_path> <output.png> [wait_s]` |
| `e2e/_compare/compare_artifacts.dart` | Diff flutter build vs bazel build outputs | `dart run <script> <flutter_dir> <bazel_dir>` |
| `tools/dev_tool/tool/concurrent_sessions.dart` | Two `flutter_bazel run` sessions in one workspace vs one (control) | `dart run <script> [solo\|pair] [edits]` |

`concurrent_sessions.dart` targets a race that does not reliably reproduce.
Read a passing `pair` as "the collision did not happen in this run", not as "it
cannot": the race is timing-dependent and the generated-sources half of it is
unfixed. Run `solo` alongside it as the control. Needs the hermetic Dart (§ 2) — the
script's own package requires ≥ 3.12.

## Quick reference: what to test when

| Change area | Minimum test scope |
|-------------|-------------------|
| Starlark rules (`flutter/*.bzl`) | Root `//...` + all e2e workspaces |
| macOS runner (`flutter/private/runners/macos/`) | macos_example `//...` + manual runtime test |
| Linux runner / bundle (`flutter/private/*linux*`) | linux_example, cross_compile_example, GCP VM visual test |
| Windows runner / bundle (`flutter/private/*windows*`) | windows_example (on Windows), GCP VM visual test |
| Desktop engine selection (debug/release) | cross_compile_example `bazel build :cross_linux` + verify on VM |
| Dart compilation / AOT | hello_world, ffi_example, macos_example |
| Asset bundling | hello_world, plugin_example |
| Web support | `web_smoke_e2e_test.dart` (render) + `plugin_example_e2e_test.dart` (plugins on web) |
| FFI / native deps / native assets | ffi_example (incl. manual iOS-sim + macOS runtime tests), ffi_plugin_example |
| Plugins | plugin_example, ffi_plugin_example |
| Toolchain / SDK | smoke, hello_world |
| dev_tool (unit) | `bazel test //tools/dev_tool/...` (already covered by root `//...`) |
| dev_tool (e2e) | `dart run tools/dev_tool/tool/e2e.dart` — needs a Dart ≥3.12 on `PATH`, see § 2 |
| dev_tool reload paths (`run_command.dart`, `vm_service_client.dart`, `hot_reload/**`, `session.dart`) | dev_tool unit + e2e **and** manual hot reload **and** hot restart — see "Hot reload / hot restart (manual)" |
| dev_tool app-output forwarding (`app_log.dart`, `app_log_sink.dart`, `cdp_console.dart`, `vm_service_logs.dart`, `device.dart` launch paths) | dev_tool unit + e2e **and** the manual per-platform checks below |
| dev_tool iOS device paths (`mdns_vm_service_discovery.dart`, `IOSDevice` in `device.dart`) | dev_tool unit **and** manual hot reload + hot restart on hardware, **wired and wireless** — see "iOS hardware (manual)" |
| New or changed `dart_analyze_test` coverage (an operand's `srcs` glob or `main`) | Root `//...` **and** the non-vacuity probe — see § 1 |
| Golden comparator (`flutter/private/goldens/`, `flutter_test.bzl` bootstrap) | Root `//...` + codegen `//...` **and** the manual regeneration round trip below |
| Everything | All sections above |

### Dual-hub package skew (manual)

`e2e/dual_hub` runs two pub hubs over two lock files that agree on `path`
(1.9.1) and disagree on `clock` (1.1.2 in `//hub_a`, 1.1.3 in `//hub_b`). Both
locks state the same SDK constraint, so the spokes derive the same
`language_version` and the package version is the only thing that differs.

`bazel test //...` there covers the agreeing half — `:agreeing_bin` collects
`path` from both hubs and must build. It is a binary because the check runs
wherever a package_config is assembled — `collect_packages` (`dart_binary`,
`dart_test`, `package_config`, `dart_web_application`,
`dart_analysis_options`, the codegen `library_deps` path) and directly on a
library's transitive packages in `dart_analyze` and `dart_fix`. `dart_library`
itself never reaches it: it accumulates records into depsets and never dedups,
so a `build_test` over a bare library proves nothing. A `dart_analyze_test`
pointed at the library *does* fire it, so that is the cheaper second assertion
if one is ever wanted.

The disagreeing half is `manual` because its contract is to fail analysis,
which no target in `bazel test //...` can have:

```sh
cd e2e/dual_hub
bazel build :disagreeing_bin   # must FAIL
```

The build must fail, naming both hubs and both versions:

```
Error in fail: Package "clock" is supplied more than once with different versions:
  - 1.1.2 (../rules_flutter++flutter+hub_a__clock)
  - 1.1.3 (../rules_flutter++flutter+hub_b__clock)
```

A build that succeeds instead, emitting a `package_config.json` that names
exactly one `clock` with no diagnostic, is the silent substitution this
workspace exists to catch: the binary compiles against one version's source tree
while the other lock pins the other.

`:disagreeing_bin` stays `manual`: a target whose contract is to fail analysis
cannot sit in `bazel test //...`. `:agreeing_bin` is the automated half and
must keep passing — two records for `path` at the same 1.9.1 agree, so the
guard lets them merge.

The root workspace already has the ingredients — `dev_tool_deps` and
`gen_l10n_deps` share eleven package names and disagree on `clock` and `meta` —
but no target reaches both, so nothing there observes it. Do not add one: the
edge that would make it observable is the bug.

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

### iOS hardware (manual)

The simulator and a physical device find the VM service by different mechanisms
(log stream vs mDNS advertisement), and a wired device and a wireless one differ
again in how that service is reached, so passing on one proves nothing about the
others. All three need checking whenever `IOSDevice` or
`mdns_vm_service_discovery.dart` changes.

```sh
cd e2e/ios_example   # needs device/BUILD.bazel — see device.example/

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
