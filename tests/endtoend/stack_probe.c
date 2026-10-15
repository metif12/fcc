/* A frame larger than a page, which has to be reached one page at a time.
 *
 * Windows x64 requires a guard probe for any frame over a single page, and this is
 * not an optimisation. `sub $N, %rsp` on its own moves the stack pointer past the
 * guard page, and the first store into the frame lands on a page the system never
 * committed: an access violation. A frame of one page or less is safe without it,
 * which is why this went unnoticed — every local in the suite and in
 * tests/endtoend/ was smaller than the threshold.
 *
 * The reference reaches for `___chkstk_ms` here. This generator emits the probe
 * inline instead, because that symbol lives in libgcc and nothing here can assume
 * it was linked.
 *
 * The two shapes below are deliberately different. The first is a single frame,
 * with no recursion at all, so the stack is at its starting depth — it is the case
 * that shows the missing probe with nothing else involved. The second recurses, so
 * the same frame is entered many times over and a probe that descended wrongly
 * would fault at some depth rather than immediately.
 */

#include <stdio.h>

/* Exactly one page of local. Below the threshold, and therefore safe either way.
 * Every element read below is written first, because an uninitialised local is
 * undefined and the two compilers would then disagree for a reason that has nothing
 * to do with the probe. */
static int small(int n) {
  char f[4000];
  for (int i = 0; i < 4000; i++) f[i] = (char)(i & 0x3f);
  f[0] = (char)n;
  f[3999] = (char)(n * 2);
  int s = 0;
  for (int i = 0; i < 4000; i += 997) s += f[i];
  return s;
}

/* One frame, no recursion, well over the threshold. */
static void fill(char *f) {
  f[0] = 1;
  f[65535] = 2;
  f[40000] = 3;
}

static int big_once(void) {
  char f[65536];
  fill(f);
  return f[0] + f[65535] + f[40000];
}

/* The same frame, entered twenty-four times over. */
static int recurse(int depth) {
  char frame[65536];
  frame[0] = (char)depth;
  frame[65535] = (char)(depth * 2);
  if (depth > 0) return frame[0] + frame[65535] + recurse(depth - 1);
  return 0;
}

/* And a value that forces the remainder path, because it is not a whole number of
 * pages and so does not land on the last probe. */
static int odd_size(void) {
  char f[65536 + 64];
  f[0] = 4;
  f[65536 + 63] = 5;
  return f[0] + f[65536 + 63];
}

int main(void) {
  printf("small=%d\n", small(7));
  printf("big_once=%d\n", big_once());
  printf("recurse=%d\n", recurse(24));
  printf("odd_size=%d\n", odd_size());
  return 0;
}
