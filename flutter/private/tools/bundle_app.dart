/// Cross-platform Flutter application bundler.
///
/// Takes a JSON config describing the bundle layout and copies files accordingly.
/// Used by macOS, Linux, and Windows bundle rules to avoid platform-specific
/// shell scripts.
///
/// Config JSON schema:
/// {
///   "output_dir": "/path/to/output",
///   "copies": [
///     {"src": "/path/to/src", "dst": "relative/path/in/output"},
///     ...
///   ],
///   "copy_dirs": [
///     {"src": "/path/to/dir", "dst": "relative/path/in/output"},
///     ...
///   ],
///   "symlinks": [
///     {"target": "relative/target", "link": "relative/link/path"},
///     ...
///   ],
///   "write_files": [
///     {"path": "relative/path", "content": "file content", "executable": true},
///     ...
///   ]
/// }
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 2 || args[0] != '--config') {
    stderr.writeln('Usage: bundle_app.dart --config <config.json>');
    exit(1);
  }

  final config = json.decode(File(args[1]).readAsStringSync()) as Map<String, dynamic>;
  final outputDir = config['output_dir'] as String;

  // Ensure output directory exists.
  Directory(outputDir).createSync(recursive: true);

  // Process file copies.
  final copies = (config['copies'] as List<dynamic>?) ?? [];
  for (final copy in copies) {
    final src = copy['src'] as String;
    final dst = '$outputDir/${copy['dst']}';
    final dstDir = File(dst).parent;
    if (!dstDir.existsSync()) dstDir.createSync(recursive: true);
    File(src).copySync(dst);
  }

  // Process directory copies.
  final copyDirs = (config['copy_dirs'] as List<dynamic>?) ?? [];
  for (final copy in copyDirs) {
    final src = copy['src'] as String;
    final dst = '$outputDir/${copy['dst']}';
    _copyDirectory(Directory(src), Directory(dst));
  }

  // Process symlinks.
  final symlinks = (config['symlinks'] as List<dynamic>?) ?? [];
  for (final sym in symlinks) {
    final target = sym['target'] as String;
    final link = '$outputDir/${sym['link']}';
    final linkDir = File(link).parent;
    if (!linkDir.existsSync()) linkDir.createSync(recursive: true);
    Link(link).createSync(target);
  }

  // Process write_files.
  final writeFiles = (config['write_files'] as List<dynamic>?) ?? [];
  for (final wf in writeFiles) {
    final path = '$outputDir/${wf['path']}';
    final content = wf['content'] as String;
    final executable = (wf['executable'] as bool?) ?? false;
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    if (executable && !Platform.isWindows) {
      Process.runSync('chmod', ['+x', path]);
    }
  }
}

void _copyDirectory(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  for (final entity in src.listSync(recursive: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    // Skip compiler debug artifacts that shouldn't be in the output bundle.
    if (name.endsWith('.deps')) continue;
    final dstPath = '${dst.path}/$name';
    if (entity is File) {
      entity.copySync(dstPath);
    } else if (entity is Directory) {
      _copyDirectory(entity, Directory(dstPath));
    } else if (entity is Link) {
      Link(dstPath).createSync(entity.targetSync());
    }
  }
}
