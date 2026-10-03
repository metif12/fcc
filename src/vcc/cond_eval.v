module vcc

import ast

// The `#if` expression evaluator.
//
// This lives in the preprocessor rather than the parser because an `#if` may use
// macros the parser will never see, and because `defined X` must be resolved before
// macro expansion — expanding first would replace the operand.
//
// Arithmetic follows C's integer promotions on `intmax_t`: every value is an i64 with
// a separate unsigned flag, because `#if 0xFFFFFFFFu > 0` is true and getting that
// backwards silently changes which branch is compiled.
//
// Punctuation is compared with double-quoted strings. A backtick literal is a `rune`
// in this V build and cannot be compared with a `string`, which is what a token's
// `text` is.

// Eval is one value of a `#if` expression.
pub struct Eval {
pub mut:
	// v is the value, held as intmax_t so a 64-bit literal is not truncated.
	v i64
	// is_unsigned records unsignedness, which is what makes `#if -1 > 0u` true.
	is_unsigned bool
}

// CondEval walks a directive's argument text and answers whether the branch is live.
//
// `p` is held so the evaluator can report diagnostics through the preprocessor,
// which is why an arithmetic mistake in an `#if` is a message rather than a crash.
struct CondEval {
mut:
	toks []ast.Token
	pos  int
	p    &Preprocessor
	line int
}

// eval_condition evaluates an `#if` or `#elif` operand.
fn (mut p Preprocessor) eval_condition(text string, line int) bool {
	// The tokenizer's eof sentinel is dropped: the primary case treats an unknown
	// identifier as 0, and eof is not an identifier.
	mut body := []ast.Token{}
	for t in tokenize_fragment(text) {
		if t.kind == .eof {
			continue
		}
		body << t
	}
	if body.len == 0 {
		p.errorf(line, '#if with no expression')
		return false
	}
	mut e := CondEval{
		toks: body
		pos:  0
		p:    p
		line: line
	}
	v := e.conditional()
	if e.pos < e.toks.len {
		p.errorf(line, 'unexpected token in #if expression: ${e.toks[e.pos].text}')
	}
	return v.v != 0
}

// eval_ifdef evaluates `#ifdef` or `#ifndef`, whose operand must not be expanded.
fn (mut p Preprocessor) eval_ifdef(name string, rest string, line int) bool {
	mut operand := ''
	for t in tokenize_fragment(rest) {
		if t.kind == .eof {
			continue
		}
		if t.kind == .ident || t.kind == .keyword {
			operand = t.text
			break
		}
	}
	if operand.len == 0 {
		p.errorf(line, '#${name} expects a macro name')
		return false
	}
	present := p.is_defined(operand)
	return if name == 'ifdef' { present } else { !present }
}

fn (e &CondEval) peek() ?ast.Token {
	if e.pos < e.toks.len {
		return e.toks[e.pos]
	}
	return none
}

fn (e &CondEval) at(text string) bool {
	t := e.peek() or { return false }
	return t.text == text
}

fn (mut e CondEval) eat(text string) bool {
	if e.at(text) {
		e.pos++
		return true
	}
	return false
}

// conditional is the `?:` level: right-associative and the outermost operator.
fn (mut e CondEval) conditional() Eval {
	cond := e.logical_or()
	if !e.eat('?') {
		return cond
	}
	then_val := e.conditional()
	if !e.eat(':') {
		e.p.errorf(e.line, 'expected : in #if conditional')
		return then_val
	}
	else_val := e.conditional()
	return if cond.v != 0 { then_val } else { else_val }
}

fn (mut e CondEval) logical_or() Eval {
	mut left := e.logical_and()
	for e.eat('||') {
		right := e.logical_and()
		left = bool_eval((left.v != 0) || (right.v != 0))
	}
	return left
}

fn (mut e CondEval) logical_and() Eval {
	mut left := e.bit_or()
	for e.eat('&&') {
		right := e.bit_or()
		left = bool_eval((left.v != 0) && (right.v != 0))
	}
	return left
}

fn (mut e CondEval) bit_or() Eval {
	mut left := e.bit_xor()
	// `|` must not swallow the `||` that logical_or already handled, so the check is
	// for a bare bar.
	for e.at('|') && !e.at('||') {
		e.pos++
		right := e.bit_xor()
		left = arith(left.v | right.v, left.is_unsigned || right.is_unsigned)
	}
	return left
}

fn (mut e CondEval) bit_xor() Eval {
	mut left := e.bit_and()
	for e.eat('^') {
		right := e.bit_and()
		left = arith(left.v ^ right.v, left.is_unsigned || right.is_unsigned)
	}
	return left
}

fn (mut e CondEval) bit_and() Eval {
	mut left := e.equality()
	for e.at('&') && !e.at('&&') {
		e.pos++
		right := e.equality()
		left = arith(left.v & right.v, left.is_unsigned || right.is_unsigned)
	}
	return left
}

fn (mut e CondEval) equality() Eval {
	mut left := e.relational()
	for {
		if e.eat('==') {
			right := e.relational()
			left = bool_eval(left.v == right.v)
			continue
		}
		if e.eat('!=') {
			right := e.relational()
			left = bool_eval(left.v != right.v)
			continue
		}
		return left
	}
}

fn (mut e CondEval) relational() Eval {
	mut left := e.shift()
	for {
		// `<=` and `>=` are tried first so they are not consumed as `<` and then `=`.
		mut op := ''
		for candidate in ['<=', '>=', '<', '>'] {
			if e.at(candidate) {
				op = candidate
				break
			}
		}
		if op.len == 0 {
			return left
		}
		e.pos++
		right := e.shift()
		left = bool_eval(compare(op, left, right))
	}
	// Every path through the loop returns; this satisfies the flow checker.
	return left
}

// compare applies one relational operator, honouring unsignedness.
fn compare(op string, l Eval, r Eval) bool {
	if l.is_unsigned || r.is_unsigned {
		a := u64(l.v)
		b := u64(r.v)
		return match op {
			'<' { a < b }
			'>' { a > b }
			'<=' { a <= b }
			else { a >= b }
		}
	}
	return match op {
		'<' { l.v < r.v }
		'>' { l.v > r.v }
		'<=' { l.v <= r.v }
		else { l.v >= r.v }
	}
}

fn (mut e CondEval) shift() Eval {
	mut left := e.additive()
	for {
		if e.eat('<<') {
			right := e.additive()
			left = arith(left.v << right.v, left.is_unsigned)
			continue
		}
		if e.eat('>>') {
			right := e.additive()
			// Shifting a negative value right is implementation-defined; arithmetic
			// shift is what every compiler on this platform does.
			left = arith(left.v >> right.v, left.is_unsigned)
			continue
		}
		return left
	}
}

fn (mut e CondEval) additive() Eval {
	mut left := e.multiplicative()
	for {
		if e.eat('+') {
			right := e.multiplicative()
			left = arith(left.v + right.v, left.is_unsigned || right.is_unsigned)
			continue
		}
		if e.eat('-') {
			right := e.multiplicative()
			left = arith(left.v - right.v, left.is_unsigned || right.is_unsigned)
			continue
		}
		return left
	}
}

fn (mut e CondEval) multiplicative() Eval {
	mut left := e.unary()
	for {
		if e.eat('*') {
			right := e.unary()
			left = arith(left.v * right.v, left.is_unsigned || right.is_unsigned)
			continue
		}
		if e.eat('/') {
			right := e.unary()
			if right.v == 0 {
				e.p.errorf(e.line, 'division by zero in #if')
				return left
			}
			left = arith(left.v / right.v, left.is_unsigned || right.is_unsigned)
			continue
		}
		if e.eat('%') {
			right := e.unary()
			if right.v == 0 {
				e.p.errorf(e.line, 'modulo by zero in #if')
				return left
			}
			left = arith(left.v % right.v, left.is_unsigned || right.is_unsigned)
			continue
		}
		return left
	}
}

fn (mut e CondEval) unary() Eval {
	if e.eat('+') {
		return e.unary()
	}
	if e.eat('-') {
		v := e.unary()
		return arith(-v.v, v.is_unsigned)
	}
	if e.eat('~') {
		v := e.unary()
		return arith(~v.v, v.is_unsigned)
	}
	if e.eat('!') {
		v := e.unary()
		return bool_eval(v.v == 0)
	}
	return e.primary()
}

fn (mut e CondEval) primary() Eval {
	t := e.peek() or {
		e.p.errorf(e.line, 'unexpected end of #if expression')
		return Eval{}
	}
	if t.text == '(' {
		e.pos++
		v := e.conditional()
		if !e.eat(')') {
			e.p.errorf(e.line, 'expected ) in #if expression')
		}
		return v
	}
	if t.text == 'defined' {
		return e.defined()
	}
	if t.kind == .num_ {
		e.pos++
		return arith(t.val, is_unsigned_literal(t.text))
	}
	if t.kind == .keyword {
		e.p.errorf(e.line, 'unexpected keyword ${t.text} in #if expression')
		e.pos++
		return Eval{}
	}
	if t.kind == .ident {
		// An identifier that reaches this point expanded to nothing, and the standard
		// says it is 0. `true` and `false` are not C keywords, but accepting them
		// costs nothing and no real code depends on it.
		e.pos++
		if t.text == 'true' {
			return bool_eval(true)
		}
		if t.text == 'false' {
			return bool_eval(false)
		}
		return Eval{}
	}
	e.p.errorf(e.line, 'unexpected token ${t.text} in #if expression')
	e.pos++
	return Eval{}
}

// defined evaluates the `defined` operator, in both its `defined X` and
// `defined(X)` spellings.
fn (mut e CondEval) defined() Eval {
	e.pos++
	mut paren := false
	if e.eat('(') {
		paren = true
	}
	name := e.peek() or {
		e.p.errorf(e.line, 'expected a macro name after defined')
		return Eval{}
	}
	e.pos++
	if paren && !e.eat(')') {
		e.p.errorf(e.line, 'expected ) after defined')
	}
	return bool_eval(e.p.is_defined(name.text))
}

// is_unsigned_literal reports whether a numeric literal carries a `u` suffix, which
// is what makes `#if 0xFFFFFFFFu > 0` true rather than false.
fn is_unsigned_literal(text string) bool {
	for c in text {
		if c == `u` || c == `U` {
			return true
		}
	}
	return false
}

fn bool_eval(b bool) Eval {
	return Eval{
		v:           if b { 1 } else { 0 }
		is_unsigned: false
	}
}

fn arith(v i64, unsigned bool) Eval {
	return Eval{
		v:           v
		is_unsigned: unsigned
	}
}
