#+feature dynamic-literals
package main

import lua "vendor:lua/5.4"
import "core:flags"
import "core:os"
import "core:strings"
import "base:runtime"
import "core:mem"
import "core:log"
import "core:time"
import "core:thread"
import "core:slice"
import "core:sys/windows"
import "core:sync/chan"

CLI_Args :: struct {
	path: string `args:"pos=0,required" usage:"Path to lua used to generate theme"`,
	output_path: string `args:"pos=1" usage:"Path where theme gets output"`,
	generator: Generator `args:"pos=2" usage:"Editor to generate theme for defaults to VSCode"`,
	live: bool `usage:"Set this flag to enable the interactive mode"`,

	// VSCode generator only flags
	skeleton: bool `usage:"Set this flag to generate a whole VSCode theme directory`,
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

Generator_Strings := [Generator]string {
	.VSCode = "VSCode",
}

generate_theme :: proc(args: CLI_Args) {
	lua_state := setup_lua_state(args)

	cstr_path := strings.clone_to_cstring(args.path)
	if lua.L_dofile(lua_state, cstr_path) != 0 {
		err := lua.tostring(lua_state, -1)
		log.error("Error running lua file:", err)

		if args.live {
			log.info("Continuing watch.")
		}
	} else {
		switch args.generator {
			case .VSCode: {
				generate_vscode_theme(args, lua_state)
			}
		}
	}

	delete(cstr_path)
	lua.close(lua_state)
}

setup_logging :: proc(level: log.Level) -> Logger {
	log_file, _ := os.open("./log.txt", {.Create, .Trunc, .Write})
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

included_base_libs := map[string]Open_Proc {
		"_G" = lua.open_base,
		"package" = lua.open_package,
		"math" = lua.open_math,
		"string" = lua.open_string,
		"table" = lua.open_table,
		"utf8" = lua.open_utf8,
}

setup_lua_state :: proc(args: CLI_Args) -> ^lua.State {
	s := lua.L_newstate()

	open_base_libs(s, included_base_libs)

	// Add builtin libraries
	{
		context.allocator = context.temp_allocator
		lua.getglobal(s, "package")

		lua.getfield(s, -1, "path")
		original_path := strings.clone_from(lua.tostring(s, -1))
		lua.pop(s, 1)

		exe_path, _ := os.get_executable_directory(context.temp_allocator)
		color_lua_path, _ := os.join_path({exe_path, "builtin_lua", "color", "init.lua"}, context.temp_allocator)

		final_path := strings.concatenate({original_path, ";", color_lua_path})
		final_path_cstr := strings.clone_to_cstring(final_path)

		lua.pushstring(s, final_path_cstr)
		lua.setfield(s, -2, "path")

		lua.pop(s, 1)
		free_all(context.temp_allocator)
	}

	// Other globals
	{
		context.allocator = context.temp_allocator
		lua.pushstring(s, strings.clone_to_cstring(Generator_Strings[args.generator]))
		lua.setglobal(s, "generator")

		free_all(context.temp_allocator)
	}

	return s
}

parse_cli_args :: proc() -> CLI_Args {
	args: CLI_Args
	flags.parse_or_exit(&args, os.args)

	if fixed_output, err := os.replace_path_separators(args.output_path, os.Path_Separator, context.allocator); err == nil {
		args.output_path = fixed_output
	} else {
		log.panic("Error replacing output path:", err)
	}

	if fixed_input, err := os.replace_path_separators(args.path, os.Path_Separator, context.allocator); err == nil {
		args.path = fixed_input
	} else {
		log.panic("Error replacing input path:", err)
	}

	return args
}

cleanup_cli_args :: proc(args: CLI_Args) {
	delete(args.path)
	delete(args.output_path)
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		if len(track.allocation_map) > 0 {
			log.error("Leaked", len(track.allocation_map), "allocations")
			for _, entry in track.allocation_map {
				log.error(entry.size, "@", entry.location)
			}
		}
		mem.tracking_allocator_destroy(&track)
	}

	when ODIN_OS == .Windows {
		windows.SetConsoleOutputCP(.UTF8)
		windows.SetConsoleCP(.UTF8)
	}
	
	logger := setup_logging(.Debug)
	context.logger = logger.multi_logger
	defer cleanup_logging(logger)

	args := parse_cli_args()
	defer cleanup_cli_args(args)

	if args.live {
		command_channel, chan_err := chan.create(chan.Chan(^Command), 5, context.allocator)
		if chan_err != nil {
			log.panic("Failed to create command channel:", chan_err)
		}
		
		thread_data := Thread_Data{
			args = args,
			send_chan = chan.as_send(command_channel),
		}

		input_thread := thread.create_and_start_with_poly_data(thread_data, input_thread_proc, context)

		recv_chan := chan.as_recv(command_channel)

		our_last_modify := time.now()
		if os.exists(args.path) {
			mod_err: os.Error
			our_last_modify, mod_err = os.modification_time_by_path(args.path)
			if mod_err != nil {
				log.panic("Failed to get initial modification time:", mod_err)
			}
		}

		in_live := true
		for in_live {
			for {
				if cmd, ok := chan.try_recv(recv_chan); ok {
					switch type in cmd {
						case Exit: {
							in_live = false
						}
					}

					destroy_command(cmd)
				} else {
					break
				}
			}
			
			modification_time, mod_err := os.modification_time_by_path(args.path)
			if mod_err != nil {
				log.panic("Failed to get modification time:", mod_err)
			}

			if modification_time != our_last_modify {
				generate_theme(args)
				our_last_modify = modification_time
			}

			time.sleep(25 * time.Millisecond)
		}

		thread.destroy(input_thread)
		chan.destroy(command_channel)
	} else {
		generate_theme(args)
	}	
}