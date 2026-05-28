/// Creates a preemptible Windows VM for Flutter app visual verification.
///
/// Usage: dart run tools/vm/create_windows_vm.dart [vm-name]
///
/// The VM is created with:
/// - Windows Server 2022
/// - Preemptible (low cost, auto-deleted after 24h)
/// - Virtual display device (--enable-display-device) for D3D rendering
/// - SSH enabled via google-compute-engine-ssh
/// - Auto-logon: testuser is created with an interactive console session
///   at boot — no RDP or tscon needed for DXGI screenshots
/// - Visual C++ Build Tools, Dart SDK, Git, Bazel, Python + dxcam installed
///
/// After creation, deploy and verify entirely over SSH:
///   dart run tools/vm/deploy_bundle.dart <vm-name> <bundle_path> --windows
library;

import 'dart:io';

import 'gcloud.dart';

const _defaultName = 'flutter-windows-test';
const _machineType = 'e2-standard-4';
const _imageFamily = 'windows-2022';
const _imageProject = 'windows-cloud';

/// Sysprep specialize script — runs once on first boot before GCP auto-reboots.
///
/// Creates the test user with auto-logon registry keys so the second boot
/// creates an interactive console session (session 1) automatically — no RDP needed.
String get _specializeScript => '''
# Install SSH via googet (must happen during sysprep).
googet -noconfirm=true install google-compute-engine-ssh

# Create test user with known password.
net user $windowsTestUser "$windowsTestPassword" /add /y
net localgroup Administrators $windowsTestUser /add

# Set auto-logon registry keys so the user gets a console session at boot.
\$regPath = "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
Set-ItemProperty -Path \$regPath -Name AutoAdminLogon -Value "1"
Set-ItemProperty -Path \$regPath -Name DefaultUserName -Value "$windowsTestUser"
Set-ItemProperty -Path \$regPath -Name DefaultPassword -Value "$windowsTestPassword"
Set-ItemProperty -Path \$regPath -Name DefaultDomainName -Value "."
''';

/// PowerShell startup script — runs on every boot.
///
/// Installs tools, then waits for the auto-logon session to be Active
/// before signalling completion.
const _startupScript = r'''
# Install Chocolatey (package manager).
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

# Install prerequisites.
choco install -y git --params "/GitAndUnixToolsOnPATH"
choco install -y dart-sdk
choco install -y bazelisk
choco install -y vcredist140
choco install -y visualstudio2022buildtools --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
choco install -y python3
choco install -y psexec

# Install Python packages for DXGI screen capture.
# Redirect output to a log file — the GCE agent's stdout pipe breaks during
# long pip installs, causing "Pipe to stdout was broken" errors.
$pythonDir = (Get-ChildItem C:\Python* -Directory | Select-Object -First 1).FullName
if ($pythonDir) {
    & "$pythonDir\python.exe" -m pip install dxcam numpy Pillow opencv-python-headless > C:\pip_install.log 2>&1
}

# Set BAZEL_VC so Bazel finds MSVC.
[System.Environment]::SetEnvironmentVariable("BAZEL_VC", "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC", "Machine")

# Disable Server Manager auto-start (blocks the desktop).
schtasks /Change /TN "\Microsoft\Windows\Server Manager\ServerManager" /DISABLE

# Wait for testuser auto-logon session to become Active.
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    $sessions = query user 2>&1
    if ($sessions -match "testuser.*Active") {
        break
    }
    Start-Sleep -Seconds 5
}

# Signal completion.
New-Item -Path C:\startup_complete.txt -Value "STARTUP_COMPLETE" -Force
''';

Future<void> main(List<String> args) async {
  final vmName = args.isNotEmpty ? args[0] : _defaultName;
  final project = await getProject();
  final zone = await getZone();

  print('Creating Windows VM: $vmName');
  print('  Project: $project');
  print('  Zone: $zone');
  print('  Machine type: $_machineType');
  print('  Image: $_imageFamily ($_imageProject)');
  print('  Preemptible: yes');
  print('  SSH: enabled');
  print('  Virtual display: enabled');
  print('');

  // Write scripts to temp files to avoid shell escaping issues.
  final tmpDir = Directory.systemTemp.createTempSync('win_vm_');
  final tmpSpecialize = File('${tmpDir.path}/specialize.ps1');
  final tmpStartup = File('${tmpDir.path}/startup.ps1');
  tmpSpecialize.writeAsStringSync(_specializeScript);
  tmpStartup.writeAsStringSync(_startupScript);

  try {
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
      // Virtual display device — required for D3D rendering and DXGI capture.
      '--enable-display-device',
      '--metadata=enable-windows-ssh=TRUE',
      '--metadata-from-file=sysprep-specialize-script-ps1=${tmpSpecialize.path},windows-startup-script-ps1=${tmpStartup.path}',
      '--scopes=default',
      '--boot-disk-size=100GB',
    ]);
  } finally {
    tmpDir.deleteSync(recursive: true);
  }

  print('');
  print('VM created. Waiting for SSH ...');
  await waitForSsh(vmName, timeout: const Duration(minutes: 10));

  print('');
  print('Windows VM created: $vmName');
  print('');
  print('The startup script is installing tools (Git, Dart, Bazel, MSVC,');
  print('Python, dxcam, PsExec). This takes ~15 minutes.');
  print('');
  print('The deploy script checks readiness automatically. Just run:');
  print('  dart run tools/vm/deploy_bundle.dart $vmName <bundle_path> --windows');
  print('');
  print('Delete when done:');
  print('  gcloud compute instances delete $vmName --quiet');
}
