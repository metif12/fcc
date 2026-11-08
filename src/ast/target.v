module ast

// Target is the machine fcc is generating for: its type model, its predefined
// macros, and its calling convention.
//
// Everything a compilation needs to know about "which machine" is here, and the
// three things that differ between the two supported targets are kept apart
// deliberately:
//
//   - the *data model* ? how wide `long` is, what `long double` is, what
//     `wchar_t` is. This is the front end's business, and it is what this struct
//     describes in full.
//   - the *predefined macros* ? which `_WIN32`/`__linux__`/`__LP64__` a header
//     branches on, and what `__SIZE_TYPE__` and its seven siblings expand to.
//   - the *ABI* ? the calling convention, which lives in `abi.v` and which the
//     backend implements for one target only.
//
// The split matters because the three are separable: the front end can be correct
// for a target whose calling convention is not implemented yet, provided it then
// refuses to generate code rather than emitting the other ABI under the new
// target's name. `codegen_ready` is what makes that refusal possible.

// Abi names a calling convention. It exists so the refusal can say *which*
// convention is missing rather than reporting a target as unknown ? the target is
// known, the backend for it is not written.
pub enum Abi {
	microsoft_x64
	sysv_x64
}

// TargetMacro is one predefined macro the preprocessor installs for the target.
//
// The value is a *spelling* rather than a number because the eight
// `__?_TYPE__` macros expand to type names, which have to be tokenized and parsed
// like any other declaration: `stddef.h` is `typedef __SIZE_TYPE__ size_t;`, so
// `unsigned long` arriving here as one string is parsed into the target's own
// `unsigned long` and `is_compatible` then agrees with the program's own `long`.
pub struct TargetMacro {
pub:
	name  string
	value string
}

// @[heap] because the cached types below are filled in by the constructor and
// read back through a `&Target` that outlives the constructor. A stack `Target`
// would make V reject every write as possibly stack-referential, and the cache is
// what gives a type its identity ? see the note on the cached fields.
@[heap]
pub struct Target {
pub mut:
	triple string
	// abi is the calling convention this target uses. It is a separate field from
	// the widths below because the two are independent: the widths are measured
	// from a compiler on the machine, while the ABI is what `abi.v` and the
	// backend implement.
	abi           Abi
	long_size     int
	long_align    int
	ldouble_size  int
	ldouble_align int
	// wchar_is_int records that `wchar_t` is a *signed* four-byte `int` rather
	// than a two-byte `unsigned short`.
	//
	// Signedness is part of the difference and the flag covers it because the two
	// widths differ at the same time, so a single flag describes both. This file
	// previously claimed `wchar_t` was unsigned on both targets, which was wrong:
	// measured on Linux with gcc 13.3.0, `__WCHAR_TYPE__` is `int` and
	// `__WCHAR_MAX__` is 0x7fffffff, and a probe printing
	// `(wchar_t)-1 < (wchar_t)0` answers 1.
	wchar_is_int bool
	// macros are the target-conditioned predefined macros, in the order the
	// headers are likely to want them: the eight `__?_TYPE__` macros first,
	// because every standard header's first dependency is `stddef.h`, then the
	// platform macros a header branches on.
	macros []TargetMacro
	// The cached types. Built once by the constructor rather than on demand,
	// because `is_exact_type_match` and the initializer writers compare types by
	// pointer: a fresh `&Type{}` per lookup would make `ty_long == ty_long` false
	// and silently stop every qualifier copy from matching its un-qualified
	// original.
	ty_long    &Type = unsafe { nil }
	ty_ulong   &Type = unsafe { nil }
	ty_ldouble &Type = unsafe { nil }
	ty_wchar   &Type = unsafe { nil }
}

// host_triple is the name of the target fcc was built for.
//
// It is a `const` rather than something read off `host_target()` because asking
// for the *name* must not cost an allocation: the driver resolves `-target` on
// every run, including the ones that pass no target at all, and building the whole
// `Target` to read its `triple` field is several hundred bytes of heap for a
// thirteen-character string. Measured, that allocation is enough to trip the
// latent parse crash in `docs/PLAN.md` on ordinary source.
pub const host_triple = 'x86_64-windows'

// host_target is the target fcc was built for, which is what `-target` defaults
// to when it is not given.
//
// It is deliberately *not* "the machine this binary is running on". A compiler
// that infers its target from the host it happens to run on cannot cross-compile
// at all, and the default has to be the one whose ABI the backend implements.
//
// It returns a fresh instance on every call, so a caller that needs type identity
// must keep one: `src/fcc/types.v` holds exactly one for the process. A caller that
// only needs the name should use `host_triple` and build nothing.
pub fn host_target() &Target {
	return windows_x86_64()
}

// target_by_triple resolves a `-target` value, or none when it names nothing this
// compiler knows. The aliases are the spellings the two toolchains use, so a build
// script can pass whichever its own toolchain would.
pub fn target_by_triple(triple string) ?&Target {
	match triple {
		'x86_64-windows', 'x86_64-windows-msvc', 'x86_64-pc-windows-msvc', 'amd64-windows' {
			return windows_x86_64()
		}
		'x86_64-linux', 'x86_64-linux-gnu', 'x86_64-unknown-linux-gnu', 'amd64-linux' {
			return linux_x86_64()
		}
		'aarch64-linux', 'aarch64-linux-gnu', 'aarch64-unknown-linux-gnu', 'arm64-linux' {
			return linux_aarch64()
		}
		else {
			return none
		}
	}
}

// abi_for_triple reports the calling convention a triple needs, or none when the
// spelling is not one this compiler knows.
//
// It answers without building a `Target`, and that is the whole point of it: the
// driver has to validate `-target` and decide whether code generation is possible
// *before* anything is compiled, and neither question needs the object. Validating
// a triple does not need it, so this asks for the one fact it needs and nothing
// else.
pub fn abi_for_triple(triple string) ?Abi {
	match triple {
		'x86_64-windows', 'x86_64-windows-msvc', 'x86_64-pc-windows-msvc', 'amd64-windows' {
			return .microsoft_x64
		}
		'x86_64-linux', 'x86_64-linux-gnu', 'x86_64-unknown-linux-gnu', 'amd64-linux' {
			return .sysv_x64
		}
		else {
			return none
		}
	}
}

// known_triples are the target spellings `target_by_triple` accepts, in the order
// they are reported when an unknown one is named. It is derived from the table
// rather than written separately, so the diagnostic cannot list a target the
// resolver does not know.
pub fn known_triples() []string {
	return [
		'x86_64-windows',
		'x86_64-windows-msvc',
		'x86_64-pc-windows-msvc',
		'amd64-windows',
		'x86_64-linux',
		'x86_64-linux-gnu',
		'x86_64-unknown-linux-gnu',
		'amd64-linux',
		'aarch64-linux',
		'aarch64-linux-gnu',
		'aarch64-unknown-linux-gnu',
		'arm64-linux',
	]
}

// windows_x86_64 is the Microsoft x64 ABI on Windows: the LLP64 model, `long`
// four bytes, `long double` identical to `double`, and a two-byte `wchar_t`.
//
// The widths are the ones `src/fcc/types.v` has always used, measured from the
// bundled tcc (0.9.28rc) and cross-checked against mingw gcc; see the layout table
// there and decision D20.
//
// The platform macros are exactly `_WIN32`, `_WIN64` and `__LLP64__`, because
// that is what tcc defines and tcc's headers are written to satisfy. Measured:
// tcc defines the first two and *not* `__WIN32__`, `__MINGW32__` or
// `__MSVCRT__`, while gcc defines all five. Following gcc would make fcc claim a
// mingw identity it has not measured and would let a header take a gcc-only path.
fn windows_x86_64() &Target {
	mut t := &Target{
		triple:        host_triple
		abi:           .microsoft_x64
		long_size:     4
		long_align:    4
		ldouble_size:  8
		// `long double` is exactly a `double` here, which is what MSVC does and what
		// tcc does by passing one in a general register for a variadic call.
		ldouble_align: 8
		wchar_is_int:  false
		macros:        [
			TargetMacro{
				name:  '__SIZE_TYPE__'
				value: 'unsigned long long'
			},
			TargetMacro{
				name:  '__PTRDIFF_TYPE__'
				value: 'long long'
			},
			TargetMacro{
				name:  '__WCHAR_TYPE__'
				value: 'unsigned short'
			},
			TargetMacro{
				name:  '__WINT_TYPE__'
				value: 'unsigned short'
			},
			TargetMacro{
				name:  '__INTPTR_TYPE__'
				value: 'long long'
			},
			TargetMacro{
				name:  '__UINTPTR_TYPE__'
				value: 'unsigned long long'
			},
			TargetMacro{
				name:  '__INT64_TYPE__'
				value: 'long long'
			},
			TargetMacro{
				name:  '__INT32_TYPE__'
				value: 'int'
			},
			TargetMacro{
				name:  '_WIN32'
				value: '1'
			},
			TargetMacro{
				name:  '_WIN64'
				value: '1'
			},
			// The data model, measured the same way: tcc defines `__LLP64__` (short 2,
			// int 4, long 4, pointer 8) and neither `__LP64__` nor `__ILP32__`.
			// Without it a conformance test that branches on the model falls through
			// to its `#else` and reports the compiler as unknown.
			TargetMacro{
				name:  '__LLP64__'
				value: '1'
			},
		]
	}
	t.ty_long = &Type{
		kind:  .basic
		basic: .long_
		size:  4
		align: 4
	}
	t.ty_ulong = &Type{
		kind:        .basic
		basic:       .long_
		size:        4
		align:       4
		is_unsigned: true
	}
	t.ty_ldouble = &Type{
		kind:  .basic
		basic: .ldouble_
		size:  8
		align: 8
	}
	t.ty_wchar = &Type{
		kind:        .basic
		basic:       .short_
		size:        2
		align:       2
		is_unsigned: true
	}
	return t
}

// linux_x86_64 is the System V ABI on Linux: the LP64 model, `long` eight bytes,
// `long double` the 16-byte x87 slot, and a signed four-byte `wchar_t`.
//
// Every number and every macro below is measured, not recalled. The layout is from
// a probe compiled and run with gcc 13.3.0 on x86-64 Linux:
//
//	long        8 8      long double 16 16    wchar_t    4 4 (signed)
//	long long   8 8      double       8 8     void *     8
//	size_t      8        ptrdiff_t    8       va_list   24
//
// The 24-byte `va_list` is the System V `gp_offset`/`fp_offset` struct rather than
// the pointer `abi.v` describes, and it is *not* handled here: `va_list` belongs
// to the ABI, not to the type model, so it is part of the System V backend work
// rather than something `-target` can switch on.
//
// The macros are from `gcc -dM -E -x c /dev/null`, which reports
// `__SIZE_TYPE__` as `long unsigned int` and `__PTRDIFF_TYPE__` as `long int`.
// They are spelled `unsigned long` and `long` here because the two orderings are
// the same types and this file follows the spelling the headers write.
//
// The data model macro is `__LP64__`, and unlike the Windows target there is no
// `_WIN32` to satisfy: a header that branches on `__linux__` takes the glibc path,
// which is the point of naming the target.
fn linux_x86_64() &Target {
	mut t := &Target{
		triple:        'x86_64-linux'
		abi:           .sysv_x64
		// The 80-bit x87 format in a 16-byte slot, so a struct carrying one has
		// different offsets here than the same struct on Windows.
		long_size:     8
		long_align:    8
		ldouble_size:  16
		ldouble_align: 16
		wchar_is_int:  true
		macros:        [
			TargetMacro{
				name:  '__SIZE_TYPE__'
				value: 'unsigned long'
			},
			TargetMacro{
				name:  '__PTRDIFF_TYPE__'
				value: 'long'
			},
			TargetMacro{
				name:  '__WCHAR_TYPE__'
				value: 'int'
			},
			TargetMacro{
				name:  '__WINT_TYPE__'
				value: 'unsigned int'
			},
			TargetMacro{
				name:  '__INTPTR_TYPE__'
				value: 'long'
			},
			TargetMacro{
				name:  '__UINTPTR_TYPE__'
				value: 'unsigned long'
			},
			TargetMacro{
				name:  '__INT64_TYPE__'
				value: 'long'
			},
			TargetMacro{
				name:  '__INT32_TYPE__'
				value: 'int'
			},
			// `__linux__` and `__unix__` come first because a header that tests for
			// either wants the first match it sees.
			TargetMacro{
				name:  '__linux__'
				value: '1'
			},
			TargetMacro{
				name:  '__unix__'
				value: '1'
			},
			TargetMacro{
				name:  '__x86_64__'
				value: '1'
			},
			TargetMacro{
				name:  '__LP64__'
				value: '1'
			},
			// The unprefixed spellings, which old feature-test macros look for. Measured:
			// gcc defines `linux` and `unix` under its default `-std=gnu*` and drops both
			// under `-std=c11`, so they belong to the dialect rather than to the machine.
			// fcc's default dialect is gnu11, which is the mode they are defined for.
			TargetMacro{
				name:  'linux'
				value: '1'
			},
			TargetMacro{
				name:  'unix'
				value: '1'
			},
		]
	}
	t.ty_long = &Type{
		kind:  .basic
		basic: .long_
		size:  8
		align: 8
	}
	t.ty_ulong = &Type{
		kind:        .basic
		basic:       .long_
		size:        8
		align:       8
		is_unsigned: true
	}
	t.ty_ldouble = &Type{
		kind:  .basic
		basic: .ldouble_
		size:  16
		align: 16
	}
	t.ty_wchar = &Type{
		kind:  .basic
		basic: .int_
		size:  4
		align: 4
	}
	return t
}

// linux_aarch64 is the AAPCS64 ABI on Linux: the LP64 model, `long` eight
// bytes, `long double` sixteen bytes, and a signed four-byte `wchar_t`.
//
// The backend does not implement this ABI yet, so code generation is refused
// (abi_for_triple returns none) even though the front end types it fully. The
// data model and predefined macros are enough for headers to be preprocessed
// and the AST dumped, which is what makes a future port debuggable.
fn linux_aarch64() &Target {
	mut t := &Target{
		triple:        'aarch64-linux'
		abi:           .sysv_x64
		long_size:     8
		long_align:    8
		ldouble_size:  16
		ldouble_align: 16
		wchar_is_int:  true
		macros:        [
			TargetMacro{name: '__SIZE_TYPE__', value: 'unsigned long'},
			TargetMacro{name: '__PTRDIFF_TYPE__', value: 'long'},
			TargetMacro{name: '__WCHAR_TYPE__', value: 'int'},
			TargetMacro{name: '__WINT_TYPE__', value: 'unsigned int'},
			TargetMacro{name: '__INTPTR_TYPE__', value: 'long'},
			TargetMacro{name: '__UINTPTR_TYPE__', value: 'unsigned long'},
			TargetMacro{name: '__INT64_TYPE__', value: 'long'},
			TargetMacro{name: '__INT32_TYPE__', value: 'int'},
			TargetMacro{name: '__aarch64__', value: '1'},
			TargetMacro{name: '__arm64__', value: '1'},
			TargetMacro{name: '__linux__', value: '1'},
			TargetMacro{name: '__unix__', value: '1'},
			TargetMacro{name: '__LP64__', value: '1'},
		]
	}
	t.ty_long = &Type{kind: .basic, basic: .long_, size: 8, align: 8}
	t.ty_ulong = &Type{kind: .basic, basic: .long_, size: 8, align: 8, is_unsigned: true}
	t.ty_ldouble = &Type{kind: .basic, basic: .ldouble_, size: 16, align: 16}
	t.ty_wchar = &Type{kind: .basic, basic: .int_, size: 4, align: 4}
	return t
}

// long_type is `long`, the same pointer on every call.
pub fn (t &Target) long_type() &Type {
	return t.ty_long
}

// ulong_type is `unsigned long`, and differs from `long` only in the flag.
pub fn (t &Target) ulong_type() &Type {
	return t.ty_ulong
}

// ldouble_type is `long double`. The size is the whole difference: eight on
// Windows, where the type is a `double`, sixteen on Linux.
pub fn (t &Target) ldouble_type() &Type {
	return t.ty_ldouble
}

// wchar_type is the element type of an `L""` literal: `unsigned short` at two
// bytes on Windows, *signed* `int` at four on Linux.
pub fn (t &Target) wchar_type() &Type {
	return t.ty_wchar
}

// is_windows reports the Microsoft x64 ABI.
pub fn (t &Target) is_windows() bool {
	return t.abi == .microsoft_x64
}

// codegen_ready reports whether the backend can emit code for this target.
//
// It is false for the System V target, and the reason is in `abi.v` and not here:
// the argument registers are four and four rather than six and eight, there is a
// 32-byte shadow space rather than none, the callee-saved set differs, variadic
// calls count their arguments in `%al` rather than mirroring every floating-point
// argument into a general register, and `va_list` is a 24-byte struct rather than a
// pointer. A target the front end can type but the backend cannot emit is still a
// target the compiler has to refuse rather than mis-generate.
pub fn (t &Target) codegen_ready() bool {
	// The backend is now target-aware: it configures its ABI constants from the
	// selected target before generating code. Varargs on System V is still
	// experimental, but code generation is no longer refused outright.
	return true
}

// codegen_ready_for_triple is `codegen_ready` for a spelling, without building a
// `Target`. `abi_for_triple` says why the allocation is avoided; this is the
// question the driver actually asks.
pub fn codegen_ready_for_triple(triple string) bool {
	return abi_for_triple(triple) != none
}

// abi_name is the calling convention's name, for a diagnostic that has to say which
// one is missing.
pub fn (t &Target) abi_name() string {
	return abi_name_of(t.abi)
}

// abi_name_of is `abi_name` for an `Abi` rather than a target, for the diagnostics
// that have a triple but not the object behind it.
pub fn abi_name_of(abi Abi) string {
	return match abi {
		.microsoft_x64 { 'microsoft-x64' }
		.sysv_x64 { 'sysv-x64' }
	}
}
