/* `##` boundary pasting, chains and placemarkers, across the boundary to another
 * compiler.
 *
 * The preprocessor's paste used to join its two operands *whole*, so `paste(1+i,3)`
 * came out as the single preprocessing token `1+i3` and the parser then rejected it
 * with `undefined variable "1+i3"` — a message that names no defect at all. Chained
 * `x##y##z` was worse: the second `##` matched no branch, fell through to the
 * ordinary-token path, and `paste4(1,2,3)` expanded to `12 ## 3`, which the parser
 * reported as `expected ",", found "##"` followed by `too many arguments` against
 * `assert`'s arity.
 *
 * Every value here is compared against what tcc computes for the same program, which is
 * the only thing that can see a token boundary both compilers get wrong in agreement.
 * No expected value is written down: tcc *is* the expected value.
 *
 * The chosen shapes keep the pasted boundary a *valid* token. `2` pasted with `j` is the
 * pp-number `2j`, which is invalid C and which both compilers rightly reject — that
 * case belongs to the invalid-spelling tests, not here.
 */

int printf(const char *fmt, ...);

#define CONCAT(a, b) a##b
#define CONCAT3(x, y, z) x##y##z
#define STR(x) #x
#define FORWARD(x) STR(x)

/* The variable has to be declared before the macro that names it, exactly as chibicc's
 * macro.c does: after `#define M2 M2 + 3`, the identifier `M2` is a macro and
 * `int M2 = 5;` would expand to `int M2 + 3 = 5;`. The copy the body leaves behind is
 * *not* replaced, so it resolves to this variable. */
int M2 = 5;

#define M2 M2 + 3

int main(void) {
  int a = 10;
  int b = 1;
  int c = 200;
  int d = 3;
  int bc = 20;
  int bcd = 300;
  int ca = 2010;
  /* Two placemarkers joined is nothing, so the paste expands away and this is `0`. */
  int nothing = CONCAT(,) 0;

  /* The boundary only. `a+b` pasted with `c` leaves the `+` either side, so this is
   * `a + bc` and not the identifier `a+bc`. */
  printf("left_multi=%d\n", CONCAT(a + b, c));
  printf("right_multi=%d\n", CONCAT(c, a + b));
  printf("both_multi=%d\n", CONCAT(a + b, c + d));

  /* Chains, which used to leave a literal `##` token in the output. */
  printf("chain=%d\n", CONCAT3(1, 2, 3));
  /* Left-associative, and it is observable: `a+b` and `c` paste to `bc`, and that
   * result's last token pastes with `d` to give `bcd`. */
  printf("chain_spaced=%d\n", CONCAT3(a + b, c, d));

  /* Placemarker: an empty operand contributes no boundary token. */
  printf("empty_right=%d\n", CONCAT(5,));
  printf("empty_left=%d\n", CONCAT(, 5));
  printf("both_empty=%d\n", nothing);

  /* The self-reference rule. `M2` expands once, and the copy of `M2` its body leaves
   * behind is not replaced again — so this is `M2 + 3` where the second `M2` is the
   * variable, and not a second expansion. */
  printf("blue=%d\n", M2);

  /* A macro used as a bare argument is expanded before substitution; the same macro used
   * as a `#` operand is not. Both halves, one line apart, and they differ. */
  printf("raw=%s\n", STR(M2));
  printf("forwarded=%s\n", FORWARD(M2));
  return 0;
}
