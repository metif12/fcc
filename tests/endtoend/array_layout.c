/* Array layout and pointer arithmetic, which were both wrong in ways that only
 * showed up across the boundary to another compiler.
 *
 * `int a[3][5]` is an array of three rows of five. This built
 * `array(array(int, 3), 5)` — the declarator's suffixes applied left to right instead
 * of the right-to-left C gives them.
 *
 * A reversed pair of dimensions has the same *total* size and the same innermost
 * stride, and a self-consistent program reads and writes through the same reversed
 * shape, so every value came back right. Two things noticed it, and both are in here:
 *
 *   - the *row* stride, which is the stride of `&a[1]` from `&a[0]`. Anything whose
 *     layout is not this compiler's disagrees about where a row is — `int (*pa)[5] = a`
 *     and then `pa`.
 *   - `sizeof(*a)`, which is the row's own size.
 *
 * Measured on this host, tcc and gcc against vcc before the fix:
 *
 *                  tcc    vcc
 *   &a[1] - &a[0]    20    12
 *   sizeof(*a)       20    12
 *   int b[2][3][4], &b[1] - &b[0]        48    24
 *                  &b[0][1] - &b[0][0]   16     8
 *
 * Pointer arithmetic in a plain binary `+` or `-` is the second thing here, and it is
 * the one the recorded `pointer.c` suite failure was about. `int *q; q + 1` advanced one
 * byte whatever the element type: four for an `int`, eight for a `double`, one for a
 * `char` — where the `char` was right by accident and the other two were not. `q[1]`,
 * `q += 1` and `q++` all scaled, because those paths go through a different builder,
 * so `q + 1` and `q[1]` disagreed with each other inside one expression.
 */

int printf(const char *fmt, ...);

int main(void) {
  int a[3][5];
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 5; j++)
      a[i][j] = i * 10 + j;

  /* The row is twenty bytes, wherever the row starts. */
  printf("row=%d elem=%d\n", (int)((char *)&a[1] - (char *)&a[0]),
         (int)((char *)&a[0][1] - (char *)&a[0][0]));
  printf("sizeofs=%d %d %d\n", (int)sizeof(a), (int)sizeof(*a), (int)sizeof(**a));

  /* A pointer to the row type is the cross-compiler case: this is where a reversed
   * dimension turns a correct-looking program into a wrong answer, because the pointer
   * is converted from `int (*)[5]` and its target is not where the compiler thinks. */
  int (*pa)[5] = a;
  printf("via ptr=%d %d %d\n", pa[2][4], (*(pa + 2))[3], (*(a + 1))[2]);
  printf("ptr stride=%d\n", (int)((char *)(pa + 1) - (char *)pa));

  /* Three dimensions, where reversing the suffixes scrambles two strides at once. */
  int b[2][3][4];
  printf("3d=%d %d sizes=%d %d %d\n", (int)((char *)&b[1] - (char *)&b[0]),
         (int)((char *)&b[0][1] - (char *)&b[0][0]), (int)sizeof(b), (int)sizeof(*b),
         (int)sizeof(**b));

  /* One element of each class, so a scale that is hard-coded to one width is caught.
   * The arrays are initialised: reading an uninitialised local is a coin flip, and a
   * probe that reports one is a probe with no answer. */
  int ia[8] = {0};
  char ca[8] = {0};
  double da[4] = {0};
  int *ip = ia;
  char *cp = ca;
  double *dp = da;
  printf("steps=%d %d %d %d %d\n", (int)((char *)(ip + 1) - (char *)ip),
         (int)((char *)(ip - 1) - (char *)ip), (int)((char *)(cp + 1) - (char *)cp),
         (int)((char *)(dp + 1) - (char *)dp), (int)((char *)(1 + ip) - (char *)ip));
  ip[3] = 42;
  cp[3] = 7;
  dp[3] = 1.5;
  printf("subscript=%d %d %g %g %g\n", ip[3], cp[3], dp[3], *(ip + 3), *(dp + 3));
  return 0;
}