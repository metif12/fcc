module ast

// The target ABI, in one place.
//
// It belongs here rather than in the backend because **both** sides need it and the front
// end cannot import the backend without a cycle. The cost of getting it wrong is not
// hypothetical: `va_area_size` is the size of a variadic function's `va_list` local, and if
// it drifts from `gp_max` and `fp_max` then the register save area is written past the end
// of its own frame slot — silently, because the write is a `movq` into a local.
//
// Every number here is measured on the target, not recalled. The measured ones are:
// `long` 4, `long long` 8, pointers 8, `sizeof(void)` 1, `wchar_t` 2, `sizeof(va_list)` 8.
// The ones this file's comments call out as differing from the psABI are called out there.

// gp_max and fp_max are the argument register counts of the *Windows* x64 ABI: four
// integer registers and four SSE registers.
//
// These are not the psABI's six and eight. The psABI is the System V convention, and it is
// what a Linux target would use; on this target mingw's C library follows the Microsoft
// ABI, so a call emitted for the psABI puts every argument in a register the callee does not
// read. That is invisible from inside the compiler, because two vcc-compiled functions
// agree with each other, and it kills the first program that calls the C library.
//
// Measured from `gcc -S -O0` on this host; see docs/PLAN.md.
pub const gp_max = 4
pub const fp_max = 4

// shadow_space is the 32 bytes the caller must reserve before a `call` so the callee has
// somewhere to spill its four argument registers.
//
// [MS x64 2.2.5] "space is reserved on the stack for arguments passed in registers"; the
// first four eight-byte slots at the top of the callee's frame are the home area. gcc
// takes it out of the prologue once rather than at each call site, which is why its `main`
// has one `subq $56, %rsp` and no `sub` before any `call`.
pub const shadow_space = 32

// incoming_base is the offset of the first incoming *stack* parameter from `%rbp` in a
// callee: the return address the `call` pushed, the `%rbp` the prologue pushed, and the
// caller's home area above them.
//
// This was 40 for the whole of phase 2, read off gcc's own output by mistaking a *spilled
// register parameter* at `40(%rbp)` for the first stack parameter. The listing contains both
// numbers and they mean different things in the same six lines.
pub const incoming_base = 16 + shadow_space

// va_list is `char *`, eight bytes: a pointer, not the psABI's 24-byte
// `gp_offset`/`fp_offset`/`overflow_arg_area`/`reg_save_area` struct.
//
// **The 24-byte struct is wrong for this target, and this file asserted it for
// the whole of phase 2.** The size was measured and is right; the *shape* was
// assumed from the psABI. Measured, by reading the `va_list` a callee built and
// walking it slot by slot:
//
//	$ tcc -o t.exe walk.c && ./t.exe
//	before va_list bytes: 01 00 00 00 00 00 00 00 02 ... 03 ... 04 ...
//	                        ^ the argument values themselves
//
// Those are the values of the variadic arguments, not four header words. mingw
// gcc 15.2 produces the same bytes, and both compilers read the same arguments
// out of them.
//
// The mechanism is the Microsoft one, and it is three instructions rather than a
// structure:
//
//	- the callee spills `%rcx`, `%rdx`, `%r8`, `%r9` to the home slots at
//	  16/24/32/40(`%rbp`) — which is where `incoming_base - 32` already is, so
//	  the register area and the caller's stack area are **contiguous**;
//	- `va_start(ap, last)` sets `ap` to the first slot past the named parameters;
//	- `va_arg(ap, T)` reads `T` at `*ap` and adds 8 to `ap`.
//
// There is no tag, no `gp_offset`, and no separate register save area. A variadic
// callee never reads `%xmm` through `va_list` at all, because the caller mirrors
// every floating-point argument into a general register — see `gen_funcall`.
pub const va_slot = 8

// va_start_offset is where a variadic function's arguments begin, and it is the
// first thing `va_start` puts in the `va_list`.
//
// It is `incoming_base - shadow_space`, which is 16: the return address and the
// saved `%rbp` are above it, and the four home slots are below it. Measured from
// gcc for `int vsum(int n, ...)`, whose one named parameter is in `%ecx`:
//
//	leaq	24(%rbp), %rax    # ap = &home[1]
//
// and the home slots themselves are written by the same four stores a normal
// parameter spill needs, because a variadic function spills all four argument
// registers whether it has that many named parameters or not.
pub const va_start_offset = incoming_base - shadow_space
