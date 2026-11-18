/// Assembles a directory from trees and files, each placed at a name.
///
/// Builds `--output` from what it is given, in the order given:
///
/// * `--add-tree <name> <dir>` copies the contents of `<dir>`, following
///   symlinks, into `<name>` under `--output` (`.` is `--output` itself).
/// * `--add <name> <file>` copies `<file>` to `<name>`, replacing a file of
///   that name an earlier argument put there.
///
/// Directories in a `<name>` are created. Each file is copied once, from the
/// last argument that places it: a file an earlier tree has and a later
/// `--add` replaces is never copied. A copy of a Bazel output is read-only on
/// Windows, where a read-only file cannot be deleted to replace it.
///
/// A Bazel tree artifact cannot be extended in place, and an action can only
/// name its contents by running something over them, so this is that
/// something.
///
/// The tool has no package dependencies and runs with the bare Dart SDK, so it
/// runs on any host.
///
/// Usage:
///   dart assemble_directory.dart --output <dir>
///       [--add-tree <name> <dir> | --add <name> <file>]...
import 'dart:io';

/// Copies the contents of [source] into [destination], following symlinks.
void copyTree(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  for (final entry in source.listSync(followLinks: false)) {
    final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    final target = '${destination.path}/$name';
    switch (FileSystemEntity.typeSync(entry.path)) {
      case FileSystemEntityType.directory:
        copyTree(Directory(entry.path), Directory(target));
      case FileSystemEntityType.file:
        copyFile(File(entry.path), target);
      case _:
        throw FileSystemException('cannot copy', entry.path);
    }
  }
}

/// Copies [source] to [target], replacing a file already there.
void copyFile(File source, String target) {
  File(target).parent.createSync(recursive: true);
  final existing = File(target);
  if (existing.existsSync()) {
    existing.deleteSync();
  }
  // Resolved first: on Windows, `File.copySync` of a symlink to a file fails
  // with "file not found" instead of copying what it points to.
  File(source.resolveSymbolicLinksSync()).copySync(target);
}

/// Adds the directories and files of [source], following symlinks, to
/// [directories] and [files] at [target].
void _planTree(
  Directory source,
  String target,
  List<String> directories,
  Map<String, File> files,
) {
  directories.add(target);
  for (final entry in source.listSync(followLinks: false)) {
    final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    final path = '$target/$name';
    switch (FileSystemEntity.typeSync(entry.path)) {
      case FileSystemEntityType.directory:
        _planTree(Directory(entry.path), path, directories, files);
      case FileSystemEntityType.file:
        files[path] = File(entry.path);
      case _:
        throw FileSystemException('cannot copy', entry.path);
    }
  }
}

/// Runs the tool over [args] (the command line) and returns the exit code.
int run(List<String> args) {
  String? output;
  // Each step is (isTree, name, source).
  final steps = <(bool, String, String)>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--output':
        output = args[++i];
      case '--add-tree':
        steps.add((true, args[++i], args[++i]));
      case '--add':
        steps.add((false, args[++i], args[++i]));
      default:
        stderr.writeln('unexpected argument: ${args[i]}');
        return 64;
    }
  }
  if (output == null) {
    stderr.writeln(
      'usage: assemble_directory.dart --output <dir> '
      '[--add-tree <name> <dir> | --add <name> <file>]...',
    );
    return 64;
  }
  final destination = Directory(output)..createSync(recursive: true);
  // The directories to create and the file at each path, the last argument's.
  final directories = <String>[];
  final files = <String, File>{};
  for (final (isTree, name, source) in steps) {
    final target = name == '.' ? destination.path : '${destination.path}/$name';
    if (isTree) {
      _planTree(Directory(source), target, directories, files);
    } else {
      files[target] = File(source);
    }
  }
  for (final directory in directories) {
    Directory(directory).createSync(recursive: true);
  }
  files.forEach((target, source) => copyFile(source, target));
  return 0;
}

void main(List<String> args) {
  exitCode = run(args);
}
