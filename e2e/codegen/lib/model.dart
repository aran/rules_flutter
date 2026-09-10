/// A simple model file demonstrating code generation.
///
/// The generator will parse class definitions and produce
/// a companion .g.dart file with toDebugString() extensions.
library;

part 'model.g.dart';

/// A model the per-file generator turns into a `toDebugString()` extension.
class User {
  /// Creates a user from the fields the generator will enumerate.
  User(this.name, this.age, this.email);

  /// The user's name.
  final String name;

  /// The user's age in years.
  final int age;

  /// The user's email address.
  final String email;
}

/// A second model in the same file, proving the generator handles more than
/// one class per input.
class Product {
  /// Creates a product from the fields the generator will enumerate.
  Product(this.id, this.title, this.price);

  /// Opaque product identifier.
  final String id;

  /// Human-readable product name.
  final String title;

  /// Product price, in whatever currency the caller means.
  final double price;
}
