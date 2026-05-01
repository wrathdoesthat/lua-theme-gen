package main

import "core:os"
import "core:io"
import "core:log"
import "core:sync/chan"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import "core:slice"

Exit :: struct{}

Command :: union {
	Exit,
}

parse_command :: proc(text: string) -> (^Command, bool, bool) {
	null_trimmed := strings.trim_right_null(text)
	newline_trimmed := strings.trim_right(null_trimmed, "\r\n")
	split_text, _ := strings.split(newline_trimmed, " ", context.temp_allocator)
	cmd_txt := strings.to_lower(split_text[0], context.temp_allocator)

	command: ^Command
	exists := true
	resume := true
	switch cmd_txt {
		case "exit", "quit", "q": {
			command = new(Command)
			command^ = Exit{}
			resume = false
		}
		case: {
			exists = false
		}
	}

	free_all(context.temp_allocator)
	return command, exists, resume
}

destroy_command :: proc(c: ^Command) {
	#partial switch t in c {
		
	}
	free(c)
}

Thread_Data :: struct {
	args: CLI_Args,
	send_chan: chan.Chan(^Command, .Send),
}

INPUT_BUFFER_SIZE :: 100 * mem.Kilobyte

input_thread_proc :: proc(state: Thread_Data) {
	input_buffer := make([]byte, INPUT_BUFFER_SIZE)
	in_stream := os.to_stream(os.stdin)
	
	for {
		bytes_read, read_err := io.read(in_stream, input_buffer)
		if read_err != nil {
			log.panic("io.read failed:", read_err)
		}
		if bytes_read == 0 {
			continue
		}

		cmd, exists, resume := parse_command(string(input_buffer))
		if !exists {
			slice.zero(input_buffer)
			continue
		}

		chan.send(state.send_chan, cmd)		
		slice.zero(input_buffer)

		if !resume {
			break
		}
	}

	delete(input_buffer)
}