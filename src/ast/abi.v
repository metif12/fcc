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

// va_area_size is the size of the frame slot a variadic function builds its `va_list` in.
//
//	 0..8    the `va_list`: the address of the tag
//	 8..32   the tag: gp_offset, fp_offset, overflow_arg_area, reg_save_area
//	32..    the register save area: gp_max integer slots, then fp_max SSE slots of 16
//
// `va_list` is eight bytes on this target, measured: mingw gcc and tcc both report
// `sizeof(va_list) == 8`, and it is a *pointer* rather than the psABI's 24-byte
// `gp_offset`/`fp_offset`/`overflow`/`reg_save` struct. That is what makes a callee's
// `va_list` passable to the C library's `vprintf`; with the struct there, a library that
// reads eight bytes reads `gp_offset` and `fp_offset` as a pointer instead.
//
// Derived from the constants above rather than written down, so it cannot drift from them.
pub const va_area_size = 8 + 24 + gp_max * 8 + fp_max * 16

// xmm_slot is the width an SSE register is saved and restored at in the register save area,
// and therefore the step `fp_offset` takes per consumed floating-point argument.
pub const xmm_slot = 16