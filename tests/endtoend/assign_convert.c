/* An assignment converts its right-hand side to the left-hand side's type.
 *
 * [C11 6.5.16.1]: the value stored is the right operand "converted to the type of the
 * assignment expression". The conversion is not optional — it is the difference between
 * storing a number and storing the representation the left type calls for.
 *
 * This program has no variadic argument in it. It is here because `double s = 0;` broke
 * the variadic work in a way that looked like a `va_arg` bug: `gen_num` left an integer
 * literal in `%rax` and `store` wrote `%xmm0`, which nothing had loaded, so the frame slot
 * kept whatever was in it. Every value here is wrong without the conversion, and the
 * symptoms are uninitialised-looking numbers rather than zeros. */

int printf(const char *fmt, ...);

/* The declaration form: the integer 0 stored through a double slot. */
double declared(void) {
  double s = 0;
  return s;
}

/* The accumulating form, which is how it was found: `dsum` printed 8.5 instead of 7 and
 * the control with no `va_arg` in it printed 3.7756e+150. */
double accumulated(void) {
  double s = 0;
  s += 1.5;
  s += 2.5;
  s += 3.0;
  return s;
}

/* The narrowing direction as well: a double stored into an int. */
int narrowed(void) {
  int i = 3;
  i = 3.9;
  return i;
}

float declared_float(void) {
  float f = 0;
  return f;
}

/* An int through a double slot, then read back as a double — the two must agree, and
 * without the conversion the second read is whatever the frame held. */
double round_trip(void) {
  double d = 42;
  return d;
}

int main(void) {
  printf("declared=%g accumulated=%g narrowed=%d declared_float=%g round_trip=%g\n",
         declared(), accumulated(), narrowed(), declared_float(), round_trip());
  return 0;
}