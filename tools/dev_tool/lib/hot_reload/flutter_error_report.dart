/// A `Flutter.Error` event, kept whole.
///
/// One site in the framework sends these — `WidgetInspectorService`'s
/// `_reportStructuredError`. It serialises the error's DiagnosticsNode tree and
/// then adds two keys of its own: `errorsSinceReload`, and `renderedErrorText`
/// holding the framework's own terminal formatting, box-drawing characters
/// included.
///
/// Which means the top level of the payload *is* a serialised DiagnosticsNode —
/// `description` and the node's own fields — plus those two. Anything the
/// framework models as a property of the error, the stack trace included, is
/// nested inside `properties` as a child node (a stack arrives as a
/// `DiagnosticsStackTrace` block) rather than as a sibling key. There is no
/// top-level `stackTrace`. Reaching a stack means walking `data['properties']`,
/// which is one of the things [data] is exposed for.
///
/// Rendering is the edges' job; this type is what the core passes around.
library;

class FlutterErrorReport {
  /// The event's `extensionData.data`, verbatim.
  ///
  /// Exposed deliberately. The accessors below name the fields we currently
  /// use, but the framework sends more than that and adds to it over time — a
  /// consumer must be able to ask a question this class did not anticipate.
  final Map<String, dynamic> data;

  const FlutterErrorReport(this.data);

  /// The framework's own rendering. Convenient for a terminal, useless to code.
  String? get renderedText => _string('renderedErrorText');

  /// What went wrong, without the formatting.
  String? get description => _string('description');

  /// How many errors the app has reported since the last reload. A second
  /// failure with the count still climbing means the reload did not fix it.
  int? get errorsSinceReload {
    final value = data['errorsSinceReload'];
    return value is int ? value : null;
  }

  /// Null rather than a throw for a field of the wrong type: this path is not
  /// schema-checked, and a malformed field must not take down the reload that
  /// was reporting it.
  String? _string(String key) {
    final value = data[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  String toString() =>
      'FlutterErrorReport(${description ?? renderedText ?? 'no description'})';
}
