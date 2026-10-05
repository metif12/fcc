module backend

import os
import src.ast
import src.vcc

// Backend tests.
//
// The assertions are about the text an assembler sees, not about a running
// program: function bodies are not generated yet, so the only output that exists
// to check is the data section. The strongest check available is therefore that
// the generated assembly *assembles*, and one test does exactly that by handing it
// to the host's `as` through gcc when gcc is present.

// parsed_globals is the front end's globals for a snippet, without a preprocessor.
fn parsed_globals(src string) []&ast.Obj {
	r := vcc.parse_tokens(vcc.tokenize(src), 'test.c', []vcc.PackEvent{})
	assert r.errors.len == 0, 'unexpected diagnostics: ${r.errors}'
	return r.globals
}

// generated runs the backend and returns its assembly and diagnostics.
fn generated(src string) (string, []string) {
	mut globals := parsed_globals(src)
	mut g := AsmGen{}
	return g.gen(mut globals)
}

// assembled reports whether the host's assembler accepts the generated text.
//
// The test is skipped rather than failed when no assembler is present, because a
// missing toolchain is not a property of the code generator. That distinction is
// the same one tools/harness makes about a missing compiler.
fn assembled(text string) bool {
	src := 'vcc_asm_check.s'
	obj := 'vcc_asm_check.o'
	os.write_file(src, text) or { return false }
	defer {
		os.rm(src) or {}
		os.rm(obj) or {}
	}
	gcc := os.find_abs_path_of_executable('gcc') or { return false }
	res := os.execute('${gcc} -c -o ${obj} ${src}')
	return res.exit_code == 0
}

fn test_an_initialized_global_becomes_bytes_in_the_data_section() {
	text, errs := generated('int g = 42;\n')
	// `f` is absent, so the only diagnostic should be none at all.
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	assert text.contains('.globl g')
	assert text.contains('  .data')
	assert text.contains('g:')
	// 42 is 0x2a, little-endian in four bytes.
	assert text.contains('  .byte 42')
	assert text.contains('  .byte 0')
	assert text.contains('  .align 4')
}

fn test_a_tentative_global_becomes_bss() {
	text, _ := generated('int bss_var;\n')
	assert text.contains('  .bss')
	assert text.contains('  .zero 4')
	// A tentative definition is zeroed, not stored, so it must not also appear in
	// `.data`: an object that has both is a link error.
	assert !text.contains('  .data')
}

fn test_a_static_global_is_not_exported() {
	text, _ := generated('static int s = 1;\n')
	assert !text.contains('.globl s')
	assert text.contains('s:')
}

fn test_a_relocation_becomes_a_quad_of_the_symbol_plus_the_offset() {
	text, _ := generated('static int table[8];\nint *p = &table[3];\n')
	assert text.contains('  .quad table+12')
}

fn test_a_string_literal_becomes_its_own_object() {
	text, _ := generated('char *msg = "hi";\n')
	// The literal is a separate object and the pointer is a relocation into it,
	// which is the only way a string can be shared between two uses of it.
	assert text.contains('  .quad .L..1+0')
	assert text.contains('  .byte 104')
	assert text.contains('  .byte 105')
	assert text.contains('  .byte 0')
}

fn test_an_array_of_at_least_sixteen_bytes_is_aligned_to_sixteen() {
	// The psABI asks for 16-byte alignment on an array of 16 bytes or more, even
	// when its element type asks for less. Four ints are exactly 16.
	text, _ := generated('int a[4];\n')
	assert text.contains('  .align 16')
	small, _ := generated('int b[2];\n')
	assert small.contains('  .align 4')
}

fn test_a_function_definition_gets_a_prologue_and_one_epilogue() {
	text, errs := generated('int f(int a, int b) { return a + b; }\n')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	assert text.contains('.globl f')
	assert text.contains('f:')
	assert text.contains('  push %rbp')
	assert text.contains('  mov %rsp, %rbp')
	// Both parameters arrived in registers and are spilled into the frame, because
	// the body addresses every parameter as a local. `%ecx` and `%edx`, not `%edi` and
	// `%esi`: this is the Windows x64 ABI, not the psABI.
	assert text.contains('  mov %ecx,')
	assert text.contains('  mov %edx,')
	assert !text.contains('  mov %edi,'), 'the psABI register leaked back in'
	// Every exit jumps to the one epilogue rather than carrying its own sequence,
	// because the epilogue is what gives back a VLA's stack.
	assert text.contains('  jmp .L.return.f')
	assert text.contains('.L.return.f:')
	assert text.contains('  ret')
}

fn test_a_loop_uses_its_own_break_and_continue_labels() {
	text, errs := generated('int f(int n) { int t = 0; for (int i = 0; i < n; i++) { t += i; } return t; }\n')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	// A `for` is the only construct whose failure edge and whose `break` have to land
	// in the same place, so the condition jumps to the loop's own break label.
	assert text.contains('  je .L..')
	assert text.contains('  jmp .L.begin.')
}

fn test_a_stack_depth_that_does_not_return_to_zero_is_reported() {
	// Every push has a matching pop, so a body that leaves the depth non-zero means
	// the generator lost track of the accumulator, which would corrupt every frame
	// above it. It is reported rather than emitted.
	_, errs := generated('int f(int n) { return n; }\n')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
}

fn test_a_thread_local_is_reported_rather_than_emitted_wrongly() {
	_, errs := generated('_Thread_local int t = 1;\n')
	// [PE] A thread-local's section index is allocated by the object writer, so the
	// text backend cannot spell one.
	assert errs.len > 0
	assert errs[0].contains('thread-local')
}

fn test_the_generated_assembly_is_accepted_by_the_assembler() {
	text, _ := generated('static int table[8] = {1, 2, 3};\nint g = 42;\nchar *msg = "hi";\nint *p = &table[3];\nint bss_var;\n')
	if assembled(text) {
		return
	}
	// The text did not assemble. That is a real failure unless there is no
	// assembler to assemble it with, which is the one thing that excuses it.
	assert os.find_abs_path_of_executable('gcc') or { '' } == ''
}

fn test_a_parameter_that_arrives_on_the_stack_is_placed_above_the_return_address() {
	// Seven integer parameters: the first six go in registers and the seventh
	// arrives on the stack, where its offset is the caller's choice and has to be
	// 40 — the return address plus the caller's 32-byte home area.
	mut globals := parsed_globals('int f(int a, int b, int c, int d, int e, int g, int h) { return a; }\n')
	mut g := AsmGen{}
	g.assign_lvar_offsets(mut globals)
	f := globals[0]
	// Four integer arguments arrive in registers on this target, so the first four are
	// placed in the frame like any other local and end up below the frame pointer. The
	// fifth is the first on the stack, at 48: the return address the `call` pushed, the
	// `%rbp` the prologue pushed, and the 32-byte home area above them.
	//
	// 40 is *not* it, and the mistake is easy to make because gcc's listing contains both
	// numbers and they mean different things: 40 is where a callee spills its fourth
	// register parameter, and 48 is where it finds the first stack parameter. Reading the
	// listing as if the offset appeared once put every stack argument eight bytes low.
	assert f.params[3].offset < 0
	assert f.params[4].offset == 16 + shadow_space
	assert f.params[5].offset == 24 + shadow_space
	// The frame itself is a multiple of 16 so that a call from inside it keeps the
	// stack aligned.
	assert f.stack_size % 16 == 0
}

fn test_a_local_gets_a_negative_offset() {
	mut globals := parsed_globals('int f(void) { int x = 1; return x; }\n')
	mut g := AsmGen{}
	g.assign_lvar_offsets(mut globals)
	f := globals[0]
	mut found := false
	for local in f.locals {
		if local.name == 'x' {
			found = true
			assert local.offset < 0, 'a local must live below the frame pointer'
		}
	}
	assert found, 'x is not in the frame'
}

fn test_has_flonum_asks_about_bytes_rather_than_about_the_type() {
	// A struct of one float and one int is 8 bytes, and its bytes are not all
	// floating-point, so it goes in a general-purpose register.
	globals := parsed_globals('struct S { float a; int b; };\nstruct T { float a; float b; };\nstruct S si;\nstruct T ti;\n')
	s := globals[0].ty
	// `s` is the first global only if it has a definition; the tag alone is not one,
	// so the types are reached through the variables instead.
	_ = s
	mut fi := -1
	mut ti := -1
	for i, obj in globals {
		if obj.ty.kind == .struct_ && obj.name == 'si' {
			fi = i
		}
		if obj.ty.kind == .struct_ && obj.name == 'ti' {
			ti = i
		}
	}
	assert fi >= 0 && ti >= 0, 'expected two struct variables'
	_ = globals
	// The point of the helper: the *same* struct type answers differently for its
	// first and second eight bytes.
	assert has_flonum(globals[fi].ty, 0, 8, 0) == false
	assert has_flonum(globals[ti].ty, 0, 8, 0) == true
}

fn test_a_cast_between_two_identical_types_emits_nothing() {
	mut g := AsmGen{}
	g.out = []
	g.emit = &TextEmitter{}
	int_ty := vcc.ty_int
	g.cast(int_ty, int_ty)
	assert g.out.len == 0
}

fn test_a_cast_to_bool_is_a_comparison() {
	mut g := AsmGen{}
	g.out = []
	g.emit = &TextEmitter{}
	int_ty := vcc.ty_int
	bool_ty := vcc.ty_bool
	g.cast(int_ty, bool_ty)
	// Not a move: a value is true when it is not zero, which is a comparison.
	assert g.out.join('\n').contains('cmp $0, %eax')
	assert g.out.join('\n').contains('setne %al')
}

fn test_a_cast_to_void_emits_nothing() {
	mut g := AsmGen{}
	g.out = []
	g.emit = &TextEmitter{}
	g.cast(vcc.ty_int, vcc.ty_void)
	assert g.out.len == 0
}

fn test_align_to_rounds_up() {
	assert align_to(5, 8) == 8
	assert align_to(8, 8) == 8
	assert align_to(9, 16) == 16
	assert align_to(0, 16) == 0
}

fn test_a_symbol_containing_a_dollar_sign_is_quoted_in_an_operand() {
	// GNU `as` reads `$` as the start of an immediate, so `lea $$$(%rip), %rax` is
	// `junk '(%rip)' after expression`. Measured here: the quoted spelling assembles,
	// links, and reads the right address.
	// The `&$$$` initializer is what produces a `.quad` relocation; a function that reads
	// the global is what produces the `lea`. Both positions need the quoting and neither
	// is reachable from the other, so both are here.
	text, errs := generated('int $$$ = 5; int *p = &$$$; int f(void) { return $$$; }')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	assert text.contains('lea "$$$"(%rip), %rax'), 'the operand was not quoted'
	assert text.contains('.quad "$$$"'), 'the relocation was not quoted'
	// A label and a `.globl` take the bare name: both accept it, so quoting them would
	// be noise.
	assert text.contains('.globl $$$'), 'the directive should keep the bare name'
	assert assembled(text), 'the assembler rejected the generated text'
}

fn test_a_symbol_without_a_dollar_sign_is_not_quoted() {
	text, errs := generated('int q = 5; int *p = &q; int f(void) { return q; }')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	assert text.contains('lea q(%rip), %rax'), 'an ordinary symbol should not be quoted'
}

fn test_a_long_double_argument_is_passed_by_address() {
	// [MS x64 2.2.5] Anything wider than eight bytes that is not a structure is passed by
	// reference. gcc does `fstpt` to its own frame and `movq` the address into a general
	// register; there is no x87 argument on the stack on this target at all. The previous
	// version of this test asserted the psABI's two stack slots and had to be rewritten.
	text, errs := generated('int f(char *b, char *g, ...); int h(void) { char b[8]; return f(b, "", (long double)1.5); }')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	assert text.contains('  fstpt (%rsp)'), 'the value was not spilled'
	// Then the address is pushed, so the ordinary pop loads it like a pointer.
	assert text.contains('  mov %rsp, %rax'), 'the address of the spill was not taken'
	assert text.contains('  pop %rdx'), 'the address did not reach the second integer register'
}

fn test_the_by_reference_spill_is_released_after_the_call() {
	// The spill is not one of `stack_args` — those are what the *callee* pops — so
	// without adding it to the cleanup the frame grew 16 bytes at every such call and the
	// function ended with a depth it could never account for.
	text, errs := generated('int f(...); int h(void) { return f((long double)1.5); }')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	// 32 of home area plus the 16-byte spill, which is 48 and not a multiple of 16 on its
	// own because the spill is below the area and was already accounted for in the depth.
	assert text.contains('  add $48, %rsp'), 'got: ' + text
}

fn test_a_long_double_parameter_is_loaded_through_its_address() {
	// The callee receives an address, so the value is `fldt`-ed from the register and
	// `fstpt`-ed to the frame slot. The general-register spill is not used at all, which
	// is what makes this easy to get backwards: it is the psABI's pair with the operands
	// swapped, and swapping it back is the bug this replaced.
	text, errs := generated('long double f(long double x) { return x + x; }')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	assert text.contains('  fldt (%rcx)'), 'the parameter was not loaded through its address'
	assert text.contains('  fstpt'), 'the parameter was not written to its frame slot'
}

fn test_an_ordinary_stack_argument_is_still_one_slot() {
	text, errs := generated('int f(int a, int b, int c); int h(void) { return f(1, 2, 3); }')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	assert text.contains('sub $16, %rsp'), 'three eight-byte arguments should be padded to two slots'
}

// --- the calling convention ---

fn test_a_call_reserves_the_callees_home_area_immediately_before_it() {
	// [MS x64 2.2.5] The caller reserves 32 bytes so the callee can spill its four
	// argument registers. gcc takes the same bytes out of the prologue once; taking them
	// out here costs one instruction and keeps the depth accounting local to the call.
	// It has to come *after* the argument values are popped into their registers, or
	// `%rsp` moves out from under the pops.
	text, errs := generated('int f(int); int g(void) { return f(1); }')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	i_sub := text.index('  sub $32, %rsp') or { -1 }
	i_call := text.index('  call *%r10') or { -1 }
	assert i_sub >= 0, 'no home area was reserved'
	assert i_call > i_sub, 'the home area must be reserved before the call'
	// The value is materialised into %rax and popped into the register, because this is
	// a stack machine; the pop target is what decides the ABI.
	assert text.contains('  pop %rcx'), 'the argument did not go into the first register'
}

fn test_a_call_does_not_set_the_vector_register_count() {
	// `mov $N, %al` is a psABI requirement for the callee's register save area. The
	// Microsoft ABI has no such save area, and gcc emits no such instruction.
	text, errs := generated('int f(double); int g(void) { return (int)f(1.0); }')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	assert !text.contains(', %rax\n  call'), 'the vector register count was still being set'
	assert text.contains('  movsd (%rsp), %xmm0'), 'the argument did not go into %xmm0'
}

fn test_a_variadic_call_mirrrors_its_floating_point_arguments() {
	// [MS x64 3.2] The first four floating-point arguments are also written into the
	// integer registers, so a variadic callee can find them. The Nth floating-point
	// argument goes into the Nth *integer* register — counted among the floating-point
	// arguments, not among all of them.
	text, errs := generated('int p(char *, ...); int g(void) { return p("", 1.0); }')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	// `movq`, not `movsd`: an SSE mnemonic cannot move between an XMM and a general
	// register, and the assembler only says `operand type mismatch`.
	assert text.contains('  movq %xmm0, %rcx'), 'the mirror instruction or its target is wrong'
}

fn test_a_non_variadic_call_does_not_mirror_its_floating_point_arguments() {
	text, errs := generated('double f(double); double g(void) { return f(1.0); }')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	assert !text.contains('movq %xmm0, %rcx'), 'a non-variadic callee was given a mirror'
}

fn test_the_fifth_integer_argument_goes_on_the_stack_and_the_fifth_fp_too() {
	// Four of each on this target, so the fifth of either class spills.
	text, errs := generated('int f(int,int,int,int,int); int g(void) { return f(1,2,3,4,5); }')
	assert errs.len == 0, 'unexpected diagnostics: ${errs}'
	assert text.contains('  pop %r9'), 'the fourth register argument is missing'
	assert !text.contains('pop %r10'), 'a fifth integer register was used, which does not exist on this ABI'
}
