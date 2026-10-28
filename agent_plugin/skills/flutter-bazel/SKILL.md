---
name: flutter-bazel
description: Run, look at, drive and hot-reload a Flutter app built with Bazel and rules_flutter, through its dev tool `flutter_bazel`. Use it whenever a rules_flutter workspace (rules_flutter in MODULE.bazel, flutter_macos_app, flutter_ios_app, flutter_android_app, flutter_web_app and similar targets in BUILD files) needs its app launched, or a change checked in the running app - what a screen shows, tapping, typing, reading text, screenshots, app logs and exceptions, hot reload and hot restart after a Dart edit. Prefer it to `bazel run` of an app target, which starts an app you cannot see into, drive or reload, and to `bazel build`, which only shows that the code compiles. Covers macOS, Linux, Windows, Chrome, the iOS simulator, iPhones and Android.
---

# Running and driving a Flutter app with flutter_bazel

`flutter_bazel` builds a Flutter target with Bazel, launches it on a device, and
stays running. While it runs it hot reloads and hot restarts the app, and it
serves an HTTP control channel on localhost through which you read the UI, tap,
type, take screenshots and read the app's logs.

Use it rather than `bazel run //:my_app_macos`. That starts an app you have no
way to look into, and every change means a rebuild and relaunch. With the dev
tool, an edit is live in a second or two, and you can check what it did on
screen yourself instead of guessing from the code.

The shape of a session: start the tool once, in the background, with its output
in files. Read the channel's URL and token, and the app's id, from those files.
Drive the app with `curl`. Reload after each edit. Shut it down at the end.

## 1. Find the target, the tool and the device

The target is the platform app, not the `flutter_application`:

```sh
grep -rnE --include='BUILD*' 'flutter_(macos|ios|android|linux|windows|web)_app\(' -A1 .
```

The tool is `@rules_flutter//tools/dev_tool:flutter_bazel`, or
`//tools/dev_tool:flutter_bazel` inside the rules_flutter repository itself.
Some projects put it on `PATH` with bazel_env under a short name such as `fl`;
look in `.bazel_env/bin` and in the project's CLAUDE.md or AGENTS.md.

Pick the device with `-d`. The host desktop (`macos`, `linux`, `windows`) is the
fastest loop when the project has that target. Other ids: `chrome`,
`ios-simulator`, `ios`, `android`, and the forms that name one device,
`ios-simulator:<udid>`, `ios:<udid>`, `android:<serial>`. A bare serial or UDID
is refused. See [reference/devices.md](reference/devices.md) before using
anything but the host.

## 2. Start a session in the background

Make a directory for the session's output and note the path it prints:

```sh
mktemp -d "${TMPDIR:-/tmp}/flutter_bazel.XXXXXX"
```

From the workspace root, start the tool as a background job that outlives the
call (in Claude Code, Bash with `run_in_background`; elsewhere `&` or `nohup`
around the whole line):

```sh
LOG_FORMAT=json bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- \
  run -t //:my_app_macos -d macos --machine --no-devtools \
  > /tmp/flutter_bazel.Ab12Cd/out 2> /tmp/flutter_bazel.Ab12Cd/err
echo $? > /tmp/flutter_bazel.Ab12Cd/exited
```

The `exited` file appears when the run ends, for any reason, with its exit
code in it.

- `--machine` keeps stdout to JSON protocol events, one `[{...}]` per line, and
  turns the file watcher off, so nothing reloads until you ask.
- `LOG_FORMAT=json` makes each of the tool's own stderr lines one JSON record.
- `--no-devtools` stops it opening a DevTools tab in a browser.
- On `-d chrome`, add `--web-run-headless`.

The first run builds the tool and the app, which takes minutes on a cold cache.
A slow start is not a hang. Bazel's progress is in `err`.

## 3. Find the channel and the app, then send a request

Wait until the app is up and the channel with it, or the run has ended. If your
harness refuses a foreground `sleep`, run the loop as a background job and wait
for it to finish:

```sh
cd /tmp/flutter_bazel.Ab12Cd
until grep -q '"message":"session_ready"' err || [ -e exited ]; do sleep 2; done
cat exited 2>/dev/null && grep '"message":"command_failed"' err | jq -r .text
```

No output from the last line means it started. An exit code means the run
ended: a `command_failed` text after it says why, and with none, bazel failed
before the tool started, and the reason is in the last lines of `err`.

Each app has a `session_ready` record on stderr with the channel's URL and
token, the app's id, and its endpoints with the id filled in:

```sh
cd /tmp/flutter_bazel.Ab12Cd
grep '"message":"session_ready"' err | jq '{appId, uri, token, urls: [.endpoints[].url]}'
# {"appId":"___my_app_macos_macOS","uri":"http://localhost:53817","token":"9f2c…e1",
#  "urls":[".../sessions/___my_app_macos_macOS/screenshot/flutter?token=9f2c…e1",
#          ".../sessions/___my_app_macos_macOS/screenshot/native?token=9f2c…e1",
#          ".../sessions/___my_app_macos_macOS/logs?token=9f2c…e1"]}
```

The token goes in the `token` query parameter, not in a header. Every `app.*`
command needs `appId` in its params. A command is a POST of
`{"method":..., "params":{...}}` to `/command`; with the values filled in:

```sh
curl -s 'http://localhost:53817/command?token=9f2c…e1' \
  -d '{"method":"app.getText","params":{"appId":"___my_app_macos_macOS","key":"counter_label"}}'
# {"result":{"text":"count: 0","texts":["count: 0"]}}
```

Screenshots and logs are GETs on the app's session:

```sh
curl -s -D - -o /tmp/flutter_bazel.Ab12Cd/shot.png \
  'http://localhost:53817/sessions/___my_app_macos_macOS/screenshot/native?token=9f2c…e1'
curl -s 'http://localhost:53817/sessions/___my_app_macos_macOS/logs?token=9f2c…e1'
```

With several `-d` devices there is one `app.started` per app, each with its own
`appId`. `GET /commands?token=…` lists what this run accepts; the list grows
during a run, so read it again rather than caching it.

The rest of this skill writes requests as `POST /command` plus the body; send
them exactly like the one above.

If you will make many calls, consider writing yourself a small, token-efficient
wrapper for this API. One way, a file you source before each call:

```sh
cat > /tmp/flutter_bazel.Ab12Cd/env <<'EOF'
U=http://localhost:53817 T=9f2c…e1 A=___my_app_macos_macOS
c() { curl -s "$U/command?token=$T" -d "{\"method\":\"$1\",\"params\":{\"appId\":\"$A\"${2:+,$2}}}"; echo; }
shot() { curl -s -o "$1" "$U/sessions/$A/screenshot/native?token=$T"; }
EOF
. /tmp/flutter_bazel.Ab12Cd/env; c app.tap '"key":"increment"'
```

Nothing in this skill depends on it.

## 4. See what is on screen

Cheapest first:

1. **`app.dumpSemanticsTree`**: the whole screen as a screen reader sees it, in
   about a kilobyte of text. It takes only `appId` and answers `{"text": …}`:

   ```
   POST /command  {"method":"app.dumpSemanticsTree","params":{"appId":"___my_app_macos_macOS"}}
   → view 0 800x600 @1x
     #3 scopesRoute @400,300 800x600
       #6 "count: 0" @400,254 56x20
       #7 button "Increment (agent)" [tap] @400,280 171x32
       #8 textField [tap] @400,320 200x48
       #27 [scrollUp] @400,444 200x80
         #17 hidden "item 4"
   ```

   Each line is a node: role and flags, its strings, its actions in brackets,
   then `@x,y`, its centre in logical pixels, and its size. To press a node,
   pass that point to `app.tap` as `"x"` and `"y"`; a node with a label can
   also be named with the `semanticsLabel` selector. A `hidden` node is
   scrolled out of view and has no point: scroll it into view, then dump
   again. Node ids are not selectors. If `/commands` does not list the
   command, the rules_flutter version predates it.
2. **`app.getText`** on a selector you already know.
3. **A screenshot** when layout, colour or rendering is the question. Save it
   as above and open the PNG with your image-reading tool. The `X-Settled: yes`
   header means the app was idle when captured. Use `screenshot/native`;
   `screenshot/flutter` answers `501` on every platform at the pinned Flutter.

`app.dumpWidgetTree` returns the whole widget tree as inspector JSON: 142 KB
for a small example app whose semantics dump is 1 KB. Save it to a file and
search it, and use it only to find a `ValueKey` or a widget type that nothing
cheaper shows.

## 5. Drive it

Commands that target a widget take exactly one selector: `key` (a `ValueKey`'s
string), `text` (the exact displayed text), `tooltip`, `type` (the runtime type
name, such as `ElevatedButton`) or `semanticsLabel`. Matching is exact, not
substring. Values may be strings or numbers.

```
POST /command  {"method":"app.tap","params":{"appId":"___my_app_macos_macOS","key":"increment"}}
POST /command  {"method":"app.enterText","params":{"appId":"___my_app_macos_macOS","key":"email","text":"a@b.c"}}
POST /command  {"method":"app.pressKey","params":{"appId":"___my_app_macos_macOS","key":"Enter"}}
POST /command  {"method":"app.waitFor","params":{"appId":"___my_app_macos_macOS","text":"Saved","timeoutMs":5000}}
```

Each input command waits for the app to go idle before it answers, so the next
read sees the result. The reply says how that went in `settled`. `no` is not a
failure: the input was delivered, so do not send it again or you will tap twice.
An app with a spinner or other endless animation never goes idle; pass
`"settle":"false"` and confirm with `app.waitFor`.

The full list, every parameter and every reply field are in
[reference/commands.md](reference/commands.md).

## 6. Edit, reload, check

Make all the edits for one step, then reload once:

```
POST /command  {"method":"app.hotReload","params":{"appId":"___my_app_macos_macOS"}}
→ {"result":{"succeeded":true,"runningCode":"updated","appIds":["___my_app_macos_macOS"],
             "message":"Hot reload successful","filesRecompiled":["package:my_app/main.dart"],
             "isEmpty":false,"elapsedMs":377}}
```

Read `succeeded`. A compile error comes back as `succeeded: false` with the
compiler's diagnostics in `error`; the app keeps running its old code. Fix and
reload again; the session does not need restarting.

A reload keeps the app's state and re-runs `build` methods. It does not re-run
`main()`, `initState` of widgets already on screen, or initializers of globals
and static fields that have already been read. When the edit is in one of those,
use `app.restart` with the same params, which re-runs `main()` and loses state.
A restart also picks up changed native code, relaunching the process if it has
to; the channel, token and `appId` stay the same.

Then look again: a screenshot, `getText`, or the semantics tree. A reply with
`notShown`, or a read with `notRendering`, means the window is hidden or covered
and is drawing nothing; see [reference/failures.md](reference/failures.md).

## 7. Read the logs

The logs request above returns the last 200 lines:

```json
{"lines":[{"index":812,"text":"flutter: …","error":false}],
 "nextCursor":813,"launch":1,"missed":0,"dropped":0,"closed":false}
```

Check them after a reload or a tap: Flutter prints errors that do not stop the
app, such as `RenderFlex overflowed` or an exception thrown in a handler, only
here. Add `&since=813`, a previous reply's `nextCursor`, to read only what is
new. The tool's own messages and bazel's output are in `err`:
`grep '^{' err | jq -r '.text // .line // empty' | tail -40`.

## 8. Stop

```
POST /command  {"method":"daemon.shutdown"}
```

That stops the app, the compiler, any browser and the tool. Do not `pkill` by
name: other sessions on the machine may be running the same tool.

## When something fails

Every refusal is `{"error": "<reason>"}` with a status: `404` unknown command
or `appId`, `400` a malformed request, `501` this run cannot do it, `422` the
app could not or would not do it, `500` the tool broke. Read the reason; it
usually names the fix. [reference/failures.md](reference/failures.md) lists the
common ones and what they mean.

## Tell rules_flutter when the tool lets you down

Prepare a feedback report when:

- a step cost far more than it should: a dump or screenshot much larger than
  needed, many calls where one should do;
- you had to guess a command, parameter, flag or device id, or guessed wrong;
- an error did not say what to do;
- this skill or the docs disagree with what the tool did;
- the tool hung or had to be restarted.

Write it with [reference/feedback.md](reference/feedback.md). If a Claude
session working on rules_flutter is running on this machine (list agents, then
send it a message), send the report there. Otherwise draft a GitHub issue for
github.com/aran/rules_flutter and show the draft to the user. File it only if
they say so: an issue is public text under their name.

One report per distinct problem. Write it, then carry on with the user's task.
