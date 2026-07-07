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

Device builds require code signing. One-time setup:

```sh
# 1. Create your local device config (gitignored)
cp -r device.example device
mv device/BUILD.bazel.example device/BUILD.bazel

# 2. Mint a provisioning profile for the bundle id (headless; requires an
#    Apple ID signed into Xcode and, for free teams, the device connected)
xcodebuild -project ios/Runner.xcodeproj -scheme Runner -configuration Debug \
  -destination generic/platform=iOS \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

# 3. Edit device/BUILD.bazel — set BUNDLE_ID to match the project's
#    PRODUCT_BUNDLE_IDENTIFIER (com.rulesflutter.ios.example by default;
#    override with your own team's id via DEVELOPMENT_TEAM=<id>
#    PRODUCT_BUNDLE_IDENTIFIER=<id> args to xcodebuild above)

# 4. Build
bazel build //device:app -c opt --ios_multi_cpus=arm64
```

The `device/` directory is gitignored — your signing config stays local.

**Profile expired?** Free-team ("Personal Team") profiles expire after ~7
days. When the bazel build fails with *"Could not find provisioning
profile"*, re-run the `xcodebuild ... -allowProvisioningUpdates build`
command from step 2 to mint a fresh one — no Xcode GUI needed.

## Build modes

| Compilation mode | Target | Result |
|-----------------|--------|--------|
| `-c dbg` | Simulator (`sim_arm64`) | JIT debug build — fast iteration |
| `-c dbg` | Device (`arm64`) | JIT debug build — requires debug engine on device |
| (default / `-c fastbuild`) | Device (`arm64`) | AOT release build |
| `-c opt` | Device (`arm64`) | AOT optimized release build |
| (default / `-c opt`) | Simulator (`sim_arm64`) | Builds but won't run — simulator cannot execute AOT code |

## Approaches

This example demonstrates three ways to build the iOS runner:

1. **`flutter_ios_app`** (`:app`) — Recommended. Auto-discovers `ios/Runner/` from `flutter create`.
2. **Bazel-generated runner** (`:app_bazel_runner`) — No `flutter create` needed. Uses template files from rules_flutter.
3. **Custom runner** (`:app_custom_runner`) — Full control. Write your own AppDelegate/SceneDelegate.

Approaches 2 and 3 are tagged `manual` and must be built explicitly.
