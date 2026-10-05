/* The three `va_arg` strides, each against the value it must produce.
 *
 * The type decides the stride at compile time, so this is the case where a
 * front-end implementation and a backend one genuinely differ — and where a wrong stride
 * is silent for every value except the ones it displaces. The sequences below are chosen
 * so that a stride of 8 where 16 belongs reads the second half of the struct, and a
 * stride of 16 where 8 belongs skips an argument entirely.
 *
 * Note `long long` rather than `long`: `long` is *four* bytes on this target, measured,
 * so `struct { long a; long b; }` is one eight-byte slot and exercises nothing. */

int printf(const char *fmt, ...);

struct Pair16 { long long a; long long b; };

/* Two eightbytes: two consecutive slots, stride 16. The int after it is what proves
 * the stride — a stride of 8 would leave the next read on the struct's second half. */
void stride16(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  struct Pair16 s = __builtin_va_arg(ap, struct Pair16);
  int i = __builtin_va_arg(ap, int);
  double d = __builtin_va_arg(ap, double);
  printf("  stride16: %lld/%lld | %d | %g\n", s.a, s.b, i, d);
  __builtin_va_end(ap);
}

/* Wider than two eightbytes: [MS x64 2.2.5] passes anything larger by reference, so the
 * slot holds an address and the stride is one slot. It has its own file because of how
 * it gets there — see the note at the top of `va_arg_wide.c`.
 *
 * The value comes from a named local rather than a compound literal, because a
 * compound literal of this size is a separate pre-existing defect. */

/* Ten of each class, so the walk crosses from the register area into the caller's stack
 * in the middle of a sequence. */
void ten_ints(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  long long sum = 0;
  for (int i = 0; i < n; i++)
    sum += __builtin_va_arg(ap, long long);
  printf("  ten_ints: %lld\n", sum);
  __builtin_va_end(ap);
}

void ten_doubles(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  double sum = 0;
  for (int i = 0; i < n; i++)
    sum += __builtin_va_arg(ap, double);
  printf("  ten_doubles: %g\n", sum);
  __builtin_va_end(ap);
}

int main(void) {
  stride16(1, (struct Pair16){7, 9}, 30, 1.5);
  ten_ints(10, 1LL, 2LL, 3LL, 4LL, 5LL, 6LL, 7LL, 8LL, 9LL, 10LL);
  ten_doubles(10, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0);
  return 0;
}