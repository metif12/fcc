module core

// blip is fcc's small config/build language. It is intentionally
// TOML-compatible: every valid blip config without a `task`/`plugin` block
// is valid TOML, and `task "name" { ... }` desugars to `[task."name"]`.
//
// Supported forms:
//   # comment
//   key = value            (string "..." / '...' / int / bool / array)
//   [section] / [task."name"] / ["quoted.section"]
//   task "name" { k = v ... }     -> [task."name"]
//   plugin "name" { ... }         -> [plugin."name"]
//   build { ... }                 -> [build]  (bare block sugar)
//
// desugar_blip rewrites the sugar into plain TOML so the stdlib toml
// parser remains the single source of truth for values.

pub fn desugar_blip(src string) string {
	mut out := []string{}
	for raw in src.split_into_lines() {
		line := raw.trim_space()
		if line == '' || line.starts_with('#') || line.starts_with('//') {
			out << raw
			continue
		}
		// task "name" {  /  plugin "name" {  /  build {
		if (line.starts_with('task ') || line.starts_with('plugin ')
			|| line == 'build {' || line.starts_with('build ')) && line.ends_with('{') {
			header := line[..line.len - 1].trim_space()
			if header.starts_with('task ') {
				name := unquote(header['task '.len..].trim_space())
				out << '[task."' + name + '"]'
				continue
			}
			if header.starts_with('plugin ') {
				name := unquote(header['plugin '.len..].trim_space())
				out << '[plugin."' + name + '"]'
				continue
			}
			if header == 'build' {
				out << '[build]'
				continue
			}
			out << raw
			continue
		}
		if line == '}' {
			// end of sugar block: TOML has no closers, drop it.
			continue
		}
		out << raw
	}
	return out.join('\n')
}

fn unquote(s string) string {
	t := s.trim_space()
	if t.len >= 2
		&& ((t.starts_with('"') && t.ends_with('"')) || (t.starts_with("'") && t.ends_with("'"))) {
		return t[1..t.len - 1]
	}
	return t
}
