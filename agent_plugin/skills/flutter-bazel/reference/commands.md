# Control channel reference

Requests are written as the path plus the body. Send them as SKILL.md step 3
shows, with your run's URL, token and `appId` in place of the ones here:

```sh
curl -s 'http://localhost:53817/command?token=9f2c…e1' \
  -d '{"method":"app.tap","params":{"appId":"___my_app_macos_macOS","key":"increment"}}'
```

## Endpoints

| Request | What it does |
|---|---|
| `POST /command?token=…` | Run a command. Body `{"method":"app.X","params":{"appId":"…",…}}`. Answers `{"result":{…}}` or `{"error":"…"}`. |
| `GET /commands?token=…` | What this run accepts now: `{"protocolVersion":3,"commands":[{"name","longRunning"}]}`. |
| `GET /sessions/<appId>/screenshot/native?token=…` | PNG of the app as the platform sees it. Add `&settle=false` to skip the idle wait, `&window=<title>` on macOS for one window. |
| `GET /sessions/<appId>/logs?token=…` | The app's console output. See "Logs" below. |
| `GET /sessions/<appId>/screenshot/flutter?token=…` | Engine screenshot. `501` on every platform at the pinned Flutter (Impeller); use `native`. |

The channel's stderr record also lists each endpoint with a ready-made `url`,
token included: `jq -r '.endpoints[].url'` on that line. The per-app ones carry
a literal `{appId}` to replace.

Plain HTTP/1.1. If your `curl` tries HTTP/2, add `--http1.1`.

Commands run one at a time. A command that waits (a long `timeoutMs`, a settle
on an app that never goes idle) holds up every command behind it, screenshots
included.

## Seeing the UI

### app.dumpSemanticsTree

```
POST /command  {"method":"app.dumpSemanticsTree","params":{"appId":"___my_app_macos_macOS"}}
→ {"result":{"text":"view 0 800x600 @1x\n#3 scopesRoute @400,300 800x600\n  #30 header \"Hello World\" …"}}
```

Takes only `appId`. Read it with `jq -r .result.text`:

```
view 0 800x600 @1x
#3 scopesRoute @400,300 800x600
  #30 header "Hello World" @400,28 120x28
  #6 "count: 0" @400,254 56x20
  #7 button "Increment (agent)" [tap] @400,280 171x32
  #8 textField [tap] @400,320 200x48
  #27 [scrollUp] @400,444 200x80
    #13 "item 0" @400,416 200x24
    #17 hidden "item 4"
  #31 button tooltip="Increment" [tap] @756,556 56x56
```

- A `view <id> <width>x<height> @<ratio>x` line starts each view.
- A node line is `#<id>`, role and flags, strings (`"label"`, `value=`,
  `hint=`, `tooltip=`, `id=` for a `Semantics.identifier`), actions in
  brackets, then `@x,y` (the centre, in logical pixels) and the size.
- Indentation is nesting; order is the order a screen reader walks.
- Flags are Flutter's names without `is`: `button`, `textField`, `header`,
  `obscured`, `readOnly`, `focused`, `checked`/`unchecked`/`mixed`, `on`/`off`,
  `selected`, `expanded`/`collapsed`, `disabled`.
- `hidden` means scrolled out of view. It has no point: scroll it into view,
  then dump again.
- Nodes that only group their children are left out, and so are nodes merged
  into their parent, whose text and actions show on the parent's line.

To act on a node, pass its point to `app.tap` (or `longPress`, `doubleTap`,
`drag`) as `"x"` and `"y"`. A labelled node can also be named with the
`semanticsLabel` selector. To type, tap the field and send `app.enterText`
with no selector. Node ids last only as long as the widget behind them; they
are not selectors.

### app.dumpWidgetTree

```
POST /command  {"method":"app.dumpWidgetTree","params":{"appId":"___my_app_macos_macOS"}}
```

The Flutter inspector's full widget tree (not the summary tree), as nested JSON
with `description`, `children`, and for text widgets a `textPreview`. It is
large even for a small app (142 KB, where the semantics dump is 1 KB): save the reply to a file (`-o tree.json`) and search
it, for example `jq -r '.. | .description? // empty' tree.json`, rather than
reading it whole. Works against any debug Flutter app.

### app.getText, app.getRect

```
POST /command  {"method":"app.getText","params":{"appId":"___my_app_macos_macOS","key":"agent_test_label"}}
→ {"result":{"text":"count: 0","texts":["count: 0"]}}
POST /command  {"method":"app.getRect","params":{"appId":"___my_app_macos_macOS","key":"agent_test_button"}}
→ {"result":{"x":…,"y":…,"width":…,"height":…}}
```

`getText` returns the first text under the match, in reading order, and all of
them in `texts`: a `Text` (including `Text.rich`), `RichText`, or a text field's
contents. Rects are in logical pixels.

## Selectors

Widget commands take exactly one of these. Zero, or two, is refused.

| Param | Matches |
|---|---|
| `key` | A widget whose `ValueKey` value equals the string. |
| `text` | A widget whose displayed text equals the string exactly. |
| `tooltip` | A `Tooltip` whose `message` equals the string. |
| `type` | A widget whose runtime type name equals the string, such as `ElevatedButton`. |
| `semanticsLabel` | A widget whose semantics label equals the string. |

The first match wins. When several widgets share a text, use a `key` or `type`
instead. `enterText` cannot take `text` as a selector, because `text` is what it
types.

`tap`, `longPress`, `doubleTap` and `drag` refuse when the point they would
press does not reach the widget: off screen in a scroll view, or under a
dialog. The error says which. `app.scrollIntoView` first, or pass
`"requireHit":"false"` if you mean to press there anyway.

## Input commands

| Method | Params besides the selector | Reply |
|---|---|---|
| `app.tap` | `pointer: "mouse"`, or `x`,`y` instead of a selector | `tappedAt` |
| `app.longPress` | `durationMs` (500) | `tappedAt` |
| `app.doubleTap` | | `tappedAt` |
| `app.drag` | `dx`, `dy` (required), `durationMs` (200) | |
| `app.enterText` | `text` (required); no selector types into the focused field | `enteredText`, `into` |
| `app.pressKey` | `key` (required); no selector, acts on focus | `route`, `handled`, `sent`, `textInput` |
| `app.scrollIntoView` | `scrollableKey`, `dx`, `dy` (-50), `durationMs`, `maxIterations` (40) | `iterations`, `reachable` |
| `app.pageBack` | no selector; pops the nearest `Navigator` | `popped` |
| `app.hover` | selector, or `x`,`y` | `hoveredAt`, `cursor` |
| `app.hoverExit` | | `exited`, `cursorRestored` |
| `app.setWindowActive` | `active: "true"` or `"false"` | `active`, `lifecycleState` |

```
POST /command  {"method":"app.enterText","params":{"appId":"___my_app_macos_macOS","key":"agent_test_field","text":"hi"}}
→ {"result":{"enteredText":"hi","into":"ValueKey(agent_test_field)","settled":"yes"}}
POST /command  {"method":"app.drag","params":{"appId":"___my_app_macos_macOS","key":"agent_gesture_box","dx":120,"dy":0}}
POST /command  {"method":"app.scrollIntoView","params":{"appId":"___my_app_macos_macOS","key":"agent_test_list_item_40","scrollableKey":"agent_test_list"}}
POST /command  {"method":"app.pressKey","params":{"appId":"___my_app_macos_macOS","key":"Meta+A"}}
```

`app.pressKey` names keys as Playwright does: a character (`a`, `A`, `!`), a key
or code name (`Enter`, `Tab`, `Backspace`, `ArrowDown`, `Escape`, `KeyA`), and
modifiers joined with `+` (`Control+K`, `Shift+Tab`, `ControlOrMeta+S`). Only
modifiers can be held: one command per key. On native platforms the key is
simulated inside the framework (`"route":"framework"`); it reaches shortcuts,
focus and text editing, not the OS or an input method. In Chrome it is real
browser input (`"route":"browser"`).

`app.enterText` with a selector focuses the field itself; no tap first.

### Settling

Every input command, and the screenshot endpoints, wait for the app to go idle
first (no frame scheduled, as `pumpAndSettle` means it), bounded by `timeoutMs`
(default 10000). The reply carries `settled`:

- `yes`: idle; the next read sees the result.
- `no`: the wait ran out. The input was delivered; do not resend it.
  `settleDetail` gives the number of animations still running.
- `skipped`: you passed `"settle":"false"`, or the app is backgrounded.

An app with an endless animation never settles, and every command spends its
whole timeout. Pass `"settle":"false"`, then wait for the state you expect with
`app.waitFor`. `settle` takes only `"true"` or `"false"`.

A reply with `notRendering` means the app is not drawing (window hidden or
covered, screen locked). The input landed, but nothing on screen or in a read
reflects it until the app is visible.

## Waiting

```
POST /command  {"method":"app.waitFor","params":{"appId":"___my_app_macos_macOS","text":"count: 1","timeoutMs":5000}}
POST /command  {"method":"app.waitForAbsent","params":{"appId":"___my_app_macos_macOS","type":"CircularProgressIndicator"}}
POST /command  {"method":"app.settle","params":{"appId":"___my_app_macos_macOS"}}
```

`waitFor` answers with the widget's rect once it is in the tree, `waitForAbsent`
with `{}` once it is gone; both default to 5000 ms and answer `422` "timed out waiting
for …" otherwise. `app.settle` is the idle wait on its own. Commands sent before
the first frame wait for it, so you do not need to poll for readiness after
`app.started`.

## Reload, restart, stop

| Method | Params | Notes |
|---|---|---|
| `app.hotReload` | `appId` (optional: omit for every app) | Long-running. |
| `app.restart` | `appId`; `fullRestart: false` makes it a reload | Long-running. Re-runs `main()`. |
| `app.stop` | `appId` (required) | Stops one app; the tool keeps running other devices. |
| `daemon.shutdown` | none | Ends the run: every app, the compiler, the browser, the tool. |

Reply fields:

- `succeeded`: whether the edit is live.
- `runningCode`: `updated` or `unchanged`, what the app is now running.
- `message`: one sentence, safe to quote in a report.
- `filesRecompiled`, `isEmpty`: what was compiled; `isEmpty: true` and
  "(no changes detected)" mean the tool saw no edit. Check the file was saved
  and is part of the target.
- `error`: compile diagnostics when `succeeded` is false.
- `notShown`: per app, why the new code is not on screen yet (window hidden).
- `relaunched`, `nativeLibsChanged`, `launch`, `ready`: a restart that replaced
  the process because a native library changed. The log cursor restarts at 0.
- `nativeLibsStale`, `nativePatched`, `nativeReverted`: native code across a
  reload; the `message` says whether a restart is needed.

## Logs

```
GET /sessions/___my_app_macos_macOS/logs?token=…              last 200 lines
GET /sessions/___my_app_macos_macOS/logs?token=…&since=-50    last 50
GET /sessions/___my_app_macos_macOS/logs?token=…&since=0      everything buffered
GET /sessions/___my_app_macos_macOS/logs?token=…&since=813    from a previous nextCursor
→ {"lines":[{"index":812,"text":"flutter: …","error":false}],
   "nextCursor":813,"launch":1,"missed":0,"dropped":0,"closed":false}
```

`limit` caps a page at 500. `error: true` marks lines from an error channel
(stderr), not a severity: on iOS and Android, engine errors arrive with
`error: false`, so search the text. `missed` > 0 means your cursor fell out of
the buffer. `closed: true` means the app's output ended (it exited or crashed);
its last lines stay readable. When `launch` changes, the app was relaunched:
drop the cursor and tail again.

## Other commands

- `app.buildInfo`: native `-c dbg` runs only. Which build produced the app.
- `app.setViewport` (Chrome): `{"width":393,"height":660}`, whole numbers, not
  strings. The pixel ratio is fixed at launch with `--web-viewport 393x660@3`.

## The machine protocol

Under `--machine` the tool also takes the same commands as JSON-RPC lines on
stdin, `[{"id":1,"method":"app.hotReload","params":{"appId":"…"}}]`, and writes
events to stdout: `daemon.connected`, `app.start`, `app.debugPort`,
`app.started`, `app.log`, `app.progress`, `app.reloadResult`, `app.devTools`,
`app.webLaunchUrl`, `app.stop`, `daemon.commandsChanged`. A background job
cannot easily write to its own stdin, so use the HTTP channel for commands and
read the stdout file only for events.
