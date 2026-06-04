/// A dependency package whose hand-written source IMPORTS a generated standalone
/// library (catalog.g.dart) — as opposed to a `part of`. This exercises the
/// import-as-library codegen shape (the rest of the e2e only covers `part of`).
import 'catalog.g.dart';

class Catalog {
  final String name;

  const Catalog(this.name);

  /// Joins the field names the generator discovered in this file. Editing the
  /// fields below (a codegen INPUT change) regenerates catalog.g.dart, so the
  /// new field list is observable on a hot reload.
  String get fieldSummary => catalogFields.join(',');
}
