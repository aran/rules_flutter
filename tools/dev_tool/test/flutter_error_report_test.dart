import 'package:flutter_bazel_dev_tool/hot_reload/flutter_error_report.dart';
import 'package:test/test.dart';

/// A `Flutter.Error` event arrives structured — a DiagnosticsNode tree.
/// Reducing it to the pre-rendered string alone puts the framework's own
/// terminal formatting, box-drawing characters and all, inside a JSON protocol
/// response that nothing can then ask which app, which frame, or how many
/// errors have accrued.
void main() {
  /// Shaped like the real payload, and held to it key by key.
  ///
  /// `WidgetInspectorService._reportStructuredError` serialises the error's
  /// DiagnosticsNode — which is where `description` comes from — and adds
  /// `errorsSinceReload` and `renderedErrorText`. Those three are the whole of
  /// what a `Flutter.Error` carries at the top level.
  ///
  /// There is no top-level `stackTrace`: the framework nests a stack inside
  /// `properties` as a `DiagnosticsStackTrace` child. A fixture documented as
  /// real-shaped has to stay real-shaped, or it certifies the code that reads
  /// it.
  const payload = <String, dynamic>{
    'renderedErrorText':
        '══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞══\n'
        "The following _TypeError was thrown building CodegenApp(dirty):\n"
        "type 'Null' is not a subtype of type 'String'",
    'description': "type 'Null' is not a subtype of type 'String'",
    'errorsSinceReload': 3,
  };

  group('FlutterErrorReport', () {
    test('keeps every sibling of the rendered text', () {
      final report = FlutterErrorReport(payload);
      expect(report.renderedText, contains('EXCEPTION CAUGHT'));
      expect(
        report.description,
        "type 'Null' is not a subtype of type 'String'",
      );
      expect(report.errorsSinceReload, 3);
    });

    test(
      'exposes the raw payload so an unanticipated field is still reachable',
      () {
        // A consumer must be able to ask a question the producer did not think
        // of.
        final report = FlutterErrorReport({...payload, 'library': 'widgets'});
        expect(report.data['library'], 'widgets');
      },
    );

    test('tolerates a payload carrying only a description', () {
      final report = FlutterErrorReport(const {
        'description': 'something went wrong',
      });
      expect(report.renderedText, isNull);
      expect(report.description, 'something went wrong');
      expect(report.errorsSinceReload, isNull);
    });

    test(
      'an empty payload reports nothing rather than inventing a sentence',
      () {
        final report = FlutterErrorReport(const {});
        expect(report.renderedText, isNull);
        expect(report.description, isNull);
        expect(report.data, isEmpty);
      },
    );

    test('ignores fields of the wrong type instead of throwing', () {
      // The VM service is not schema-checked on this path; a malformed field
      // must not take down the reload that reported it.
      final report = FlutterErrorReport(const {
        'description': 42,
        'errorsSinceReload': 'lots',
      });
      expect(report.description, isNull);
      expect(report.errorsSinceReload, isNull);
    });
  });
}
