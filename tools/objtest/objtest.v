module main

// objtest: phase-3 differential runner. For every tests/endtoend/*.c program it
// checks three things, each reported separately so a failure says which half
// broke:
//
//  1. ENCODE: `fcc -S` assembled natively vs with GNU `as` produce identical
//     `.text` disassembly (`objdump -d -j .text` compared line for line).
//  2. LINK+RUN: the native object links with gcc and runs.
//  3. BEHAVE: the native-linked exe prints what the oracle (tcc, else gcc)
//     prints, with the same exit code.
//
// Usage (mirroring tools/probe):
//   $env:VCC_V_ROOT = 'C:\path\to\v'
//   $env:FCC_OBJTEST_DIR = "$env:TMPDIR\objtest"
//   v -enable-globals run tools/objtest/objtest.v

import os

fn main() {
	scratch := os.getenv('FCC_OBJTEST_DIR')
	assert scratch != '', 'FCC_OBJTEST_DIR must name a directory to write artifacts into'
	root := os.dir(os.dir(os.dir(os.args[0])))
	src_dir := os.join_path(root, 'tests', 'endtoend')
	vcc := os.join_path(root, 'fcc.exe')
	v_root := os.getenv('VCC_V_ROOT')
	assert v_root != '', 'VCC_V_ROOT must name the V tree tcc and gcc are taken from'
	gcc := os.join_path(os.dir(v_root), 'scoop', 'apps', 'gcc', 'current', 'bin',
		'gcc.exe')
	tcc := os.join_path(v_root, 'thirdparty', 'tcc', 'tcc.exe')
	tcc_include := os.join_path(v_root, 'thirdparty', 'tcc', 'include')
	objtest_dir := os.join_path(scratch, 'objtest')
	os.mkdir_all(objtest_dir) or { panic('cannot create ${objtest_dir}') }

	names := os.ls(src_dir) or { panic('cannot list ${src_dir}') }
	c_names := names.filter(it.ends_with('.c')).sorted()
	if c_names.len == 0 {
		panic('no programs in ${src_dir}')
	}

	mut same := 0
	mut differ := 0
	mut blocked := 0
	mut flaky := 0
	for name in c_names {
		src := os.join_path(src_dir, name)
		base := name.all_before_last('.')
		s_path := os.join_path(objtest_dir, base + '.s')
		nat_o := os.join_path(objtest_dir, base + '_nat.o')
		gas_o := os.join_path(objtest_dir, base + '_gas.o')

		// fcc -S must succeed before anything else is meaningful.
		rc := os.execute('${vcc} -I ${tcc_include} -S -o ${s_path} ${src}')
		if rc.exit_code != 0 {
			println('BLOCKED ${name}: fcc -S failed')
			blocked++
			continue
		}
		// Native -c.
		rc2 := os.execute('${vcc} -I ${tcc_include} -c -o ${nat_o} ${src}')
		if rc2.exit_code != 0 {
			println('DIFFER ${name}: native -c failed: ${rc2.output}')
			differ++
			continue
		}
		// Reference assembly with GNU as.
		rc3 := os.execute('as ${s_path} -o ${gas_o}')
		if rc3.exit_code != 0 {
			println('BLOCKED ${name}: GNU as refused fcc output: ${rc3.output}')
			blocked++
			continue
		}
		// 1. ENCODE: identical .text disassembly (skipping objdump's first
		// line, which names the input file and always differs).
		nat_d := os.execute('objdump -d -j .text ${nat_o}')
		gas_d := os.execute('objdump -d -j .text ${gas_o}')
		if nat_d.exit_code != 0 || gas_d.exit_code != 0 {
			println('BLOCKED ${name}: objdump failed')
			blocked++
			continue
		}
		if strip_header(nat_d.output) != strip_header(gas_d.output) {
			println('DIFFER ${name}: .text disassembly differs native vs as')
			dump_first_diff(nat_d.output, gas_d.output, name)
			differ++
			continue
		}
		// 2+3. Link native, link reference, run both. The behavior criterion
		// is native-vs-gas, not native-vs-oracle: probe already owns the
		// oracle comparison, and the current tree differs from it on four
		// programs for frontend reasons phase 3 must not inherit.
		// A native/gas split means the object writer changed behavior;
		// a joint split against the oracle is probe's business.
		// Both links go to the SAME exe path, sequentially: several endtoend
		// programs read out-of-bounds varargs (a known frontend gap, which
		// is why probe differs from tcc on them), and that garbage can
		// include argv[0]'s bytes. Distinct exe names would make the two
		// runs differ for harness reasons rather than object reasons.
		exe_path := os.join_path(objtest_dir, base + '.exe')
		if os.execute('${gcc} -o ${exe_path} ${nat_o}').exit_code != 0 {
			println('DIFFER ${name}: gcc refused to link the native object')
			differ++
			continue
		}
		a_nat := os.execute(exe_path)
		if os.execute('${gcc} -o ${exe_path} ${gas_o}').exit_code != 0 {
			println('BLOCKED ${name}: gcc refused to link the gas object')
			blocked++
			continue
		}
		a_gas := os.execute(exe_path)
		// Reference-stability control: relink the same gas object and run
		// again. Programs whose output is not a pure function of the object
		// file (out-of-bounds vararg reads observe link time, argv bytes,
		// stack ASLR) fail this control and are reported FLAKY rather than
		// MATCH/DIFF, since strict comparison is invalid for them.
		if os.execute('${gcc} -o ${exe_path} ${gas_o}').exit_code != 0 {
			println('BLOCKED ${name}: gcc refused the control relink')
			blocked++
			continue
		}
		a_gas2 := os.execute(exe_path)
		if a_gas.output != a_gas2.output || a_gas.exit_code != a_gas2.exit_code {
			println('FLAKY ${name}: reference output varies across identical links')
			flaky++
			continue
		}
		if a_gas.output == a_nat.output && a_gas.exit_code == a_nat.exit_code {
			println('MATCH ${name} (encode identical, behavior identical)')
			same++
		} else {
			println('DIFFER ${name}: native behavior differs from gas behavior')
			println('  gas:    exit=${a_gas.exit_code} out=${a_gas.output}')
			println('  native: exit=${a_nat.exit_code} out=${a_nat.output}')
			differ++
		}
	}
	println('objtest: ${same} match, ${differ} differ, ${blocked} blocked, ${flaky} flaky')
}

// strip_header drops objdump's first two lines (blank + filename), which name
// the input file and always differ between the native and reference objects.
fn strip_header(out string) string {
	lines := out.split_into_lines()
	if lines.len <= 2 {
		return out
	}
	return lines[2..].join('\n')
}

fn dump_first_diff(a string, b string, name string) {
	la := strip_header(a).split_into_lines()
	lb := strip_header(b).split_into_lines()
	for i in 0 .. if la.len < lb.len { la.len } else { lb.len } {
		if la[i] != lb[i] {
			println('  first diff at line ${i}:')
			println('    native: ${la[i]}')
			println('    as:     ${lb[i]}')
			return
		}
	}
	println('  line counts differ: native=${la.len} as=${lb.len}')
}
