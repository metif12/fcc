module ext

import os
import src.core

// Tests for installable external plugins: config-declared inputs register
// into the pipeline, and `plugin add/remove` round-trips through fcc.toml.

fn test_register_external_inputs_claims_extensions() {
	core.reset_registries()
	mut cfg := core.default_config()
	cfg.plugins['wlang'] = core.PluginDef{
		command:    'wlang-transpile'
		kind:       'input'
		extensions: ['.w']
	}
	// Disabled and command-less declarations register nothing.
	cfg.plugins['off'] = core.PluginDef{
		enabled:    false
		command:    'nope'
		extensions: ['.z']
	}
	cfg.plugins['nocmd'] = core.PluginDef{
		kind:       'input'
		extensions: ['.y']
	}
	register_external_inputs(cfg)
	p := core.find_input('hello.w') or { panic('external input not registered') }
	assert p.name() == 'external-wlang'
	assert p.extensions() == ['.w']
	assert p.can_handle('HELLO.W')
	assert !p.can_handle('hello.c')
	assert core.find_input('x.z') == none
	assert core.find_input('x.y') == none
	// Re-registering is safe: no duplicates.
	register_external_inputs(cfg)
	assert core.list_inputs().len == 1
	core.reset_registries()
}

fn test_plugin_add_remove_roundtrip() {
	dir := os.join_path(os.temp_dir(), 'fcc_ext_cfg_test')
	os.mkdir_all(dir) or { panic(err.msg()) }
	path := os.join_path(dir, 'fcc.toml')
	if os.is_file(path) {
		os.rm(path) or {}
	}
	defer {
		os.rm(path) or {}
	}
	plugin_add_to_file(path, 'wlang', core.PluginDef{
		command:    'wlang-transpile'
		kind:       'input'
		extensions: ['.w']
	}) or { panic(err.msg()) }
	text := os.read_file(path) or { panic(err.msg()) }
	assert text.contains('[plugin."wlang"]')
	assert text.contains('command = "wlang-transpile"')
	assert text.contains('extensions = [".w"]')
	// Re-adding updates in place, no duplicate section.
	plugin_add_to_file(path, 'wlang', core.PluginDef{
		command:    'other'
		kind:       'input'
		extensions: ['.w', '.wat']
	}) or { panic(err.msg()) }
	text2 := os.read_file(path) or { panic(err.msg()) }
	assert text2.contains('command = "other"')
	assert text2.contains('extensions = [".w", ".wat"]')
	assert text2.count('[plugin."wlang"]') == 1
	// The written file parses back.
	cfg := core.load_config_file(path) or { panic(err.msg()) }
	assert cfg.plugins['wlang'].command == 'other'
	assert cfg.plugins['wlang'].extensions == ['.w', '.wat']
	// Removal drops the section; removing again is not an error.
	plugin_remove_from_file(path, 'wlang') or { panic(err.msg()) }
	text3 := os.read_file(path) or { panic(err.msg()) }
	assert !text3.contains('[plugin."wlang"]')
	plugin_remove_from_file(path, 'wlang') or { panic(err.msg()) }
}

fn test_discover_external_commands_runs() {
	// No PATH manipulation: just assert the scan works and is sorted.
	found := discover_external_commands()
	mut prev := ''
	for v in found {
		assert v == v.trim_space() && v != ''
		assert v >= prev
		prev = v
	}
}
