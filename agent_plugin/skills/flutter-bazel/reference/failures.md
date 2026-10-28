# When something fails

Read the `error` text first; it usually names the cause and the fix. This page
is for the cases where the message alone does not tell you what to do next.

To read the tool's own messages and bazel's output from the stderr file (`err`
in the session directory from SKILL.md step 2):

```sh
grep '^{' /tmp/flutter_bazel.Ab12Cd/err | jq -r '.text // .line // empty' | tail -40
```

## The run does not start

| What you see | What it means |
|---|---|
| A `command_failed` record in `err` and the process gone | The run ended. The record's `text` says why; a build error is in the bazel lines above it. Fix and start a new session. |
| An `exited` file and no `command_failed` record | Bazel failed before the tool started, building the tool or loading the workspace. The last lines of `err` say why. Fix and start a new session. |
| `err` still growing, no `app.started` | Still building. A cold build takes minutes. Look at the last bazel lines before deciding it is stuck. |
| `-d … does not say what kind of device it is` | A bare serial or UDID. Use the form the message suggests, such as `-d android:emulator-5554`. |
| `Either the ANDROID_NDK_HOME environment variable or the path attribute of android_ndk_repository must be set` | The workspace declares Android targets, so every build in it, the dev tool's included, needs `ANDROID_HOME` and `ANDROID_NDK_HOME` set, even for `-d macos`. Set them to the installed SDK and NDK and start again. |
| `No booted iOS simulator found` | Boot one: `xcrun simctl boot <udid>`. |
| `The provisioning_profile attribute must be set for device builds` | `-d ios` with a simulator target. Use the device target, or `-d ios-simulator`. |
| A `dev_build_failed` or `initial_compile_failed` record with `recoverable: true` | The app launched but a Dart file did not compile. Fix it and call `app.hotReload`; the session recovers without a restart. |
| A `macos_app_not_activated` warning | The window may not be in front. The app runs; raise its window before taking screenshots. |

## A command is refused

| Status and text | What it means |
|---|---|
| `401` `Invalid or missing token` | The token goes in `?token=`, not in a header. Copy it again from the channel's record in `err`. |
| `404` `unknown appId: null` | `params` has no `appId`. Every `app.*` command needs it. |
| `404` `Unknown command: app.X. This run offers […]` | Not available on this run, or a typo. The message lists what is. Widget commands are missing on `--wasm` and `--profile` web runs. |
| `426` `HTTP upgrade (h2c) is not supported` | Your `curl` tried HTTP/2. Add `--http1.1`. |
| `422` `no widget matching … found` | Nothing in the tree matches. Selectors are exact. Dump the semantics or widget tree and copy the string. If the reply also says the app is not rendering, the tree is stale; see below. |
| `422` `missing selector` / `ambiguous selector` | Give exactly one of `key`, `text`, `tooltip`, `type`, `semanticsLabel`. |
| `422` refusing a tap because the point does not reach the widget | It is scrolled out of view or covered. `app.scrollIntoView`, or close what covers it. |
| `422` `timed out waiting for …` | `app.waitFor` did not see it in time. Check the logs for an exception, then the screen. |
| `422` `… cannot run: …` with a pause reason | The app is stopped at a breakpoint or an unhandled exception, or the run was `--start-paused`. Something has to resume it, usually DevTools. |
| `422` `… did not answer within …s` | The app did not answer. The text says whether it was paused, running with frames off (backgrounded), or the VM service went quiet. |
| `501` on `screenshot/flutter` | Expected: the engine cannot capture under Impeller. Use `screenshot/native`. |
| `500` | The tool itself broke. Worth reporting with the text; retrying rarely helps. |

## Reload and restart

| Reply | What it means |
|---|---|
| `succeeded: false`, compiler diagnostics in `error` | The edit does not compile. The app still runs its old code. Fix and reload. |
| `Hot reload successful (no changes detected)` | The tool saw no edit. Was the file saved, and is it in the target's `srcs` or a dependency? |
| `succeeded: true` with `notShown` | The new code is live but the window is hidden or covered, so nothing has repainted. |
| `Hot reload is still starting up.` | The tool already waited 90 seconds for reload to be set up, and nothing was working on it. Sending it again waits as long for the same answer. Read the last lines of `err` for why reload never came up. |
| The change does not show after a successful reload | The edit is in code a reload does not re-run: `main()`, `initState` of a widget already mounted, a global or static initializer already read. Use `app.restart`. |
| `Hot reload withheld: …` and `nativeLibsStale` | A native library changed in a way a reload cannot deliver. Use `app.restart`, which relaunches the app. |

A failed reload never ends the session. Keep the session; fix the code.

## The app is not drawing

Frames stop when the OS treats the app as hidden: a locked screen on a phone, or
on macOS a window minimized, hidden, or fully covered after it had been in
front. Input still lands, but nothing repaints, reads return the old tree, and
screenshots show what is in front instead. Replies say so with `notRendering`
or `notShown`, and the settle wait answers `skipped`.

Bring the app back in front (on macOS, `open <path to the .app>` or click the
window), then read again. `app.setWindowActive` only changes the framework's
idea of focus; it does not unhide a window.

## Other sessions and Bazel

The tool runs `bazel build` itself when a reload needs one (changed assets,
generated code, native libraries). Bazel runs one command at a time per
workspace, so a `bazel test` or `bazel build` you start in the same workspace
makes such a reload wait for it, and the reverse.

The session ends when the app exits or its window is closed: `app.stop` arrives
on stdout and the tool exits. Start a new session; nothing carries over except
the build cache.
