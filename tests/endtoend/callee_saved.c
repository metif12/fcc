/* Which registers a compiled function has to keep across a call, measured from
 * outside rather than assumed.
 *
 * Windows x64 and Linux SysV disagree about which registers are non-volatile, and
 * they disagree about exactly the ones that are easy to get wrong by habit: Linux
 * keeps RBX, RBP and R12-R15; Windows also keeps RDI and RSI. A generator written
 * against the Linux set will pop its argument operand into `%rdi`, and nothing it
 * emits will look wrong — the arithmetic is right, the frame is right, the
 * push/pop pairs balance.
 *
 * The damage is only visible in the *caller*. libc's `qsort` holds a live value in
 * `%rdi` across every call it makes to the comparator, so a comparator built this
 * way returns a correct comparison and takes the sort down with it. `mine` below
 * is the control that makes the point: the same comparator, called from a function
 * we compiled ourselves, sorts correctly, because our own caller happens not to
 * depend on the register. The fault was never in the comparator.
 *
 * Every value is compared against what gcc computes for the same program.
 */

#include <stdio.h>
#include <stdlib.h>

static int cmp_int(const void *a, const void *b) {
  return *(const int *)a - *(const int *)b;
}

/* The control: a comparator called from our own code. It sorts fine either way,
 * which is why this defect survived every unit test. */
static int mine_sort(int *a, int n, int (*cmp)(const void *, const void *)) {
  for (int i = 1; i < n; i++) {
    for (int j = i; j > 0; j--) {
      if (cmp(&a[j - 1], &a[j]) > 0) {
        int t = a[j - 1];
        a[j - 1] = a[j];
        a[j] = t;
      }
    }
  }
  return 0;
}

/* A comparator that does arithmetic in every width class, so the scratch register
 * is used whichever width the subtraction picked. */
static int cmp_all(const void *a, const void *b) {
  int x = *(const int *)a;
  int y = *(const int *)b;
  if (x < y) return -1;
  if (x > y) return 1;
  return 0;
}

int main(void) {
  /* The reported shape: libc's qsort calling a comparator we compiled. */
  int theirs[5] = {5, 3, 1, 4, 2};
  qsort(theirs, 5, 4, cmp_int);
  printf("theirs=%d %d %d %d %d\n", theirs[0], theirs[1], theirs[2], theirs[3], theirs[4]);

  /* The control, with the same comparator. */
  int mine[5] = {5, 3, 1, 4, 2};
  mine_sort(mine, 5, cmp_int);
  printf("mine=%d %d %d %d %d\n", mine[0], mine[1], mine[2], mine[3], mine[4]);

  /* A comparator built from comparisons and branches, so the arithmetic is not a
   * single instruction either. */
  int third[7] = {9, 1, 8, 2, 7, 3, 6};
  qsort(third, 7, 4, cmp_all);
  printf("third=%d %d %d %d %d %d %d\n", third[0], third[1], third[2], third[3], third[4], third[5], third[6]);

  /* An indirect call of our own, which was never affected. */
  int (*fp)(const void *, const void *) = cmp_int;
  int p = 1, q = 2;
  printf("indirect=%d\n", fp(&p, &q));

  /* And a `switch` with a range, which used the same scratch register. */
  for (int i = 0; i < 8; i++) {
    switch (i) {
    case 0 ... 2: printf("low%d\n", i); break;
    case 3 ... 5: printf("mid%d\n", i); break;
    default: printf("high%d\n", i);
    }
  }
  return 0;
}
