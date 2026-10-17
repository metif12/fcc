module driver
import src.ast

fn parse(args []string) !Options {
	return parse_args(args)
}

fn opts(args []string) Options {
	o := parse_args(args) or { panic('unexpected parse failure for ${args}: ${err.msg()}') }
	return o
}

fn test_parses_the_v_invocation_shape() {
	// This is the argument list `v` builds for a cached program unit link, taken
	// from driver.v:14173. If vcc cannot parse what V sends, it is not a
	// replacement, so this test is a contract, not a convenience.
	o := opts([
		'-std=gnu11'
		'-B',
		'C:/v/thirdparty/tcc'
		'-I',
		'C:/v/thirdparty/tcc/include'
		'-L',
		'C:/v/thirdparty/tcc/lib'
		'-w'
		'-Werror=implicit-function-declaration'
		'-bt25'
		'-municode'
		'-mconsole'
		'-Wl,--stack=33554432'
		'-o',
		'main.exe'
		'main.c'
		'obj.o'
		'-lmbedtls',
	])
	assert o.std == 'gnu11'
	assert o.resource_root == 'C:/v/thirdparty/tcc'
	assert o.includes == ['C:/v/thirdparty/tcc/include']
	assert o.lib_paths == ['C:/v/thirdparty/tcc/lib']
	assert o.suppress_warnings
	assert o.fatal_implicit_fn
	assert o.define_backtrace
	assert o.backtrace_frames == 25
	assert o.unicode_subsystem
	assert o.subsystem == 'console'
	assert o.stack_size == 33554432
	assert o.output == 'main.exe'
	assert o.inputs == ['main.c']
	assert o.objects == ['obj.o']
	assert o.libs == ['mbedtls']
}

fn test_separated_and_joined_flag_forms_both_work() {
	// driver.v passes some flags joined (`-I${dir}`) and some separated
	// (`-isystem <dir>`); a flag parser that handles only one form will drop
	// half the include path and fail much later with a confusing error.
	joined := opts(['-IX:\\inc', '-DX=1', '-UX', '-LX:\\lib', '-lfoo', 'x.c'])
	separated := opts(['-I', 'X:\\inc', '-D', 'X=1', '-U', 'X', '-L', 'X:\\lib', '-l', 'foo', 'x.c'])
	assert joined.includes == separated.includes
	assert joined.defines == separated.defines
	assert joined.undefines == separated.undefines
	assert joined.lib_paths == separated.lib_paths
	assert joined.libs == separated.libs
}

fn test_preprocessor_passthrough_options() {
	o := opts(['-include', 'pre.h', '-isystem', 'sys', '-imacros', 'm.h', 'x.c'])
	assert o.pre_includes == ['pre.h']
	assert o.sys_includes == ['sys']
	// `-imacros m.h` is accepted for contract compatibility, but its operand must
	// not become an input file: `m.h` is a header to process, not a translation
	// unit to compile.
	assert o.inputs == ['x.c']
	assert !o.inputs.contains('m.h')
}

fn test_object_and_library_inputs_are_separated_from_sources() {
	// Order matters for archives, so the relative order of objects and libs must
	// survive parsing rather than being merged into one list.
	o := opts(['a.c', 'one.o', 'two.lib', 'b.c', 'three.a', '-lbar'])
	assert o.inputs == ['a.c', 'b.c']
	assert o.objects == ['one.o', 'two.lib', 'three.a']
	assert o.libs == ['bar']
}

fn test_compile_only_and_shared() {
	o := opts(['-c', '-o', 'x.obj', 'x.c'])
	assert o.compile_only
	assert !o.shared
	o2 := opts(['-shared', '-o', 'x.dll', 'x.c'])
	assert o2.shared
	assert !o2.compile_only
}

fn test_bt_without_a_number_defaults_to_twenty_five() {
	// V always sends a number, but `-bt` alone must not silently disable the
	// backtrace, because V's backtraces.c.v calls tcc_backtrace unconditionally.
	o := opts(['-bt', 'x.c'])
	assert o.define_backtrace
	assert o.backtrace_frames == 25
}

fn test_ignores_flags_meaningless_to_vcc() {
	// V computes one large flag set for every compiler. Refusing the ones that
	// do not apply would make vcc unusable as a drop-in.
	o := opts(['-O2', '-Wall', '-fno-strict-aliasing', '-g', '-mavx', '-mcpu=native', '-idirafter',
		'after', 'x.c'])
	assert o.inputs == ['x.c']
}

fn test_rejects_an_unknown_flag_rather_than_ignoring_it() {
	// Silently dropping a flag that vcc does not understand would produce a
	// wrong binary with no diagnostic, which is the worst possible failure.
	if _ := parse(['-this-does-not-exist', 'x.c']) {
		assert false, 'expected an error for an unrecognised option'
	} else {
		assert err.msg().contains('unrecognized option')
	}
}

fn test_requires_at_least_one_input() {
	if _ := parse(['-c']) {
		assert false, 'expected an error when no input is given'
	} else {
		assert err.msg().contains('no input files')
	}
}

fn test_version_and_help_short_circuit() {
	assert opts(['--version']).show_version
	assert opts(['--help']).show_help
	// Neither needs an input file.
	assert opts(['--help']).inputs.len == 0
}

fn test_summary_renders_the_parsed_flags() {
	o := opts(['-c', '-std=gnu11', '-bt25', '-o', 'x.obj', 'x.c'])
	s := o.summary()
	assert s.contains('-c')
	assert s.contains('-std=gnu11')
	assert s.contains('-bt25')
	assert s.contains('x.c')
}

// --- -target ---

// Both spellings, because the two toolchains differ: V and gcc pass `-target=x`,
// and a build script written for either should work.
fn test_target_is_accepted_joined_and_separated() {
	joined := resolve_triple(&opts(['-target=x86_64-linux', 'x.c'])) or { panic('joined failed') }
	separated := resolve_triple(&opts(['-target', 'x86_64-linux', 'x.c'])) or { panic('separated failed') }
	assert joined == 'x86_64-linux'
	assert separated == joined
	// The operand must not become an input file, which is the failure mode
	// `options_that_consume_an_operand` exists to prevent.
	assert opts(['-target=x86_64-linux', 'x.c']).inputs == ['x.c']
}

// target_error_message is what `-target` fails with for these arguments, or an
// empty string when it resolves.
//
// The tests assert on a message rather than on a Result because V will not let a
// `!`-returning call be assigned without handling its error, and the thing under
// test here *is* the message: a refusal that does not say which ABI is missing is
// the failure mode this file exists to catch.
fn target_error_message(args []string) string {
	o := parse_args(args) or { return 'parse failed: ' + err.msg() }
	resolve_triple(&o) or { return err.msg() }
	return ''
}

// triple_for is the canonical triple `-target` resolves to.
fn triple_for(args []string) string {
	o := opts(args)
	return resolve_triple(&o) or { panic('${args} did not resolve') }
}

// No `-target` means the target fcc was built for — not the machine it happens to
// be running on, which would make cross-compilation impossible by construction.
fn test_no_target_means_the_host_target() {
	assert triple_for(['x.c']) == 'x86_64-windows'
	assert target_error_message(['x.c']) == ''
	assert ast.host_triple == 'x86_64-windows'
	assert ast.codegen_ready_for_triple(ast.host_triple)
}

// An unknown triple is a hard error, never a silent fallback. A fallback here would
// emit the right machine's code under the wrong machine's name, which is the one
// failure this project will not ship.
fn test_an_unknown_target_is_an_error_that_lists_the_known_ones() {
	msg := target_error_message(['-target=x86_64-plan9', 'x.c'])
	assert msg != ''
	assert msg.contains('unknown target')
	assert msg.contains('x86_64-plan9')
	// The list comes from the table rather than from the message, so it cannot drift
	// away from what `resolve_target` accepts.
	assert msg.contains('x86_64-windows')
	assert msg.contains('x86_64-linux')
	// Both spellings of the flag, because a build script may use either.
	assert target_error_message(['-target', 'x86_64-plan9', 'x.c']).contains('unknown')
	// An explicitly empty value is not "not given": it is what an unset variable
	// expands to, and it must not quietly build for the host.
	assert target_error_message(['-target=', 'x.c']).contains('requires a target')
	assert target_error_message(['-target', '', 'x.c']).contains('requires a target')
}

// The aliases exist so a build script can pass whichever spelling its own toolchain
// would, and each has to land on the target it names rather than on the default.
fn test_target_aliases_resolve_to_their_own_target() {
	for spelling in ['x86_64-windows', 'x86_64-windows-msvc', 'x86_64-pc-windows-msvc',
		'amd64-windows'] {
		assert triple_for(['-target=${spelling}', 'x.c']) == 'x86_64-windows'
		assert ast.abi_for_triple(spelling) or { panic('no abi') } == .microsoft_x64
	}
	for spelling in ['x86_64-linux', 'x86_64-linux-gnu', 'x86_64-unknown-linux-gnu',
		'amd64-linux'] {
		assert triple_for(['-target=${spelling}', 'x.c']) == 'x86_64-linux'
		assert ast.abi_for_triple(spelling) or { panic('no abi') } == .sysv_x64
	}
}

// `known_triples` is written beside the resolver rather than derived from it, so
// this is what keeps the two in agreement: every spelling the error message offers
// has to be one the resolver accepts.
fn test_every_advertised_triple_resolves() {
	for spelling in ast.known_triples() {
		assert target_error_message(['-target=${spelling}', 'x.c']) == ''
	}
}

// The front end can type the System V target; the backend cannot emit it. The
// compiler has to say so rather than generate Microsoft-ABI code, and the
// diagnostic has to name the convention that is missing rather than reporting the
// target as unknown — it is known, and every header already agrees.
fn test_codegen_is_refused_for_a_target_the_backend_cannot_emit() {
	assert !ast.codegen_ready_for_triple('x86_64-linux')
	assert ast.codegen_ready_for_triple('x86_64-windows')
	// The refusal, as `-S` would print it.
	assert codegen_refusal(['-target=x86_64-linux', 'x.c']).contains('x86_64-linux')
	assert codegen_refusal(['-target=x86_64-linux', 'x.c']).contains('sysv-x64')
	// The message names the convention that does exist, so a reader knows it is not
	// a typo or an unsupported flag…
	assert codegen_refusal(['-target=x86_64-linux', 'x.c']).contains('microsoft-x64')
	// …and it names the modes that do work, because refusing everything would make
	// the flag look unsupported rather than partially supported.
	assert codegen_refusal(['-target=x86_64-linux', 'x.c']).contains('--preprocess')
	// The default target generates, and an alias for it generates too.
	assert codegen_refusal(['x.c']) == ''
	assert codegen_refusal(['-target=amd64-windows', 'x.c']) == ''
}

// codegen_refusal is what `-S` would print for these arguments, or an empty string
// when it would generate code.
fn codegen_refusal(args []string) string {
	o := parse_args(args) or { return 'parse failed: ' + err.msg() }
	refuse_unimplemented_codegen(&o) or { return err.msg() }
	return ''
}

// `--verbose` shows the target the type model actually came from, so an unknown
// spelling is echoed rather than quietly replaced by the default.
fn test_the_summary_shows_the_target() {
	assert opts(['x.c']).summary().contains('-target x86_64-windows')
	assert opts(['-target=x86_64-linux', 'x.c']).summary().contains('-target x86_64-linux')
	assert opts(['-target=x86_64-plan9', 'x.c']).summary().contains('-target x86_64-plan9')
}
