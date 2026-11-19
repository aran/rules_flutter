/// The command line of a Chrome the dev tool launches, moved to another
/// machine, for `ssh_chrome`.
library;

/// One launch: the dev tool's arguments for Chrome, with the ports and the
/// profile directory the forwarding and the clean-up need.
class RemoteChromeLaunch {
  RemoteChromeLaunch._(
    this.args,
    this.debugPort,
    this.serverPort,
    this.profile,
  );

  /// Reads the dev tool's arguments for Chrome. A debugging port of `0`
  /// ("any") becomes [debugPort], because the port has to be known before
  /// ssh starts to be forwarded; a port the run asked for is kept.
  factory RemoteChromeLaunch.parse(
    List<String> args, {
    required int debugPort,
  }) {
    const portFlag = '--remote-debugging-port=';
    const profileFlag = '--user-data-dir=';
    String? profile;
    var port = debugPort;
    final rewritten = <String>[];
    for (final arg in args) {
      if (arg.startsWith(portFlag)) {
        final asked = int.parse(arg.substring(portFlag.length));
        if (asked != 0) port = asked;
        rewritten.add('$portFlag$port');
        continue;
      }
      if (arg.startsWith(profileFlag)) {
        profile = arg.substring(profileFlag.length);
        continue;
      }
      rewritten.add(arg);
    }
    if (profile == null) {
      throw ArgumentError('No $profileFlag among $args');
    }
    final page = args.isEmpty ? null : Uri.tryParse(args.last);
    if (page == null ||
        !page.isScheme('http') ||
        !const {'localhost', '127.0.0.1'}.contains(page.host)) {
      throw ArgumentError(
        'The last argument is not a page on this machine\'s loopback: '
        '${args.lastOrNull}',
      );
    }
    return RemoteChromeLaunch._(rewritten, port, page.port, profile);
  }

  /// Chrome's arguments, the debugging port fixed and the profile left out:
  /// [remoteScript] gives Chrome one of the host's own.
  final List<String> args;

  /// The debugging port, the same number here and on the host.
  final int debugPort;

  /// The dev server's port, the same number here and on the host.
  final int serverPort;

  /// The profile directory the dev tool made here. Its path need not exist
  /// or be writable on the host, so Chrome there gets a fresh one instead.
  final String profile;

  /// What ssh runs on the host: Chrome on a fresh profile until it exits or
  /// ssh's stdin ends, then every process still on the profile ended and the
  /// profile removed. Run by bash, because a background job's stdin is the
  /// one thing that waits for ssh's to end, and whether a shell gives it to a
  /// background job is shell-specific.
  ///
  /// Chrome can restart itself (`chrome://restart`, a relaunch it decides on):
  /// the browser exits with 0 and a relauncher starts a new one on the same
  /// profile with `--restart`, a process this script did not start and the
  /// dev tool cannot see. That ends the run, so the script says so and exits
  /// 1 rather than 0, which the dev tool would report as the app finishing,
  /// and ends the new browser rather than leaving it running on a deleted
  /// profile.
  String remoteScript(String chrome) {
    final script = [
      r'profile=$(mktemp -d "${TMPDIR:-/tmp}/rules_flutter_chrome.XXXXXX") || exit 1',
      '${_quote(chrome)} "--user-data-dir=\$profile" '
          '${args.map(_quote).join(' ')} </dev/null & chrome=\$!',
      r'( read -r _; kill $chrome 2>/dev/null ) <&0 & watcher=$!',
      r'wait $chrome; status=$?',
      r'kill $watcher 2>/dev/null',
      r'restarted=$(ps -A -o command= | grep -F -- "--user-data-dir=$profile" | grep -c -F -- " --restart")',
      r'pkill -f -- "--user-data-dir=$profile"',
      r'rm -rf "$profile"',
      r'if [ "$restarted" != 0 ]; then',
      r'  echo "ssh_chrome: Chrome restarted itself into a process this run cannot follow, and was ended." >&2',
      r'  exit 1',
      r'fi',
      r'exit $status',
    ].join('\n');
    return 'exec /bin/bash -c ${_quote(script)}';
  }
}

String _quote(String word) => "'${word.replaceAll("'", r"'\''")}'";
