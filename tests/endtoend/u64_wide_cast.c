/* An unsigned 64-bit value above 2^63 converted to a double, which cannot go
 * through `cvtsi2sd` — that instruction reads its input as signed, so anything
 * with the top bit set would come back negative.
 *
 * The conversion is emitted as a raw instruction sequence in the middle of an
 * arbitrary expression, on the same principle that the callee-saved registers
 * turn on: whatever the sequence clobbers, the caller loses. The slow path
 * originally worked in `%rdi`, which is non-volatile on this target, and the
 * generated file showed it as five unwritten-for writes of a register nothing
 * had saved. It now works in `%rcx`, from the same caller-saved scratch set the
 * inline-asm operands use.
 *
 * The values are compared by equality rather than by printing, and that is
 * deliberate. A `printf` of these numbers through this target's stdio comes back
 * as `9223372036854775800.0` where gcc prints `9223372036854775808.0`, which is
 * a formatting limitation of a different kind and is recorded in docs/PLAN.md
 * rather than papered over here. Compare first and print second: the cast is
 * then measured on its own, and the narrow values below are the ones every
 * formatter agrees on.
 */

#include <stdio.h>

int main(void) {
  unsigned long long big = 0x8000000000000001ULL;
  unsigned long long huge = 0xFFFFFFFFFFFFFFFFULL;
  unsigned long long edge = 0x7FFFFFFFFFFFFFFFULL;

  double a = (double)big;
  double b = (double)huge;
  double c = (double)edge;

  /* 2^63 is the first value the signed instruction cannot represent. */
  printf("a=%d %d %d\n", a == 9223372036854775808.0, a > 0.0, a == 9223372036854775808.0 * 1.0);
  /* 2^64 - 1 is the last one. */
  printf("b=%d %d\n", b == 18446744073709551616.0, b > a);
  /* The top of the range that needs no trick at all. */
  printf("c=%d %d\n", c == 9223372036854775808.0, c == a);

  /* And the conversions again with work between them, so the scratch register is
   * not simply read back through the same expression. */
  double d = (double)big;
  printf("d=%d\n", d / 4611686018427387904.0 == 2.0);
  double e = (double)huge;
  printf("e=%d\n", e / 9223372036854775808.0 == 2.0);
  return 0;
}
