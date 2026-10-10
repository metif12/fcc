/* A label used as a value, in a static local's initializer.
 *
 * `static void *t[] = {&&a, &&b, &&c}` is a GNU extension and a legal constant
 * expression: a label's address is fixed before the program starts, exactly as `&g` is.
 * It failed with `initializer element is not constant`, because the byte image was
 * written while the initializer was still being parsed and `&&a` carries no label until
 * `resolve_goto_labels` has matched it -- which runs after the whole body is read.
 *
 * The three shapes below are the three things a relocation can get wrong, and the first
 * two are the ones a self-consistent build cannot see:
 *
 *   - three *different* entries, each indexed and jumped through
 *   - the *same* label twice, which only survives if the duplication is not collapsed
 *   - the jump is indirect, so the entry has to be an address rather than a number
 *
 * A label does not stop the flow, so landing on `a` runs a's increment and then falls
 * into b's. That is what makes the index discriminate: 3, 2 and 1 for t[0], t[1] and
 * t[2], in an order a transposed jump table would swap.
 */

int printf(const char *fmt, ...);

/* Each index of a three-entry table, and the value it has to produce.
 * A label does not block the flow, so landing on a runs a, b and c; on b runs b and c;
 * on c runs only c. So the three answers are 3, 2 and 1. */
int via_table(int k) {
  static void *t[] = {&&a, &&b, &&c};
  int i = 0;
  goto *t[k];
a:
  i++;
b:
  i++;
c:
  i++;
  return i;
}

/* The same label entered twice. A jump table that collapsed the duplicate would land
 * nowhere, and one that invented a third entry would land somewhere else. */
int via_duplicate(int k) {
  static void *u[] = {&&d, &&d, &&e};
  int j = 0;
  goto *u[k];
d:
  j += 10;
e:
  j += 100;
  return j;
}

int main(void) {
  printf("table=%d %d %d\n", via_table(0), via_table(1), via_table(2));
  printf("duplicate=%d %d %d\n", via_duplicate(0), via_duplicate(1), via_duplicate(2));

  /* Read back as data, which is what proves the entry is an address: two slots holding
   * the same label compare equal, and the table is three pointers wide. */
  static void *v[] = {&&f, &&g, &&f};
  void *p = v[0];
  printf("identical=%d stride=%d\n", p == v[2], (int)(sizeof(v) / sizeof(v[0])));
  goto *p;
f:
  printf("target=f\n");
  return 0;
g:
  printf("target=g\n");
  return 1;
}