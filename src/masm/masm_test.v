module masm

// Hermetic unit tests: every expected byte string below was read off
// `objdump -d` of the same line assembled by GNU as on this host, so the
// oracle is the assembler fcc replaces, not this encoder.

fn enc1(line string) ![]u8 {
	mut mn := line
	mut rest := ''
	if idx := line.index(' ') {
		mn = line[..idx]
		rest = line[idx + 1..]
	}
	mut ops := []Operand{}
	if rest != '' {
		for part in rest.split(',') {
			ops << parse_operand(part.trim_space())!
		}
	}
	bytes, _ := encode(mn.to_lower(), ops, line, false)!
	return bytes
}

fn check_bytes(line string, want []u8) {
	got := enc1(line) or { panic('encode failed for "${line}": ${err.msg()}') }
	assert got == want, 'wrong bytes for "${line}": got ${got} want ${want}'
}

fn test_prologue_shape() {
	// From the s1 probe object (objdump): push %rbp; mov %rsp,%rbp; sub $32,%rsp.
	check_bytes('push %rbp', [u8(0x55)])
	check_bytes('mov %rsp, %rbp', [u8(0x48), 0x89, 0xe5])
	check_bytes('sub \$32, %rsp', [u8(0x48), 0x83, 0xec, 0x20])
}

fn test_mov_forms() {
	// mov $2,%rax is C7, not B8: the imm32 form, as GAS emits it.
	check_bytes('mov \$2, %rax', [u8(0x48), 0xc7, 0xc0, 0x02, 0x00, 0x00, 0x00])
	check_bytes('mov %rsp, %rbp', [u8(0x48), 0x89, 0xe5])
	check_bytes('mov %ecx, -8(%rbp)', [u8(0x89), 0x4d, 0xf8])
	check_bytes('mov %al, (%rcx)', [u8(0x88), 0x01])
	check_bytes('mov (%rax), %rax', [u8(0x48), 0x8b, 0x00])
	check_bytes('mov -24(%rbp), %rax', [u8(0x48), 0x8b, 0x45, 0xe8])
	// -1 fits in a signed 32 bits, so GAS takes the C7 form (orc3 oracle).
	check_bytes('mov \$-1, %rax', [u8(0x48), 0xc7, 0xc0, 0xff, 0xff, 0xff, 0xff])
	check_bytes('mov \$-9223372036854775807, %rax', [u8(0x48), 0xb8, 0x01, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x80])
	check_bytes('mov \$0, %al', [u8(0xb0), 0x00])
	check_bytes('movq \$0, (%rsp)', [u8(0x48), 0xc7, 0x04, 0x24, 0x00, 0x00, 0x00, 0x00])
}

fn test_alu_forms() {
	check_bytes('add %ecx, %eax', [u8(0x01), 0xc8])
	check_bytes('add %rcx, %rax', [u8(0x48), 0x01, 0xc8])
	check_bytes('add \$8, %rsp', [u8(0x48), 0x83, 0xc4, 0x08])
	check_bytes('cmp \$0, %eax', [u8(0x83), 0xf8, 0x00])
	// GAS uses the accumulator form for %al (orc5 oracle).
	check_bytes('and \$1, %al', [u8(0x24), 0x01])
	// ...but the 83/05 forms for %eax/%rax (orc4/orc5 oracles).
	// and $0xfffffff0,%r11d is the 81 form with REX.B, from the corpus.
	// GAS wraps a 32-bit mask to signed for the 83/81 choice (orc5 oracle).
	check_bytes('and \$0xfffffff0, %r11d', [u8(0x41), 0x83, 0xe3, 0xf0])
	check_bytes('test %rax, %rax', [u8(0x48), 0x85, 0xc0])
	// test $imm uses the A9 special form, exactly as GAS emits it.
	check_bytes('test \$3, %rax', [u8(0x48), 0xa9, 0x03, 0x00, 0x00, 0x00])
}

fn test_lea_movsx() {
	check_bytes('lea -16(%rbp), %rax', [u8(0x48), 0x8d, 0x45, 0xf0])
	check_bytes('movsxd (%rax), %rax', [u8(0x48), 0x63, 0x00])
	check_bytes('movsxd %eax, %rax', [u8(0x48), 0x63, 0xc0])
	check_bytes('movzb %al, %rax', [u8(0x48), 0x0f, 0xb6, 0xc0])
	check_bytes('movsbl (%rax), %eax', [u8(0x0f), 0xbe, 0x00])
	check_bytes('movzwl %ax, %eax', [u8(0x0f), 0xb7, 0xc0])
}

fn test_shifts() {
	// GAS uses D1 for a count of 1 and C1 otherwise (oracle orc.s).
	check_bytes('shl \$8, %rax', [u8(0x48), 0xc1, 0xe0, 0x08])
	check_bytes('shl \$1, %rcx', [u8(0x48), 0xd1, 0xe1])
	check_bytes('shr %rcx', [u8(0x48), 0xd1, 0xe9])
	check_bytes('shr %cl, %eax', [u8(0xd3), 0xe8])
	check_bytes('sar \$16, %rax', [u8(0x48), 0xc1, 0xf8, 0x10])
}

fn test_mul_div() {
	check_bytes('imul %ecx, %eax', [u8(0x0f), 0xaf, 0xc1])
	check_bytes('imul %rcx, %rax', [u8(0x48), 0x0f, 0xaf, 0xc1])
	check_bytes('div %rcx', [u8(0x48), 0xf7, 0xf1])
	check_bytes('idiv %rcx', [u8(0x48), 0xf7, 0xf9])
	check_bytes('mul %rcx', [u8(0x48), 0xf7, 0xe1])
	check_bytes('cqo', [u8(0x48), 0x99])
	check_bytes('cdq', [u8(0x99)])
	check_bytes('neg %rax', [u8(0x48), 0xf7, 0xd8])
	check_bytes('not %rax', [u8(0x48), 0xf7, 0xd0])
}

fn test_sse() {
	check_bytes('movq %rax, %xmm0', [u8(0x66), 0x48, 0x0f, 0x6e, 0xc0])
	check_bytes('movq %xmm0, %rcx', [u8(0x66), 0x48, 0x0f, 0x7e, 0xc1])
	check_bytes('cvtsi2sdl %eax, %xmm0', [u8(0xf2), 0x0f, 0x2a, 0xc0])
	check_bytes('cvttsd2siq %xmm0, %rax', [u8(0xf2), 0x48, 0x0f, 0x2c, 0xc0])
	// ss-width conversions take F3, including cvttss2si (orc6 oracle).
	check_bytes('cvtss2sd %xmm0, %xmm0', [u8(0xf3), 0x0f, 0x5a, 0xc0])
	check_bytes('cvtsd2ss %xmm0, %xmm0', [u8(0xf2), 0x0f, 0x5a, 0xc0])
	check_bytes('cvtsi2ssl %eax, %xmm0', [u8(0xf3), 0x0f, 0x2a, 0xc0])
	check_bytes('cvtsi2ssq %rax, %xmm0', [u8(0xf3), 0x48, 0x0f, 0x2a, 0xc0])
	check_bytes('cvttsd2sil %xmm0, %eax', [u8(0xf2), 0x0f, 0x2c, 0xc0])
	check_bytes('cvttss2sil %xmm0, %eax', [u8(0xf3), 0x0f, 0x2c, 0xc0])
	check_bytes('cvttss2siq %xmm0, %rax', [u8(0xf3), 0x48, 0x0f, 0x2c, 0xc0])
	check_bytes('ucomisd %xmm1, %xmm0', [u8(0x66), 0x0f, 0x2e, 0xc1])
	check_bytes('pxor %xmm0, %xmm0', [u8(0x66), 0x0f, 0xef, 0xc0])
	check_bytes('addsd %xmm1, %xmm0', [u8(0xf2), 0x0f, 0x58, 0xc1])
}

fn test_x87() {
	// fistpll is DF /7, not /3: the oracle caught the first spelling.
	check_bytes('fldl (%rdx)', [u8(0xdd), 0x02])
	check_bytes('fstpl (%rcx)', [u8(0xdd), 0x19])
	check_bytes('fistpl (%rcx)', [u8(0xdb), 0x19])
	check_bytes('fistpll (%rcx)', [u8(0xdf), 0x39])
	check_bytes('fldcw (%rcx)', [u8(0xd9), 0x29])
	check_bytes('frndint', [u8(0xd9), 0xfc])
}

fn test_setcc_and_misc() {
	check_bytes('sete %al', [u8(0x0f), 0x94, 0xc0])
	check_bytes('setnp %dl', [u8(0x0f), 0x9b, 0xc2])
	check_bytes('push %r10', [u8(0x41), 0x52])
	check_bytes('pop %r10', [u8(0x41), 0x5a])
	check_bytes('push \$300', [u8(0x68), 0x2c, 0x01, 0x00, 0x00])
	check_bytes('push \$5', [u8(0x6a), 0x05])
	check_bytes('leave', [u8(0xc9)])
	check_bytes('rep stosb', [u8(0xf3), 0xaa])
}

fn test_internal_rip_reference() {
	out := assemble('  .text\n  .globl add\nadd:\n  lea add(%rip), %rax\n  ret\n')!
	assert out.text_relocs.len == 0
	// 48 8d 05 <disp32=-7> c3: the disp points back at offset 0 from field end 7.
	// .text is padded to 16 bytes with 0x90, as in GAS objects.
	assert out.text == [u8(0x48), 0x8d, 0x05, 0xf9, 0xff, 0xff, 0xff, 0xc3, 0x90, 0x90, 0x90, 0x90,
		0x90, 0x90, 0x90, 0x90]
}

fn test_external_rip_relocation() {
	out := assemble('  .text\n  .globl main\nmain:\n  lea printf(%rip), %rax\n  ret\n')!
	assert out.text_relocs.len == 1
	assert out.text_relocs[0].symbol == 'printf'
	assert out.text_relocs[0].kind == .rel32
	assert out.text_relocs[0].offset == 3
	assert out.text == [u8(0x48), 0x8d, 0x05, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x90, 0x90, 0x90, 0x90,
		0x90, 0x90, 0x90, 0x90]
}

fn test_quad_section_relocation() {
	out := assemble('  .data\n  .align 1\n.L..1:\n  .byte 65\n  .byte 0\n  .quad .L..1+0\n')!
	assert out.data_relocs.len == 1
	assert out.data_relocs[0].symbol == '.data'
	assert out.data_relocs[0].offset == 2
	// The field carries the label's section offset (0 here).
	assert out.data[2..10] == [u8(0), 0, 0, 0, 0, 0, 0, 0]
}

fn test_short_and_near_jumps() {
	// A jump past 127 bytes of payload stays near; the sizing fixpoint
	// widens exactly the jumps that need it.
	mut body := '  .text\n  je far\n'
	for _ in 0 .. 140 {
		body += '  nop\n'
	}
	body += 'far:\n  ret\n  jmp back\nback:\n  ret\n'
	out := assemble(body)!
	// je far is near (0F 84 + disp32 = 140), jmp back is short (EB ib).
	assert out.text[0] == 0x0f && out.text[1] == 0x84
	assert out.text[147] == 0xeb
	assert out.text_relocs.len == 0
}

fn test_numeric_labels() {
	out := assemble('  .text\n1:\n  je 2f\n  jmp 1b\n2:\n  ret\n')!
	assert out.text_relocs.len == 0
	// Short forms now: je is 74 ib, jmp is EB ib (sizing relaxes them).
	assert out.text == [u8(0x74), 0x02, 0xeb, 0xfc, 0xc3, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
		0x90, 0x90, 0x90, 0x90]
}

fn test_semicolon_statements() {
	out := assemble('  .text\ntest %rax,%rax; js 1f; pxor %xmm0,%xmm0; jmp 2f; 1:\n  ret\n2:\n  ret\n')!
	// test(3) js(2) pxor(4) jmp(2) ret(1) ret(1) = 13, padded to 16.
	assert out.text.len == 16
}

fn test_bss_and_zero() {
	out := assemble('  .bss\n  .align 16\nx:\n  .zero 32\n')!
	assert out.bss_size == 32
	assert out.symbols.any(it.name == 'x' && it.section == 3 && it.offset == 0)
}

fn test_globl_marks_global() {
	out := assemble('  .text\n  .globl f\nf:\n  ret\n  .text\ng:\n  ret\n')!
	f := out.symbols.filter(it.name == 'f')[0]
	g := out.symbols.filter(it.name == 'g')[0]
	assert f.is_global
	assert !g.is_global
}

fn test_local_labels_stay_out_of_symtab() {
	out := assemble('  .data\n  .align 1\n.L..1:\n  .byte 65\n')!
	assert !out.symbols.any(it.name == '.L..1')
}

fn test_refusals_name_the_line() {
	for line in ['  sar %rax, (%rax, %rcx)', '  mov %fs:0, %rax', '  int3', '  .comm x, 4',
		'  mov (%rax), %rbx, %rcx'] {
		if _ := assemble('  .text\n' + line + '\n') {
			assert false, 'expected refusal for "${line}"'
		} else {
			assert err.msg().len > 0
		}
	}
}
