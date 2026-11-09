module core

import src.ast

// Tests for multi-unit name dedupe: two units whose generated names collide
// must come out linkable, with goto/label edges intact.

fn unit_with_generated() []&ast.Obj {
	ty := &ast.Type{
		kind:  .basic
		basic: .char_
		size:  1
		align: 1
	}
	mut str := &ast.Obj{
		name: '.L..1'
		ty:   ty
	}
	mut goto_ := &ast.Node{
		kind:         .goto_
		unique_label: '.L..3'
	}
	mut label := &ast.Node{
		kind:         .label
		unique_label: '.L..3'
	}
	mut body := &ast.Node{
		kind: .block_
		body: [goto_, label]
	}
	mut fn_ := &ast.Obj{
		name:        'f'
		ty:          ty
		is_function: true
		body:        [body]
	}
	return [str, fn_]
}

fn test_dedupe_leaves_single_unit_alone() {
	mut ctx := PipelineContext{}
	ctx.globals << unit_with_generated()
	dedupe_generated_names(mut ctx)
	assert ctx.globals[0][0].name == '.L..1'
	assert ctx.globals[0][1].body[0].body[0].unique_label == '.L..3'
}

fn test_dedupe_qualifies_later_units_consistently() {
	mut ctx := PipelineContext{}
	ctx.globals << unit_with_generated()
	ctx.globals << unit_with_generated()
	dedupe_generated_names(mut ctx)
	// Unit 0 keeps pristine spelling.
	assert ctx.globals[0][0].name == '.L..1'
	// Unit 1 is qualified, globals and flow labels alike.
	assert ctx.globals[1][0].name == '.L..1.u1'
	stmts := ctx.globals[1][1].body[0].body
	assert stmts[0].unique_label == '.L..3.u1'
	assert stmts[1].unique_label == '.L..3.u1'
}

fn test_dedupe_rewrites_relocations() {
	ty := &ast.Type{
		kind:  .basic
		basic: .char_
		size:  1
		align: 1
	}
	mut target := &ast.Obj{
		name: '.L..7'
		ty:   ty
	}
	mut holder := &ast.Obj{
		name: '.L..8'
		ty:   ty
		rel:  [
			ast.Relocation{
				offset: 0
				label:  '.L..7'
			},
		]
	}
	mut ctx := PipelineContext{}
	ctx.globals << [&ast.Obj{
		name: 'anchor'
		ty:   ty
	}]
	ctx.globals << [target, holder]
	dedupe_generated_names(mut ctx)
	assert target.name == '.L..7.u1'
	assert holder.rel[0].label == '.L..7.u1'
}
