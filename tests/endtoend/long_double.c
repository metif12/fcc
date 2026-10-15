/* A `long double` is a `double` on this target — 8 bytes, measured against tcc,
 * which passes one exactly as it passes a `double`. Every value here is small
 * on purpose: the only magnitudes printed are ones every formatter agrees on,
 * because wide-double `printf` digits diverge between C libraries for reasons
 * that have nothing to do with this file.
 *
 * Each block below is a path that used to take the x87 ten-byte route while the
 * eight-byte layout never held the value: loading a literal, storing a local,
 * arithmetic, negation, comparison, passing by value to a function, returning
 * one, and handing one to a variadic call. */

#include <stdio.h>

static long double add_ld(long double a, long double b) { return a + b; }
static double take_ld(long double x) { return (double)x; }

int main(void) {
  /* Literals and locals. */
  long double a = 1.0L;
  long double b = 3.0L;
  printf("lit=%.1Lf %.1Lf\n", a, b);

  /* Arithmetic and the value it leaves behind. */
  long double c = a / b;
  printf("div=%.15Lf\n", c);
  printf("sum=%.1Lf\n", add_ld(a, b));

  /* Negation, which had its own path. */
  printf("neg=%.1Lf\n", -a);
  printf("negdiv=%.15Lf\n", -(a / b));

  /* Comparison, which had another. */
  printf("cmp=%d %d %d\n", c == c, c > 0.25L, c < 0.5L);

  /* By value through a call, and back out of one. */
  printf("nonvariadic=%.4f\n", take_ld(c));
  printf("roundtrip=%.15Lf\n", add_ld(c, 0.0L));

  /* Mixed with integers, so the register counters for the two classes advance
   * together the way a real call does. */
  printf("mixed=%d %.1Lf %d %.1Lf\n", 1, a, 2, b);
  return 0;
}
