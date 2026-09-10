/// Creates a preemptible Linux VM for Flutter app visual verification.
///
/// Usage: dart run tools/vm/create_linux_vm.dart [vm-name]
///
/// The VM is created with:
/// - Ubuntu 24.04 LTS (see `_imageFamily` — it tracks ubuntu-latest on purpose)
/// - Preemptible (low cost, auto-deleted after 24h)
/// - GTK3 runtime (`libgtk-3-0` — the cloud image has none, and without it a
///   Flutter runner dies with `libgtk-3.so.0: cannot open shared object file`),
///   Xvfb, xdotool, x11-utils, scrot installed
/// - `zip` as well as `unzip`: the cloud image ships only the latter, while
///   GitHub's runner image has both, so `//tools/dev_tool:native_libs_fingerprint_test`
///   (which shells out to `zip`) fails here and passes in CI without it
/// - Dart SDK installed (for running verification scripts)
///
/// After creation, use deploy_bundle.dart to SCP a bundle and verify it.
library;

import 'gcloud.dart';
import 'hermetic_dart.dart';

const _defaultName = 'flutter-linux-test';
const _machineType = 'e2-medium';
// Match GitHub Actions' ubuntu-latest runner image (currently 24.04) so that
// host-resolved facts (e.g. the pip lockfile's manylinux wheel set) generated
// on this VM are identical to what CI computes.
const _imageFamily = 'ubuntu-2404-lts-amd64';
const _imageProject = 'ubuntu-os-cloud';

String _startupScript(String dartVersion) =>
    '''#!/bin/bash
set -ex

# System packages for running Flutter GTK apps.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  gcc \
  g++ \
  libegl1 \
  libgles2 \
  libgl1-mesa-dri \
  libgtk-3-0 \
  x11-utils \
  xvfb \
  xdotool \
  scrot \
  unzip \
  zip \
  curl \
  git

# Dart SDK — the version `@rules_dart//dart` resolves to, passed in rather than
# written here, so a literal cannot drift below what the e2e suite requires.
# See hermetic_dart.dart.
if ! command -v dart &>/dev/null; then
  curl -fsSL https://storage.googleapis.com/dart-archive/channels/stable/release/$dartVersion/sdk/dartsdk-linux-x64-release.zip -o /tmp/dart.zip
  unzip -q -o /tmp/dart.zip -d /opt
  ln -sf /opt/dart-sdk/bin/dart /usr/local/bin/dart
  rm /tmp/dart.zip
fi

# Bazel (via bazelisk).
if ! command -v bazel &>/dev/null; then
  curl -fsSL https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64 -o /usr/local/bin/bazel
  chmod +x /usr/local/bin/bazel
fi

echo "STARTUP_COMPLETE" > /tmp/startup_complete
''';

Future<void> main(List<String> args) async {
  final vmName = args.isNotEmpty ? args[0] : _defaultName;
  final project = await getProject();
  final zone = await getZone();
  final dartVersion = await hermeticDartVersion();

  print('Creating Linux VM: $vmName');
  print('  Project: $project');
  print('  Zone: $zone');
  print('  Machine type: $_machineType');
  print('  Image: $_imageFamily ($_imageProject)');
  print('  Preemptible: yes');
  print('  Dart SDK: $dartVersion (from @rules_dart//dart)');
  print('');

  await gcloud([
    'compute',
    'instances',
    'create',
    vmName,
    '--machine-type=$_machineType',
    '--image-family=$_imageFamily',
    '--image-project=$_imageProject',
    '--provisioning-model=SPOT',
    '--instance-termination-action=DELETE',
    '--metadata=startup-script=${_startupScript(dartVersion)}',
    '--scopes=default',
  ]);

  print('');
  print('VM created. Waiting for SSH ...');
  await waitForSsh(vmName);

  // Wait for startup script to complete.
  print('Waiting for startup script to complete ...');
  final deadline = DateTime.now().add(const Duration(minutes: 5));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final result = await sshRun(
        vmName,
        'cat /tmp/startup_complete 2>/dev/null',
      );
      if (result.contains('STARTUP_COMPLETE')) break;
    } catch (_) {}
    await Future<void>.delayed(const Duration(seconds: 10));
  }

  print('');
  print('Linux VM ready: $vmName');
  print('');
  print('Next steps:');
  print('  1. Build: cd e2e/cross_compile_example && bazel build :cross_linux');
  print(
    '  2. Deploy: dart run tools/vm/deploy_bundle.dart $vmName <bundle_path>',
  );
  print('  3. Delete: gcloud compute instances delete $vmName');
}
