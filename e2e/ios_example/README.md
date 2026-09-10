# Flutter iOS Example (rules_flutter)

Demonstrates building a Flutter iOS app with Bazel using `rules_flutter`.

## Quick start (simulator)

No signing or Xcode setup needed:

```sh
bazel build :app -c dbg --ios_multi_cpus=sim_arm64
```

Install on a booted simulator:

```sh
unzip -oq bazel-bin/app.ipa -d /tmp/ios_app
xcrun simctl install booted /tmp/ios_app/Payload/app.app
xcrun simctl launch booted com.rulesflutter.ios.example
```

## Device builds

Device builds require code signing, which is per-developer and stays out of
version control.

`flutter_ios_app` takes the credential directly via `provisioning_profile`,
so a device target is the simulator target plus one attribute — the same
bundle construction, not a second one hand-assembled from Tier-2 `_gen`
rules. That is `//:app_device` in this example's BUILD.bazel:

```starlark
flutter_ios_app(
    name = "app_device",
    application = ":app_flutter",
    bundle_id = "com.rulesflutter.ios.example",
    provisioning_profile = "//device:profile",
)
```

One-time setup:

```sh
# 1. Create your local device config (gitignored)
cp -r device.example device
mv device/BUILD.bazel.example device/BUILD.bazel

# 2. Obtain a development provisioning profile whose App ID covers the
#    bundle id, installed into
#    ~/Library/Developer/Xcode/UserData/Provisioning Profiles/
#    See "Getting a provisioning profile" below.

# 3. Set device/BUILD.bazel's profile_name to that profile's own Name, and
#    make sure //:app_device's bundle_id is covered by its App ID.

# 4. Build
bazel build //:app_device -c opt --ios_multi_cpus=arm64
```

The `device/` directory is gitignored — it holds nothing but the credential,
so `//:app_device` itself stays in version control. It is tagged `manual`, so
`bazel build //...` on a fresh clone never expands it and therefore never
loads the missing `//device` package.

### Getting a provisioning profile

This changes an Apple Developer account, so it is yours to do; no Bazel
change can substitute for it. Two routes:

- **Developer portal** — create the App ID and a development profile,
  download it, double-click to install. Works for any repository layout.
- **`xcodebuild` automatic signing** — headless, but it needs an Xcode
  project:
  ```sh
  xcodebuild -project ios/Runner.xcodeproj -scheme Runner -configuration Debug \
    -destination generic/platform=iOS \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
  ```
  This example happens to keep `ios/Runner.xcodeproj`, but **your app need
  not**: `flutter_ios_app` reads only `ios/Runner/*.swift` and
  `ios/Runner/Info.plist`, and a `flutter create --platforms=ios .` tree
  checked into a Bazel repository has no reason to keep the project. Any
  scratch Xcode project whose `PRODUCT_BUNDLE_IDENTIFIER` is your bundle id
  will mint the same profile — override it with
  `PRODUCT_BUNDLE_IDENTIFIER=<id> DEVELOPMENT_TEAM=<id>` arguments.

**Naming it.** `profile_name` matches the profile's `Name` field, which is
*not* always `iOS Team Provisioning Profile: <bundle id>`. Xcode mints a
per-bundle-id profile only for an App ID registered explicitly in the portal;
`com.rulesflutter.ios.example` is not one, so automatic signing issues the team
**wildcard** profile instead — named `iOS Team Provisioning Profile: *` over
App ID `<TEAM>.*`, which covers any bundle id under your team. That is what
`device.example/` names by default. List what you actually have:

```sh
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$f" | plutil -extract Name raw -
done
```

**Profile expired?** Free-team ("Personal Team") profiles expire after ~7
days. When the bazel build fails with *"no provisioning profile was found
named …"*, mint a fresh one the same way.

## Build modes

| Compilation mode | Target | Result |
|-----------------|--------|--------|
| `-c dbg` | Simulator (`sim_arm64`) | JIT debug build — fast iteration |
| `-c dbg` | Device (`arm64`) | JIT debug build — requires debug engine on device |
| (default / `-c fastbuild`) | Device (`arm64`) | AOT release build |
| `-c opt` | Device (`arm64`) | AOT optimized release build |
| (default / `-c opt`) | Simulator (`sim_arm64`) | Builds and installs, but **cannot run** — see below |

"Cannot run" on the simulator does not look like a failure. `xcrun simctl
install` and `launch` both return 0 and print a pid, the process stays alive,
and the screen is **blank white forever** — the app never crashes, so nothing
is written to a crash log. The simulator slice of the engine is JIT and looks
for `flutter_assets/kernel_blob.bin`, which the AOT `App.framework` a `-c opt`
build produces does not contain. The only evidence is in the simulator's
system log:

```sh
xcrun simctl spawn booted log show --last 5m \
  --predicate 'eventMessage CONTAINS "kernel_blob" OR eventMessage CONTAINS "Engine run configuration"'
# (Flutter) Failed to find snapshot at .../App.framework/flutter_assets/kernel_blob.bin:
#   Error Domain=NSCocoaErrorDomain Code=260 "The file "kernel_blob.bin" couldn't be opened…"
# (Flutter) [ERROR:flutter/shell/common/engine.cc(219)] Engine run configuration was invalid.
```

`flutter_bazel run` refuses the combination rather than handing back a session
whose app will never draw:

```
$ flutter_bazel run -t //:app -d ios-simulator --profile
Cannot run an AOT build on iOS Simulator: the simulator's Flutter engine is
JIT-only and needs flutter_assets/kernel_blob.bin, ...
```

The *build* is still allowed — `bazel build -c opt` for the simulator is a
legitimate thing to do, and the default iOS configuration is the simulator, so
refusing there would break every release build.

So a release-configured iOS build can only be *observed* on a device, which
needs a signing credential. That matters: release-only defects are found by
running, not by reading rules.

## Approaches

This example demonstrates three ways to build the iOS runner:

1. **`flutter_ios_app`** (`:app`) — Recommended. Auto-discovers `ios/Runner/` from `flutter create`.
2. **Bazel-generated runner** (`:app_bazel_runner`) — No `flutter create` needed. Uses template files from rules_flutter.
3. **Custom runner** (`:app_custom_runner`) — Full control. Write your own AppDelegate/SceneDelegate.

Approaches 2 and 3 are tagged `manual` and must be built explicitly.
