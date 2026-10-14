/* Bitfields, including one wider than an int — the shape that produced invalid assembly.
 *
 * A 40-bit field needs the mask `(1 << 40) - 1` = 1099511627775, and the generator
 * emitted it as `and $1099511627775, %rdi`. `and` only accepts a sign-extended 32-bit
 * immediate; `mov` does take the full width, which is what `movabs` is for. GNU `as`
 * rejected the whole translation unit with `operand type mismatch for 'and'`, so this
 * shape did not merely compute wrong — it did not assemble.
 *
 * The mask is staged through a register now, so the `and` is between registers. The
 * output is a different function than the one stored, which is the assignment value.
 */

int printf(const char *fmt, ...);

/* A narrow field: the mask fits an immediate, so the old code was fine here. */
struct narrow { unsigned lo : 4; unsigned hi : 28; };
/* A wide field: the mask does not, and this is the one that broke. */
struct wide { unsigned lo : 4; unsigned hi : 28; unsigned long long big : 40; };
/* One that crosses a storage-unit boundary, which is the other way a wide field goes. */
struct split { unsigned a : 20; unsigned long long b : 40; unsigned c : 4; };

int main(void) {
  struct narrow n = {1, 2};
  printf("narrow=%u %u\n", n.lo, n.hi);
  n.lo = 15;
  n.hi = 0xabcde;
  printf("narrow2=%u %u\n", n.lo, n.hi);

  struct wide w = {1, 2, 3};
  printf("wide=%u %u %llu\n", w.lo, w.hi, w.big);
  w.big = 0xdeadbeefLL;
  w.lo = 9;
  printf("wide2=%llu %u\n", w.big, w.lo);
  /* The neighbours have to survive the merge. */
  printf("wide3=%u %u\n", w.hi, w.lo);

  struct split s = {1, 2, 3};
  printf("split=%u %llu %u\n", s.a, s.b, s.c);
  s.b = 0xfeedfaceLL;
  printf("split2=%llu %u %u\n", s.b, s.a, s.c);
  return 0;
}
