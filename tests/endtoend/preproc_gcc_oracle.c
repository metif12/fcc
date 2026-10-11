/* The shapes tcc cannot be the oracle for, measured against gcc instead.
 *
 * `tools/probe/probe.v` uses tcc as the oracle because tcc is the compiler vcc has to
 * agree with on this host — same headers, same objects, same C library. Three shapes
 * fall outside what tcc can measure, and each was BLOCKED rather than compared, which
 * is a statement about the probe and not about the compiler:
 *
 *   - tcc predates C23 and does not implement `__VA_OPT__` at all.
 *   - tcc reads a pp-number used as a macro argument as an invalid number, where
 *     [C11 6.4.8] makes it a single preprocessing token.
 *   - tcc rejects `#if F` for a function-like macro not followed by `(`, where
 *     [C11 6.10.3p9] makes it an ordinary identifier.
 *
 * So this file is compared against gcc, and the probe prints which oracle answered.
 * The fallback is the point: a shape the primary oracle refuses is still measurable,
 * and a program *both* refuse is still BLOCKED.
 *
 * gcc is the oracle; no expected value is written down.
 */

int printf(const char *fmt, ...);

int sprintf(char *buf, char *fmt, ...);
int g(int x) { return x * 3; }

#define TWO 2

#define M30(buf, fmt, ...) sprintf(buf, fmt __VA_OPT__(,) __VA_ARGS__)
/* Present only when the variadic part is non-empty, so `ADD()` is `0` and `ADD(1)`
 * is `0 + 1`. */
#define ADD(...) 0 __VA_OPT__(+ 1)
/* The content is macro-expanded, which [C11 6.10.5.1p7] requires and which is why
 * `TWICE()` is `0` and `TWICE(1)` is `0 + TWO`. */
#define TWICE(...) 0 __VA_OPT__(+ TWO)
/* Nested parens inside the content do not close it early: the content is the whole
 * `+ g(2)`, so `PAREN()` is `0` and `PAREN(1)` is `0 + g(2)`. */
#define PAREN(...) 0 __VA_OPT__(+ g(2))
#define CONCAT(a, b) a##b

int main(void) {
  char buf[100];

  /* --- `__VA_OPT__`: a comma that appears only when there is something to follow --- */

  /* No variadic arguments: the `__VA_OPT__` contributes nothing, so the call has two
   * arguments and matches its format string. */
  M30(buf, "foo");
  printf("opt_empty=%s\n", buf);

  /* One variadic argument: the comma is present. */
  M30(buf, "foo%d", 3);
  printf("opt_one=%s\n", buf);

  /* Two: still one comma, and both arguments follow. */
  M30(buf, "foo%d%d", 3, 5);
  printf("opt_two=%s\n", buf);

  /* Absent, present, and content-expanded. */
  printf("opt_add=%d %d\n", ADD(), ADD(1));
  printf("opt_twice=%d %d\n", TWICE(), TWICE(1));
  printf("opt_paren=%d %d\n", PAREN(), PAREN(1));

  /* --- a pp-number is one token, so a paste with it works --- */

  /* `0zz` is a pp-number per [C11 6.4.8]: a digit followed by identifier-nondigits.
   * Because it is one token, pasting `f` with it produces the identifier `f0zz` —
   * which is what makes `CONCAT(f, 0zz)` resolve to the local below. Had `0zz` lexed
   * as the number `0` followed by the identifier `zz`, the paste would have produced
   * `f0` plus `zz` and the variable would have been undeclared. */
  {
    int f0zz = 7;
    printf("pp_paste=%d\n", CONCAT(f, 0zz));
  }

  /* --- `#if F` where F is function-like but not followed by `(` --- */

  /* An ordinary identifier, so it evaluates to 0. [C11 6.10.3p9]. */
#define F() 1
#if F
  printf("if_no_paren=yes\n");
#else
  printf("if_no_paren=no\n");
#endif

  /* And the same name invoked properly still expands, which is the contrast. */
#if F()
  printf("if_fn_like=yes\n");
#else
  printf("if_fn_like=no\n");
#endif
  return 0;
}
