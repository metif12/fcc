module ast

// Direct AST construction for input plugins.
//
// The C parser builds nodes through its own constructors in `src/fcc`; a
// language plugin that wants real AST nodes (rather than C text fed back
// through the preprocessor) builds them here. Every constructor takes the
// producing language's id, so provenance (`Node.lang`) is set at creation and
// never assigned as an afterthought.
//
// Types still come from the caller: C's type constructors live in `src/fcc`
// because sizes are target-measured, and a plugin reuses them (or builds its
// own `Type` values) rather than this module guessing at another language's
// layout.

// synth_tok makes a token for generated code.
//
// Plugin-built nodes have no source position; V's zero `Token` would claim
// line 0 of no file, so this names the generator instead. Diagnostics that
// print `tok.text` still read sensibly.
pub fn synth_tok(text string) Token {
	return Token{
		kind: .ident
		text: text
		loc:  invalid_pos
	}
}

// num_node makes an integer literal.
pub fn num_node(v i64, ty &Type, tok Token, lang string) &Node {
	return &Node{
		kind: .num
		ty:   ty
		tok:  tok
		num:  v
		lang: lang
	}
}

// var_ref_node makes a reference to obj.
pub fn var_ref_node(obj &Obj, tok Token, lang string) &Node {
	return &Node{
		kind: .var_ref
		ty:   obj.ty
		tok:  tok
		var:  obj
		lang: lang
	}
}

// binary_node makes a two-operand expression of an explicit kind.
pub fn binary_node(kind NodeKind, l &Node, r &Node, ty &Type, tok Token, lang string) &Node {
	return &Node{
		kind: kind
		ty:   ty
		tok:  tok
		lhs:  l
		rhs:  r
		lang: lang
	}
}

// unary_node makes a one-operand expression of an explicit kind.
pub fn unary_node(kind NodeKind, e &Node, ty &Type, tok Token, lang string) &Node {
	return &Node{
		kind: kind
		ty:   ty
		tok:  tok
		lhs:  e
		lang: lang
	}
}

// call_node makes a call of target with args.
pub fn call_node(target &Node, args []&Node, ty &Type, tok Token, lang string) &Node {
	return &Node{
		kind: .funcall
		ty:   ty
		tok:  tok
		lhs:  target
		args: args.clone()
		lang: lang
	}
}

// assign_node makes `l = r`.
pub fn assign_node(l &Node, r &Node, tok Token, lang string) &Node {
	return &Node{
		kind: .assign
		ty:   l.ty
		tok:  tok
		lhs:  l
		rhs:  r
		lang: lang
	}
}

// expr_stmt_node lifts an expression into a statement.
pub fn expr_stmt_node(e &Node, tok Token, lang string) &Node {
	return &Node{
		kind: .expr_stmt
		tok:  tok
		lhs:  e
		lang: lang
	}
}

// block_node makes a `{ stmts }` block.
pub fn block_node(stmts []&Node, tok Token, lang string) &Node {
	return &Node{
		kind: .block_
		tok:  tok
		body: stmts.clone()
		lang: lang
	}
}

// if_node makes `if (cond) then else els`. Either branch may be nil.
pub fn if_node(cond &Node, then &Node, els &Node, tok Token, lang string) &Node {
	return &Node{
		kind: .if_
		tok:  tok
		cond: cond
		then: then
		els:  els
		lang: lang
	}
}

// return_node makes `return v`. A nil v is a bare `return`.
pub fn return_node(v &Node, tok Token, lang string) &Node {
	return &Node{
		kind: .return_
		tok:  tok
		lhs:  v
		lang: lang
	}
}

// plugin_node makes a `.plugin` node: carried verbatim until a `post_parse`
// hook lowers it, reported by the backend if one survives that long.
pub fn plugin_node(plugin_name string, data map[string]string, tok Token, lang string) &Node {
	return &Node{
		kind:        .plugin
		tok:         tok
		lang:        lang
		plugin:      plugin_name
		plugin_data: data.clone()
	}
}

// var_obj makes a local or global variable object. Linkage and storage come
// from the caller mutating the result; the constructor only names and types.
pub fn var_obj(name string, ty &Type) &Obj {
	return &Obj{
		name: name
		ty:   ty
	}
}

// func_obj makes a function object with params and an (initially empty) body.
pub fn func_obj(name string, ty &Type, params []&Obj) &Obj {
	return &Obj{
		name:        name
		ty:          ty
		is_function: true
		params:      params.clone()
	}
}
