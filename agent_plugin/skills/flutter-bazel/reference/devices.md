# Devices

## Ids

| `-d` | Runs on |
|---|---|
| `macos`, `linux`, `windows` | This machine's desktop. |
| `chrome` | A browser the tool launches, through its dev server. |
| `ios-simulator`, `ios-simulator:<udid>` | The booted simulator, or the one named. |
| `ios`, `ios:<udid>` | The attached iPhone, or the one named. |
| `android`, `android:<serial>` | The device `adb` picks, or the one named. |

An id must say what kind of device it is: `-d android:emulator-5554`, not
`-d emulator-5554`. A refused id comes back with the form to use. Repeat `-d`
to run on several devices at once; each gets its own `appId`, so read every
`app.started` event, not just the first.

The target has to match the device. An iOS project usually has a simulator
target and a separate device target with a `provisioning_profile`; `-d ios`
with the simulator target, or the reverse, fails at build time.

Several booted simulators or attached phones: name one. Another agent or person
may be using the others.

## Before you start

- **iOS simulator.** One must be booted: `xcrun simctl list devices booted`.
  Otherwise the run fails with "No booted iOS simulator found". Boot one with
  `xcrun simctl boot <udid>`.
- **Android.** `adb devices` lists what is attached. A physical phone behind a
  lock screen still runs the app, but every screenshot shows the lock screen and
  the app draws nothing (`notRendering` on replies). Prefer an emulator for
  anything visual, and do not try to unlock someone's phone.
- **iPhone.** Screenshots need Xcode 27 or later, whose `devicectl` can
  capture the screen. With an older Xcode selected, the screenshot fails and
  says so.
- **Chrome.** Pass `--web-run-headless` so the page stays visible to itself: a
  hidden or covered browser window draws no frames.
- **Linux.** Screenshots use `scrot` and need a display (`DISPLAY` set, or
  Xvfb).

## Timing

- Host desktop and simulator: the app is drivable within seconds of
  `app.started`.
- Chrome: commands sent right after `app.started` wait several seconds for the
  browser to connect. That wait is normal.
- iPhone: the first command after `app.started` can take a minute, wired
  (measured 45 to 61 s), because the app is still starting under the debugger.
  Commands wait it out rather than failing. Launch to first log line is about
  8 s over a cable, 40 s over Wi-Fi; a restart costs about as much as a launch.
  A launch that takes minutes points at the Mac (Xcode still copying device
  symbols), not the phone.

## Screenshots

`screenshot/native` works everywhere. It captures:

| Device | With |
|---|---|
| macOS | The app's window, through ScreenCaptureKit. Needs Screen Recording permission for the terminal running the tool. |
| Linux | `scrot` |
| Windows | DXGI desktop duplication |
| Android phone | `adb screencap` |
| Android emulator | the emulator's own framebuffer capture |
| iOS simulator | `simctl io screenshot` |
| iPhone | `devicectl device capture screenshot` (Xcode 27 or later) |
| Chrome | the DevTools protocol's page capture |

On macOS the window must be on screen. The tool brings it to the front at
launch; if something covers it later, raise it again (`open <path to .app>`, or
click it) before trusting a screenshot.

## Where app output comes from

| Device | Source |
|---|---|
| Desktop | The process's stdout and stderr. |
| Android | `adb logcat`, filtered to Flutter, the Dart VM, `AndroidRuntime`, `System.err` and fatal lines. |
| iOS simulator | `simctl spawn log stream` for the app's process. |
| iPhone | `devicectl --console` plus lldb's output, so expect devicectl banners. |
| Chrome, dev loop | The VM service's stdout and stderr streams. |
| Chrome, `--wasm` | Browser console messages. |

## Web runs without widget driving

`--wasm`, `--profile` and `--no-hot` on Chrome run a compiled bundle with no
VM service. The widget commands are absent from `/commands` (an
`agent_surface_unavailable` record on stderr says so). Such a run still offers
`app.pressKey`, logs, `screenshot/native` and `app.restart`. To read and tap
widgets on the web, run the default dev loop.

For a phone-sized web layout, start with `--web-viewport 393x660@3`, or call
`app.setViewport` with `{"width":393,"height":660}` once the browser is up. The
`app.webLaunchUrl` event on stdout has the page's URL and the browser's
DevTools port (`cdpPort`) if you want to open or drive the page yourself.
