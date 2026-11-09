module core

import src.ast

// Multi-unit support: several inputs, possibly in several languages, linked
// into one output.
//
// Every front end numbers its compiler-generated names from zero
// (`Parser.new_unique_name` spells them `.L..N`, chibicc's spelling, so a
// single-file `-S` dump stays comparable). Concatenating two units therefore
// defines `.L..1` twice: the assembler rejects it, and silently merging them
// would be worse. The fix is applied once, here, rather than in every parser:
// after all inputs load, every generated name past the first unit is
// qualified with its unit index. Unit 0 keeps pristine spelling, so the
// first unit of a multi-input build is byte-identical to building it alone.
//
// Only generated names are touched (the `.L..` prefix cannot appear in a C
// identifier, so user symbols never match). References need no lookup:
// `var_ref` nodes point at their `Obj` (renaming the object renames every
// use), relocations carry the same label string and are rewritten in place,
// and goto/label/brk/cont pairs are renamed together by one collect-and-edit
// pass, which preserves their matching.

// dedupe_generated_names qualifies generated names in every unit past the
// first. A single input is untouched.
pub fn dedupe_generated_names(mut ctx PipelineContext) {
	if ctx.globals.len <= 1 {
		return
	}
	for i in 1 .. ctx.globals.len {
		suffix := '.u${i}'
		for mut obj in ctx.globals[i] {
			if obj.name.starts_with('.L..') {
				obj.name += suffix
			}
			for ri in 0 .. obj.rel.len {
				if obj.rel[ri].label.starts_with('.L..') {
					obj.rel[ri].label += suffix
				}
			}
			// Goto/label pairs and break/continue targets match by string,
			// so qualifying both sides equally preserves every edge.
			mut flat := []&ast.Node{}
			for st in obj.body {
				ast.collect_all(st, mut flat)
			}
			for mut n in flat {
				if n.unique_label.starts_with('.L..') {
					n.unique_label += suffix
				}
				if n.brk_label.starts_with('.L..') {
					n.brk_label += suffix
				}
				if n.cont_label.starts_with('.L..') {
					n.cont_label += suffix
				}
			}
		}
	}
}
