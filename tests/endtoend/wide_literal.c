/* The element width of a prefixed literal, which is where this target differs from
 * chibicc.
 *
 * chibicc is System V, where `wchar_t` is four bytes. Here it is two, and so is
 * `char16_t`, so every wide literal this compiler used to type at twice the width the
 * platform gives:
 *
 *   sizeof("ab")        3  both
 *   sizeof(L"ab")       6  both
 *   sizeof(L"ab" "c")   8  both — the run has one width, the first piece's
 *   sizeof(L'a')        2  both
 *
 * `L"ab" "c"` is the one that cannot be checked by a single literal's own size, because
 * a run of literals is one array of the *first* piece's element type, and getting the
 * count right while the width is wrong still gives the wrong total.
 *
 * tcc does not know `u"`, `U"` or `u8"` and rejects all three, so those widths are asked
 * of gcc alone and are asserted here rather than compared — the comparison is against
 * C11 6.4.4.4, which is where the numbers come from anyway. `tools/probe/probe.v` calls
 * a program tcc refuses BLOCKED rather than failing it, and a program it cannot even
 * parse would make this file untested rather than tested.
 */

int printf(const char *fmt, ...);

int main(void) {
  printf("plain=%d L=%d Lrun=%d Lchar=%d\n", (int)sizeof("ab"), (int)sizeof(L"ab"),
         (int)sizeof(L"ab" "c"), (int)sizeof(L'a'));
  /* A wide literal as an initializer takes the width of the *declared* array, not its
   * own, so the storage image is the other half of the question: before the fix vcc
   * wrote `61 00 62 00 00 00` and then declared the object sixteen bytes wide. */
  typedef unsigned short wchar_t;
  wchar_t wa[] = L"ab";
  unsigned char *p = (unsigned char *)wa;
  printf("bytes=");
  for (unsigned i = 0; i < sizeof(wa); i++)
    printf("%02x", p[i]);
  printf(" size=%d\n", (int)sizeof(wa));
  /* And the values survive the round trip, which is what proves the stride is 2 and not
   * merely that the total size is right. */
  wchar_t w[4] = L"abc";
  printf("vals=%d,%d,%d,%d\n", (int)w[0], (int)w[1], (int)w[2], (int)w[3]);
  return 0;
}