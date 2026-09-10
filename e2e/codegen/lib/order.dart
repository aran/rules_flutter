/// Another model file for aggregate codegen demonstration.
library;

part 'order.g.dart';

/// A model in a second input file, so the aggregate generator has more than
/// one source to combine into its registry.
class Order {
  /// Creates an order from the fields the generator will enumerate.
  Order(this.orderId, this.userId, this.total);

  /// Opaque order identifier.
  final String orderId;

  /// Identifier of the user who placed the order.
  final String userId;

  /// Order total, in whatever currency the caller means.
  final double total;
}
