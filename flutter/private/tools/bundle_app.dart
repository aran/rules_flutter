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
///     {"src": "/path/to/dir", "dst": "relative/path/in/output",
///      "exclude": ["*.deps"]},
///     ...
///   ],
///   "extracts": [
///     {"src": "/path/to/dir/file.json", "dst": "declared/output/path"},
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

  final config =
      json.decode(File(args[1]).readAsStringSync()) as Map<String, dynamic>;
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
    final exclude = ((copy['exclude'] as List<dynamic>?) ?? [])
        .cast<String>()
        .toList();
    _copyDirectory(Directory(src), Directory(dst), exclude);
  }

  // Process extracts: lift one file out of a copied tree to a path the build
  // declared for it. Separate from `copies` because the destination is a
  // declared output of its own — an execroot-relative path, which resolves
  // because the action runs at the execroot — rather than a place inside the
  // bundle.
  final extracts = (config['extracts'] as List<dynamic>?) ?? [];
  for (final extract in extracts) {
    final src = extract['src'] as String;
    final dst = extract['dst'] as String;
    if (!File(src).existsSync()) {
      // The build declared this output, so producing nothing would fail the
      // action anyway — but with Bazel's generic "not all outputs were
      // created" rather than the name of the file that was missing.
      throw FileSystemException('extract source not found', src);
    }
    File(dst).parent.createSync(recursive: true);
    File(src).copySync(dst);
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

void _copyDirectory(Directory src, Directory dst, List<String> exclude) {
  dst.createSync(recursive: true);
  for (final entity in src.listSync(recursive: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (_excluded(name, exclude)) continue;
    final dstPath = '${dst.path}/$name';
    if (entity is File) {
      entity.copySync(dstPath);
    } else if (entity is Directory) {
      _copyDirectory(entity, Directory(dstPath), exclude);
    } else if (entity is Link) {
      Link(dstPath).createSync(entity.targetSync());
    }
  }
}

/// Whether [name] matches any entry of [exclude].
///
/// Two forms only: an exact basename, or a `*.<suffix>` extension pattern.
/// Anything else throws rather than quietly matching nothing — a pattern that
/// silently never fires would let the file it was meant to keep out of the
/// bundle ship anyway, which is the failure this list exists to prevent.
bool _excluded(String name, List<String> exclude) {
  for (final pattern in exclude) {
    // The suffix is checked for wildcards BEFORE it is used. Testing only the
    // `*.` prefix would let `*.info.*` through the extension branch, where it
    // matches nothing and reports nothing — the exact silence this validation
    // exists to prevent, reintroduced by the validation's own shortcut.
    final suffix = pattern.startsWith('*.') ? pattern.substring(1) : null;
    final rest = suffix ?? pattern;
    if (rest.contains('*') || rest.contains('?')) {
      throw ArgumentError.value(
        pattern,
        'exclude',
        'only an exact basename or a `*.<suffix>` pattern is supported',
      );
    }
    if (suffix != null ? name.endsWith(suffix) : name == pattern) return true;
  }
  return false;
}
