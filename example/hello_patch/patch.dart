// hello_patch — a self-contained patch that exercises the supported Dart subset:
// classes, collection literals, closures with capture, higher-order methods,
// and a recursive-capable local function. Compile and sign it with `ejenix`,
// then apply it with `bin/apply.dart` (see run.sh and README.md).

class Product {
  final String name;
  final int price;
  Product(this.name, this.price);
}

/// Sums the price of cart items at or above [threshold], then applies a 10%
/// discount. `where` takes a closure that captures [threshold]; `discount` is a
/// local function capturing `rate`.
int discountedTotal(int threshold) {
  final cart = [
    Product('pen', 3),
    Product('notebook', 12),
    Product('desk', 240),
  ];

  final expensive = cart.where((p) => p.price >= threshold).toList();

  var total = 0;
  for (final p in expensive) {
    total = total + p.price;
  }

  final rate = 90; // captured by the closure below
  int discount(int amount) => amount * rate ~/ 100;
  return discount(total);
}

int main() => discountedTotal(10);
