// Extracts the release archive of a commit to `e2e/external_module/rules_flutter`.
//
//   bazel run //tools/consumer_archive [-- <revision>]
//
// What a consumer of the published module gets is `git archive` output, which
// `.gitattributes` trims (`release_prep.sh` builds it the same way): files the
// archive omits are files the module must not need. The revision is HEAD by
// default; changes not committed are not in it.
import 'dart:io';

Future<void> main(List<String> args) async {
  final repo = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (repo == null || args.length > 1) {
    stderr.writeln('usage: bazel run //tools/consumer_archive [-- <revision>]');
    exit(2);
  }
  final revision = args.isEmpty ? 'HEAD' : args.single;
  final destination = Directory('$repo/e2e/external_module/rules_flutter');
  if (destination.existsSync()) destination.deleteSync(recursive: true);
  destination.createSync(recursive: true);

  // `git archive` writes to a file rather than a pipe into `tar`: macOS's
  // bsdtar stops reading at the archive's end-of-archive blocks, before git has
  // written the zero padding of its last record, and a write into the closed
  // pipe then fails the run (SocketException: Broken pipe), now and then.
  final temp = Directory.systemTemp.createTempSync('consumer_archive');
  final bool extracted;
  try {
    final tarball = '${temp.path}/archive.tar';
    final archive = await Process.run('git', [
      'archive',
      '--format=tar',
      '--output=$tarball',
      revision,
    ], workingDirectory: repo);
    stderr.write(archive.stderr);
    final extract = archive.exitCode != 0
        ? null
        : await Process.run('tar', [
            '-x',
            '-f',
            tarball,
            '-C',
            destination.path,
          ]);
    if (extract != null) stderr.write(extract.stderr);
    extracted = extract != null && extract.exitCode == 0;
  } finally {
    temp.deleteSync(recursive: true);
  }
  // After the `finally`: `exit` ends the process without running it.
  if (!extracted) {
    stderr.writeln('consumer_archive: could not extract $revision');
    exit(1);
  }
  stdout.writeln('extracted $revision to ${destination.path}');
}
