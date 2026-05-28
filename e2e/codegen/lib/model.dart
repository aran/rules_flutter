/// A simple model file demonstrating code generation.
///
/// The generator will parse class definitions and produce
/// a companion .g.dart file with toDebugString() extensions.

part 'model.g.dart';

class User {
  final String name;
  final int age;
  final String email;

  User(this.name, this.age, this.email);
}

class Product {
  final String id;
  final String title;
  final double price;

  Product(this.id, this.title, this.price);
}
