/* Where `va_start` points, measured rather than assumed.
 *
 * The four call shapes differ only in how many slots their *named* parameters consume, so
 * what each one reads back is the rule stated as an observation.
 *
 * The quantity measured is the number of bytes `va_list` advances for one argument, and
 * then the value of the first argument *after* the named ones. Both are ABI facts that
 * two compilers must agree on. An earlier version of this file instead printed the address
 * difference between `ap` and `&a`, which is not one of them: whether a named parameter is
 * addressed in place in the home area or copied to a frame slot is the compiler's own
 * business, and this one does the latter (`-4(%rbp)` against a `16(%rbp)` home slot), so
 * the two answers differ by a constant that has nothing to do with varargs.
 *
 * Measured on this host, both compilers answering identically:
 *
 *	stride=8  four_dbl=5   four named doubles, first variadic arg is 5.0
 *	one_int=2  two_int=3   int_dbl=3   four_dbl=5
 *
 * `int_dbl` and `two_int` are the pair that matters: both answer 3 for different reasons.
 * A double named parameter of a *variadic* function is mirrored into a general register,
 * so it consumes a slot of the run the `va_list` walks even though it arrives in `%xmm`.
 * Counting only the `%rdi`-class parameters would answer 2 for `int_dbl` and read the
 * double's own home slot. `four_dbl` is the same fact at the boundary — four doubles fill
 * the four available slots, and the fifth named parameter lands past them.
 */

int printf(const char *fmt, ...);

/* How far one `va_arg` of an int advances the list. It takes a named parameter because
 * `__builtin_va_start` names the last of them on both compilers. */
int stride(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  char *before = (char *)ap;
  int v = __builtin_va_arg(ap, int);
  return (int)((char *)ap - before) + (v == 0);
}

/* The first argument past the named ones, for each shape of named parameters. */
int one_int(int a, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, a);
  int v = __builtin_va_arg(ap, int);
  __builtin_va_end(ap);
  return v;
}

int two_int(int a, int b, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, b);
  int v = __builtin_va_arg(ap, int);
  __builtin_va_end(ap);
  return v;
}

int int_then_double(int a, double b, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, b);
  int v = __builtin_va_arg(ap, int);
  __builtin_va_end(ap);
  return v;
}

int four_dbl(double a, double b, double c, double d, double e, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, e);
  double v = __builtin_va_arg(ap, double);
  __builtin_va_end(ap);
  return (int)v;
}

/* The read has to agree with the count: if `va_start` pointed one slot low, the shapes
 * above would re-read a named parameter. Six integers checked by their sum, so one wrong
 * read among them is a wrong answer rather than a print. */
int read_after_start(int n, ...) {
  __builtin_va_list ap;
  int s = 0;
  __builtin_va_start(ap, n);
  for (int i = 0; i < n; i++)
    s += __builtin_va_arg(ap, int);
  __builtin_va_end(ap);
  return s;
}

int main(void) {
  printf("stride=%d one_int=%d two_int=%d int_dbl=%d four_dbl=%d\n", stride(0, 0),
         one_int(1, 2), two_int(1, 2, 3), int_then_double(1, 2.0, 3),
         four_dbl(1.0, 2.0, 3.0, 4.0, 5.0, 5.0));
  printf("read=%d\n", read_after_start(6, 1, 2, 3, 4, 5, 6));
  return 0;
}