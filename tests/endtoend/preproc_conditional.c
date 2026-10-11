/* Conditional directives, stringification and the integer builtins, across the
 * boundary to another compiler.
 *
 * Three defects are pinned here, each of which was invisible to every other test:
 *
 * - `#if` never expanded its operand at all. `#if 5` was correct because 5 is a
 *   literal, and every `#if` naming a macro took its `#else` branch, because an
 *   unknown identifier evaluates to 0 and nothing expanded it.
 * - The operand of `defined` must *not* be expanded, per [C11 6.10.1p4] — the same
 *   clause replaces macro invocations in the controlling constant expression
 *   "except for those macro names modified by the defined unary operator".
 *   `#if defined(M) && M` is `#if` in C, and expanding unconditionally turns it
 *   into `#if defined(5) && 5`, which answers 1 rather than 5.
 * - `has_space` was sticky. It is set by whitespace and was never cleared, so one
 *   space anywhere in a file set it for every token after it, and `#` stringizing
 *   rendered that as a space between tokens that had none: `S(a!b)` produced
 *   `"a ! b"` where C gives `"a!b"`.
 *
 * tcc is the oracle; no expected value is written down.
 */

int printf(const char *fmt, ...);

#define S(x) #x
#define M12(x) S(x)
#define M13(x) M12(foo. x)
#define M 5

int main(void) {
  /* `#if` with a macro in the operand. All four branches differ. */
#if M
  printf("if_literal_macro=yes\n");
#else
  printf("if_literal_macro=no\n");
#endif
#if M - 5
  printf("if_arith=yes\n");
#else
  printf("if_arith=no\n");
#endif
#if (M)
  printf("if_paren=yes\n");
#else
  printf("if_paren=no\n");
#endif
#if M + 0
  printf("if_arith_live=yes\n");
#else
  printf("if_arith_live=no\n");
#endif

  /* A function-like macro needs its `(` in the same token list, which is why
   * `expand_condition` expands whole runs rather than one token at a time. */
#define F() 1
#if F()
  printf("if_fn_like=yes\n");
#else
  printf("if_fn_like=no\n");
#endif
  /* Not followed by `(`, so it is an ordinary identifier and evaluates to 0 — which is
   * what C11 6.10.3p9 requires and what gcc does. This is *not* asserted here, because
   * tcc rejects the shape outright with `invalid constant in preprocessor expression`
   * and a differential test needs an oracle that compiles it. fcc's answer is pinned by
   * the unit tests instead. */

  /* `defined`'s operand is excluded from expansion, and the rest is not.
   * `defined(M) && M` is `1 && 5` — the `#if` branch. */
#if defined(M) && M
  printf("defined_and_macro=yes\n");
#else
  printf("defined_and_macro=no\n");
#endif
  /* Both spellings. */
#if defined M && M
  printf("defined_bare=yes\n");
#else
  printf("defined_bare=no\n");
#endif
  /* And the arithmetic form, where `defined(M) - 1` is zero. */
#if defined(M) - 1
  printf("defined_minus_one=yes\n");
#else
  printf("defined_minus_one=no\n");
#endif
  /* A macro that is not defined still answers 0. */
#if defined(NO_SUCH_MACRO)
  printf("defined_absent=yes\n");
#else
  printf("defined_absent=no\n");
#endif

  /* `#elif` takes the same path as `#if`. */
#if M - 5
  printf("elif_first=yes\n");
#elif M
  printf("elif_second=yes\n");
#else
  printf("elif_none=yes\n");
#endif

  /* Stringification: no space is invented between tokens that had none, and a real one
   * is kept. `M13(x M12)` in chibicc's own suite needs both halves. */
  printf("no_space=%s\n", S(a!b));
  printf("one_space=%s\n", S(a b));
  printf("dot_space=%s\n", M13(bar));
  printf("builtin_line=%s\n", S(__LINE__));

  /* The integer builtins. `__LINE__` is an integer constant, not a string, so it can
   * initialise an `int`; `__COUNTER__` starts at 0. */
  int line = __LINE__;
  printf("line_is_int=%d\n", line > 0);
  printf("counter=%d\n", __COUNTER__ + __COUNTER__ * 10 + __COUNTER__ * 100);
  printf("stdc=%d\n", __STDC__);
  printf("date_len=%d time_len=%d\n", (int)sizeof(__DATE__), (int)sizeof(__TIME__));
  return 0;
}
