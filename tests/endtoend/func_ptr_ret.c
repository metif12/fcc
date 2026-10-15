/* Calling through a function pointer that returns a pointer, including one that
 * returns another function pointer.
 *
 * The declarator `int *(*p)(int)` puts the outer `*` on the return type, not on
 * another level of pointer — `p` is a pointer to a function returning a pointer
 * to int. Reading it the other way gives pointer-to-pointer-to-function, and a
 * call through it then dereferences the callee's own code bytes instead of
 * calling it, which is an access violation rather than a wrong answer.
 *
 * The split form and the nested form exercise the same path once and twice: the
 * nested call is c-testsuite 00124, which is what found it.
 */

#include <stdio.h>

static int global = 42;

static int *getp(int a, int b) {
  (void)a;
  (void)b;
  return &global;
}

static int sub(int c, int b) { return c - b; }

static int (*sel(int a, int b))(int c, int b) {
  if (a != b) return sub;
  return 0;
}

int main(void) {
  /* Through a pointer to a function returning a pointer. */
  int *(*p)(int a, int b) = getp;
  int *q = (*p)(0, 2);
  printf("ptr-ret=%d\n", *q);

  /* Split and nested through a pointer to a function returning a pointer to
   * a function. */
  int (*(*s)(int a, int b))(int c, int d) = sel;
  int (*t)(int c, int b) = (*s)(0, 2);
  printf("split=%d\n", t(2, 2));
  printf("nested=%d\n", (*(*s)(0, 2))(2, 2));
  return 0;
}
