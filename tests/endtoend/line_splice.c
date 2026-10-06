/* Where a line splice may land, and what it must join.
 *
 * [C11 5.1.1.2p1.2] deletes every backslash-newline pair in translation phase two, which
 * is *before* tokenization. So the splice does not just join two lines: it joins two
 * halves of a token, and a compiler that only handles the splice between tokens will
 * split `sizeof` into `size` and `of`.
 *
 * chibicc's `literal.c` line 94 is exactly that spelling, and vcc reported
 * `undefined variable "size"` — naming the half it could see rather than the splice it
 * could not.
 *
 * The four positions here are the four the rule reaches. A fifth — between two tokens —
 * already worked and is included so the set is complete rather than only the new cases.
 *
 * The numeric ones are the reason this is not only an identifier rule: `1\` + `23` is one
 * constant 123 and `0x1\` + `F` is one constant 0x1F, so a literal split in two would
 * silently change a program's arithmetic instead of naming anything.
 */

int printf(const char *fmt, ...);

int main(void) {
  /* A splice inside an identifier, joining a keyword. */
  printf("sizeof=%d\n", size\
of(char));
  /* A splice inside a numeric constant: one token, not two. */
  printf("numbers=%d %d\n", 1\
23, 0x1\
F + 1);
  /* A splice inside a quoted literal, which must not end it. */
  printf("string=%s\n", "spli\
ced");
  /* Between two tokens, which is the case that already worked. */
  printf("sum=%d\n", 1 + \
1);
  /* And one that is not in a token at all, where it is simply gone. */
  printf("plain=%d\n", 40 + \
2);
  return 0;
}