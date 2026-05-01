package main

import lua "vendor:lua/5.4"
import "core:strings"
import "core:c"
import "core:os"
import "core:log"

str_f_t :: proc(s: ^lua.State, name: cstring, allocator := context.allocator) -> (string, bool) {
	lua.getfield(s, -1, name)

	if lua.isnil(s, -1) {
		log.log(.Info, name, "was not found in table or is nil")
		lua.pop(s, 1)
		return "", false
	}
	if !lua.isstring(s, -1) {
		log.log(.Error, name, "was found in table but is not a string")
		lua.pop(s, 1)
		return "", false
	}

	str := lua.tostring(s, -1)
	lua.pop(s, 1)
	return strings.clone_from(str, allocator), true
}

int_f_t :: proc(s: ^lua.State, name: cstring) -> (lua.Integer, bool) {
	lua.getfield(s, -1, name)

	if lua.isnil(s, -1) {
		log.log(.Error, name, "was not found in table or is nil")
		lua.pop(s, 1)
		return 0, false
	}
	if !lua.isinteger(s, -1) {
		log.log(.Error, name, "was found in table but is not an integer")
		lua.pop(s, 1)
		return 0, false
	}

	val := lua.tointeger(s, -1)
	lua.pop(s, 1)
	return val, true
}

bool_f_t :: proc(s: ^lua.State, name: cstring) -> (bool, bool) {
	lua.getfield(s, -1, name)

	if lua.isnil(s, -1) {
		log.log(.Error, name, "was not found in table or is nil")
		lua.pop(s, 1)
		return false, false
	}
	if !lua.isboolean(s, -1) {
		log.log(.Error, name, "was found in table but is not a boolean")
		lua.pop(s, 1)
		return false, false
	}

	val := bool(lua.toboolean(s, -1))
	lua.pop(s, 1)
	return val, true
}

col_f_t :: proc(s: ^lua.State, name: cstring, allocator := context.allocator) -> (string, bool) {
	lua.getfield(s, -1, name)
	
	if lua.isnil(s, -1) {
		log.log(.Error, name, "was nil")
		lua.pop(s, 1)
		return "", false
	}

	if lua.isstring(s, -1) {
		val := lua.tostring(s, -1)
		lua.pop(s, 1)
		return strings.clone_from(val, allocator), true
	}

	if !lua.istable(s, -1) {
		log.log(.Error, name, "was not a table")
		lua.pop(s, 1)
		return "", false
	}

	val := lua.L_tostring(s, -1)
	// L_tostring pushes the string onto the stack
	lua.pop(s, 2)
	return strings.clone_from(val, allocator), true
}

push_sub_table :: proc(s: ^lua.State, name: cstring) {
	lua.getfield(s, -1, name)

	if lua.isnil(s, -1) || !lua.istable(s, -1) {
		log.log(.Fatal, name, "is not a table or is nil")
		os.exit(1)
	}
}

/* 
	map[string]Open_Proc = {
			"_G" = lua.open_base,
			"package" = lua.open_package,
			"coroutine" = lua.open_coroutine,
			"debug" = lua.open_debug,
			"io" = lua.open_io,
			"math" = lua.open_math,
			"os" = lua.open_os,
			"string" = lua.open_string,
			"table" = lua.open_table,
			"utf8" = lua.open_utf8,
	} 
*/
Open_Proc :: #type proc "cdecl" (L: ^lua.State) -> c.int

// a reimplementation of lua_Lopenlibs that only includes ones we actually want
open_base_libs :: proc(s: ^lua.State, open_procs: map[string]Open_Proc) {
	for open_proc in open_procs {
		cstr_name := strings.clone_to_cstring(open_proc, context.temp_allocator)
		lua.L_requiref(s, cstr_name, open_procs[open_proc], 1)
		lua.pop(s, 1)
	}
	free_all(context.temp_allocator)
}