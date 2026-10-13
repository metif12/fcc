/* The whole of the C standard library, plus the inline `__asm__` that math.h needs.
 *
 * `tcc/tcc_libm.h` implements `rint` and friends with inline assembly, because the
 * x87 rounding instruction is the only way to get C99's rounding-to-nearest semantics:
 *
 *	__asm__ __volatile__ ("fldl %1\n" "fistpl %0" : "=m" (retval) : "m" (x));
 *
 * `"m" (x)` is `%1` and `"=m" (retval)` is `%0`, and the template spells `%N` where a
 * memory reference belongs — so `fldl %1` loads x's *value*, not its address. Ten of the
 * header's functions need it, which is what kept `math.h` and `tgmath.h` out.
 *
 * Every value here is compared against what gcc computes for the same program.
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <time.h>

int main(void) {
  /* The inline-asm functions, which are the ones that needed the feature. */
  printf("rint=%.1f %.1f %.1f\n", rint(2.5), rint(-2.5), rint(2.4));
  printf("rintf=%.1f %.1f\n", rintf(2.5f), rintf(-3.5f));
  printf("lrint=%ld %ld\n", lrint(2.7), lrint(-2.7));
  printf("lrintf=%ld %ld\n", lrintf(2.2f), lrintf(2.8f));

  /* Externally-linked functions from the same header, which only compile at all once
   * the target macros are defined. */
  printf("sqrt=%.4f\n", sqrt(2.0));
  printf("pow=%.0f\n", pow(3.0, 4.0));
  printf("floor=%.1f ceil=%.1f\n", floor(2.7), ceil(2.1));
  printf("fabs=%.1f fmax=%.1f\n", fabs(-3.5), fmax(1.5, 2.5));
  printf("hypot=%.4f\n", hypot(3.0, 4.0));
  printf("trunc=%.1f round=%.1f\n", trunc(2.7), round(2.5));
  printf("log=%.4f exp=%.4f\n", log(2.0), exp(1.0));

  /* The other headers that were failing, which need the target macros and the
   * after-declarator attributes and the GNU inline spellings. */
  printf("strlen=%d\n", (int)strlen("abcdefg"));
  printf("memcmp=%d\n", memcmp("abc", "abd", 3));
  printf("abs=%d labs=%ld\n", abs(-5), labs(-5L));
  printf("time=%lld\n", (long long)sizeof(time_t));
  printf("char signed=%d\n", (int)(char)-1);
  printf("size=%d ptrdiff=%d\n", (int)sizeof(size_t), (int)sizeof(ptrdiff_t));
  return 0;
}
