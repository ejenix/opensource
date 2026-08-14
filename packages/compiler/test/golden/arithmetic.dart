int add(int a, int b) => a + b;

int fib(int n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}

double average(int a, int b) => (a + b) / 2;
