#+feature dynamic-literals
package luatest

import lua "vendor:lua/5.4"
import "core:fmt"
import "core:flags"
import "core:os"
import "core:strings"
import "core:c"
import "base:runtime"
import "core:mem"
import "core:log"

CLI_Args :: struct {
	path: cstring `args:"pos=0,required" usage:"Path to lua used to generate theme"`,
	output_path: cstring `args:"pos=1" usage:"Path where theme gets output"`,
	generator: Generator `args:"pos=2" usage:"Editor to generate theme for defaults to VSCode"`
}

Generator :: enum {
	VSCode,
}

Logger :: struct {
	log_file: ^os.File,
	file_logger: runtime.Logger,
	console_logger: runtime.Logger,
	multi_logger: runtime.Logger,
}

Generator_Strings := [Generator]cstring {
	.VSCode = "VSCode",
}

setup_logging :: proc(level: log.Level) -> Logger {
	log_file, _ := os.open("./log.txt", {.Create})
	file_logger := log.create_file_logger(log_file, level)
	console_logger := log.create_console_logger(level)
	multi_logger := log.create_multi_logger(file_logger, console_logger)

	return {
		log_file,
		file_logger,
		console_logger,
		multi_logger,
	}
}

cleanup_logging :: proc(logger: Logger) {
	log.destroy_console_logger(logger.console_logger)
	log.destroy_file_logger(logger.file_logger)
	log.destroy_multi_logger(logger.multi_logger)
	os.close(logger.log_file)
}

included_base_libs: map[string]Open_Proc = {
		"_G" = lua.open_base,
		"package" = lua.open_package,
//		"coroutine" = lua.open_coroutine,
//		"debug" = lua.open_debug,
//		"io" = lua.open_io,
		"math" = lua.open_math,
//		"os" = lua.open_os,
		"string" = lua.open_string,
		"table" = lua.open_table,
		"utf8" = lua.open_utf8,
}

setup_lua_state :: proc(args: CLI_Args) -> ^lua.State {
	s := lua.L_newstate()

	open_base_libs(s, included_base_libs)

	// Add builtin libraries
	{
		lua.getglobal(s, "package")

		lua.getfield(s, -1, "path")
		original_path := strings.clone_from(lua.tostring(s, -1), context.temp_allocator)
		lua.pop(s, 1)

		exe_path, _ := os.get_executable_directory(context.temp_allocator)
		final_path := strings.concatenate({original_path, ";", exe_path, "\\builtin_lua\\color\\init.lua"}, context.temp_allocator)
		final_path_cstr := strings.clone_to_cstring(final_path, context.temp_allocator)

		lua.pushstring(s, final_path_cstr)
		lua.setfield(s, -2, "path")

		lua.pop(s, 1)
		free_all(context.temp_allocator)
	}

	lua.pushstring(s, Generator_Strings[args.generator])
	lua.setglobal(s, "generator")

	return s
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	defer {
		if len(track.allocation_map) > 0 {
			log.log(.Error, "Leaked", len(track.allocation_map), "allocations")
			for _, entry in track.allocation_map {
				log.log(.Error, entry.size, "@", entry.location)
			}
		}
		mem.tracking_allocator_destroy(&track)
	}
	
	logger := setup_logging(.Debug)
	context.logger = logger.multi_logger
	defer cleanup_logging(logger)

	args: CLI_Args
	flags.parse_or_exit(&args, os.args)
	
	lua_state := setup_lua_state(args)

	if lua.L_dofile(lua_state, args.path) != 0 {
		err := lua.tostring(lua_state, -1)
		log.log(.Fatal, "Error running lua file", err)
		os.exit(1)
	}

	switch args.generator {
		case .VSCode: {
			generate_vscode_theme(args, lua_state)
		}
	}

	lua.close(lua_state)
	delete(args.path)
	delete(args.output_path)
}