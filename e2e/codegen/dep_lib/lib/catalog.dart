/// A dependency package whose hand-written source IMPORTS a generated
/// standalone library (catalog.g.dart) — as opposed to a `part of`. This
/// exercises the import-as-library codegen shape (the rest of the e2e only
/// covers `part of`).
library;

import 'package:dep_lib/catalog.g.dart';

/// A model whose generated companion arrives as an imported library rather
/// than a `part`.
class Catalog {
  /// Creates a catalog with the given [name].
  const Catalog(this.name);

  /// The catalog's name.
  final String name;

  /// Joins the field names the generator discovered in this file. Editing the
  /// fields below (a codegen INPUT change) regenerates catalog.g.dart, so the
  /// new field list is observable on a hot reload.
  String get fieldSummary => catalogFields.join(',');
}
