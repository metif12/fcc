module driver

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
