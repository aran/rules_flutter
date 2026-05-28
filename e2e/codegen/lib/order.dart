/// Another model file for aggregate codegen demonstration.

part 'order.g.dart';

class Order {
  final String orderId;
  final String userId;
  final double total;

  Order(this.orderId, this.userId, this.total);
}
