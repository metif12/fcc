/* The end-to-end variadic test.
 *
 * This is the smallest thing in the project that can *disprove* a claim about
 * `va_list`. Everything else - the 264 unit tests, the five working programs - has
 * two sides produced by the same compiler, so they agree with each other even when
 * both are wrong. A variadic callee that passes its `va_list` to the real `vprintf`
 * crosses that boundary: `vprintf` is a mingw library function that reads the
 * `va_list` according to the *platform's* ABI and knows nothing about vcc.
 *
 * The runner is `tools/probe/probe.v`, which compiles this file with vcc and with
 * tcc and compares stdout and the exit code. Both builds go through gcc for the
 * link, so the only thing that differs is which compiler produced the assembly.
 *
 * Measured, on this host, from both compilers and byte for byte the same:
 *
 *	sum6=21 sum3=60 dsum=7 str=hello dbl=3.25 i=77 forward: i=42 d=2.5 s=ok
 *	first=one second=one sprintf=5/1.5
 *
 * `__builtin_va_list` is spelled out rather than reached through `<stdarg.h>`, for
 * one reason: the header is twelve lines of `#define`s onto the builtins, and a
 * failure inside it would say nothing about whether the builtins themselves work.
 * The chibicc suite covers the header path separately.
 *
 * Comments use plain ASCII punctuation throughout, so that nothing in this file
 * depends on what a compiler accepts in a comment.
 */

int printf(const char *fmt, ...);
int vprintf(const char *fmt, void *ap);
int sprintf(char *buf, const char *fmt, ...);

/* The integer shapes a `va_arg` has to get right: all in registers, crossing from
   the registers into the caller's stack, and both at once. */
int sum6(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  int s = 0;
  for (int i = 0; i < n; i++)
    s += __builtin_va_arg(ap, int);
  __builtin_va_end(ap);
  return s;
}

/* Floating point is the case a copied System V implementation gets wrong and a
   hand-written one gets wrong differently: the value has to come out of the general
   register the caller mirrored it into, not out of `%xmm`. */
double dsum(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  double s = 0;
  for (int i = 0; i < n; i++)
    s += __builtin_va_arg(ap, double);
  __builtin_va_end(ap);
  return s;
}

/* Interleaved classes: a pointer, a double, an int. Each `va_arg` has to step over
   a different class, so a stride that happens to be right for one is caught by the
   others. */
void mixed(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  printf("  str=%s\n", __builtin_va_arg(ap, char *));
  printf("  dbl=%g\n", __builtin_va_arg(ap, double));
  printf("  i=%d\n", __builtin_va_arg(ap, int));
  __builtin_va_end(ap);
}

/* The decisive one. `vprintf` is mingw's, and it walks the `va_list` itself. */
void forward(const char *fmt, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, fmt);
  vprintf(fmt, ap);
  __builtin_va_end(ap);
}

/* `va_copy` makes an independent cursor over the same arguments, so reading through
   one must not move the other. The order below is what proves it: `ap` is read
   *first*, so a `va_copy` that aliased instead of copying would leave `dup` already
   advanced and `second` would print the wrong string.

   Both print "one", because both cursors start at the same argument - that is the
   correct answer, and it is what tcc answers. The test is that they are *both* at
   the first argument, not that they differ. */
void copied(const char *fmt, ...) {
  __builtin_va_list ap, dup;
  __builtin_va_start(ap, fmt);
  __builtin_va_copy(dup, ap);
  printf("  first=%s\n", __builtin_va_arg(ap, char *));
  printf("  second=%s\n", __builtin_va_arg(dup, char *));
  __builtin_va_end(ap);
}

int main(void) {
  printf("sum6=%d\n", sum6(6, 1, 2, 3, 4, 5, 6));
  printf("sum3=%d\n", sum6(3, 10, 20, 30));
  printf("dsum=%g\n", dsum(3, 1.5, 2.5, 3.0));
  mixed(0, "hello", 3.25, 77);
  printf("forward: ");
  forward("i=%d d=%g s=%s\n", 42, 2.5, "ok");
  copied("x", "one", "two");
  char buf[64];
  sprintf(buf, "sprintf=%d/%g", 5, 1.5);
  printf("%s\n", buf);
  return 0;
}