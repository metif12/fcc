/* Six integers, three of which arrive in the caller's stack area.
 *
 * The integer walk is the simplest case, and the simplest case is where a one-slot-low
 * `va_start` shows: the first read has to be the argument the caller put in %rdx, and
 * the fourth has to be the first one on the stack. */
int sum6(int n, ...) {
  __builtin_va_list ap;
  int s = 0;
  __builtin_va_start(ap, n);
  for (int i = 0; i < n; i++)
    s += __builtin_va_arg(ap, int);
  __builtin_va_end(ap);
  return s;
}

int main(void) {
  int a = sum6(6, 1, 2, 3, 4, 5, 6);
  int b = sum6(3, 10, 20, 30);
  return a == 21 && b == 60 ? 0 : 1;
}