/* `sizeof` of a type name containing a variable-length array.
 *
 * [C11 6.7.6.2p4] only a type with no variable part has a constant size, and the three
 * shapes here are the ways that fails:
 *
 *   sizeof(char[n])      the VLA itself           -> n
 *   sizeof(char[2][n])   an array *of* one        -> 2 * n
 *   sizeof(int[n][5])    a VLA *of* a fixed array -> n * 20
 *
 * The middle one is the case that was fatal: a bare VLA type name reached the backend as
 * an untyped node and was reported as `operator with no left operand`, a diagnostic
 * naming the arithmetic rather than the type that could not be sized. The outer two were
 * wrong rather than fatal, and silently — an array whose element is a VLA has a constant
 * *length* and a run-time *element*, so answering `array_len * 8` from the placeholder
 * width a VLA carries gave 40 for `int[n][5]` where the answer is 100.
 *
 * The last two are controls: `int[2][3]` has no variable part and must still be a plain
 * constant, and `int[n][n + 1]` has two extents so it catches a fix that computed one of
 * them and then reused it for the other.
 */

int printf(const char *fmt, ...);

int main(void) {
  int n = 5;
  printf("char[2][n]  = %d\n", (int)sizeof(char[2][n]));
  printf("char[n]     = %d\n", (int)sizeof(char[n]));
  printf("int[n][5]   = %d\n", (int)sizeof(int[n][5]));
  printf("int[5][n]   = %d\n", (int)sizeof(int[5][n]));
  printf("double[n]   = %d\n", (int)sizeof(double[n]));
  printf("int[n][n+1] = %d\n", (int)sizeof(int[n][n + 1]));
  printf("int[2][3]   = %d\n", (int)sizeof(int[2][3]));
  /* And `sizeof` of a *declared* VLA object, which reads a local computed at its
   * declaration rather than re-evaluating the extent. `x` is allocated for 3*5 ints
   * and its size is 60. */
  int m = 3;
  int x[m][5];
  printf("declared    = %d\n", (int)sizeof(x));
  printf("elem        = %d\n", (int)sizeof(*x));
  return 0;
}