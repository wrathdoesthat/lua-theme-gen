package luatest

import "core:fmt"
import lua "vendor:lua/5.4"
import "core:os"
import "core:encoding/json"
import "core:strings"
import "core:log"
import "base:runtime"
import "core:mem"
import vmem "core:mem/virtual"

/* 
	An example vscode theme table would look something like this
	{
		name = "test_theme",
		type = "dark",
		semanticHighlighting = true,
		colors = {
			["test.scope"] = color.new(180, 0.1, 0.9),
			["test.scope2"] = "#FF00AA"
		},
		tokenColors = {
			{
				scope = {"arrscope1.yeah", "arrscope2.test"},
				foreground = color.new(65, 0.5, 0.5),
				background = color.new(90, 0.9, 0.9),
				fontStyle = "bold",
			},
			{
				scope = "nonarrscope.help",
				foreground = color.new(65, 0.5, 0.5),
				background = "#FA018B",
				fontStyle = "bold",
			},
		},
		semanticTokenColors = {
			OperatorNew = "#AAFF00"
		},
	} 
*/

Token_Color :: struct {
	scope: string,
	scopes: []string,
	multiple_scopes: bool,

	foreground: string,
	background: string,
	fontStyle: string,
	content: string,
}

VSCode_Theme :: struct {
	name: string,
	type: string,
	semanticHighlighting: bool,
	colors: map[string]string,
	semanticTokenColors: map[string]string,
	tokenColors: []Token_Color,

	arena: ^vmem.Arena,
	allocator: mem.Allocator,
}

create_vscode_theme :: proc() -> ^VSCode_Theme {
	theme := new(VSCode_Theme)
	
	theme.arena = new(vmem.Arena)
	init_err := vmem.arena_init_growing(theme.arena)
	if init_err != nil {
		log.log(.Fatal, "Error initializing virtual arena", init_err)
		os.exit(1)
	}

	theme.allocator = vmem.arena_allocator(theme.arena)

	theme.colors = make(map[string]string, theme.allocator)
	theme.semanticTokenColors = make(map[string]string, theme.allocator)
	return theme
}

destroy_vscode_theme :: proc(t: ^VSCode_Theme) {
	vmem.arena_destroy(t.arena)
	free(t.arena)
	free(t)
}

generate_vscode_theme :: proc(args: CLI_Args, state: ^lua.State) {
	theme := create_vscode_theme()
	defer destroy_vscode_theme(theme)

	// Try to convert theme from lua table
	{	
		context.allocator = theme.allocator
		if !lua.istable(state, -1) {
			log.log(.Fatal, "Value return from file is not a table")
			os.exit(1)
		}

		if name, ok := str_f_t(state, "name"); ok {
			theme.name = name
		}
		if type, ok := str_f_t(state, "type"); ok {
			theme.type = type
		}
		if has, ok := bool_f_t(state, "semanticHighlighting"); ok {
			theme.semanticHighlighting = has
		}

		// https://stackoverflow.com/a/6142700
		// Colors
		{
			push_sub_table(state, "colors")
			lua.pushnil(state)

			for lua.next(state, -2) != 0 {
				// key
				scope := lua.tostring(state, -2)

				// val
				color := lua.L_tostring(state, -1)
				lua.pop(state, 2)
				theme.colors[strings.clone_from_cstring(scope)] = strings.clone_from_cstring(color)
			}

			lua.pop(state, 1)
		}

		// Semantic token colors
		{
			push_sub_table(state, "semanticTokenColors")
			lua.pushnil(state)

			for lua.next(state, -2) != 0 {
				// key
				scope := lua.tostring(state, -2)

				// val
				color := lua.L_tostring(state, -1)
				lua.pop(state, 2)
				theme.semanticTokenColors[strings.clone_from(scope)] = strings.clone_from(color)
			}

			lua.pop(state, 1)
		}

		// Token colors
		{
			token_colors := make([dynamic]Token_Color)
			push_sub_table(state, "tokenColors")
			lua.pushnil(state)

			for lua.next(state, -2) != 0 {
				if !lua.istable(state, -1) {
					log.log(.Fatal, "Item in tokenColors is not a table")
					os.exit(1)
				}

				tok := Token_Color{
					multiple_scopes = false,
				}

				// get scopes
				{
					lua.getfield(state, -1, "scope")
					scope_type := lua.type(state, -1)

					#partial switch scope_type {
						case .STRING: {
							scope := lua.tostring(state, -1)
							tok.scope = strings.clone_from(scope)
						};
						case .TABLE: {
							tok.multiple_scopes = true
							scopes := make([dynamic]string)
							lua.pushnil(state)
							for lua.next(state, -2) != 0 {
								scope := lua.tostring(state, -1)
								scope_str := strings.clone_from(scope)
								append(&scopes, scope_str)
								lua.pop(state, 1)
							}
							tok.scopes = scopes[:]
						};
						case: {
							log.log(.Fatal, "Unknown scope type")
							os.exit(1)
						}
					}

					lua.pop(state, 1)
				}

				if fg, ok := col_f_t(state, "foreground"); ok {
					tok.foreground = fg
				}
				if bg, ok := col_f_t(state, "background"); ok {
					tok.background = bg
				}
				if style, ok := str_f_t(state, "fontStyle"); ok {
					tok.fontStyle = style
				}
				if content, ok := str_f_t(state, "content"); ok {
					tok.content = content
				}

				append(&token_colors, tok)
				lua.pop(state, 1)
			}

			theme.tokenColors = token_colors[:]
			lua.pop(state, 1)
		}
	}

	// Marshal theme to file
	{
		context.allocator = context.temp_allocator

		out := make(json.Object)
		out["$schema"] = "vscode://schemas/color-theme"
		out["type"] = theme.type
		out["name"] = theme.name
		out["semanticHighlighting"] = theme.semanticHighlighting

		out["colors"] = make(json.Object)
		colors_obj := make(json.Object)
		for scope in theme.colors {
			colors_obj[scope] = theme.colors[scope]
		}
		out["colors"] = colors_obj

		out["tokenColors"] = make(json.Array)
		tokens := make(json.Array)
		for item in theme.tokenColors {
			token_color := make(json.Object)

			if item.multiple_scopes {
				scopes := make(json.Array)

				for scope in item.scopes {
					append(&scopes, scope)
				}

				token_color["scope"] = scopes
			} else {
				token_color["scope"] = item.scope
			}

			token_color["foreground"] = item.foreground
			token_color["background"] = item.background
			token_color["fontStyle"] = item.fontStyle
			append(&tokens, token_color)
		}
		out["tokenColors"] = tokens

		out["semanticTokenColors"] = make(json.Object)
		colors := make(json.Object)
		for item in theme.semanticTokenColors {
			colors[item] = theme.semanticTokenColors[item]
		}
		out["semanticTokenColors"] = colors

		data, err := json.marshal(out, {pretty = true})
		if err != nil {
			log.log(.Fatal, "Failed marshalling theme", err)
			os.exit(1)
		}

		out_path := strings.concatenate({strings.clone_from(args.output_path), "/theme.json"})
		out_file, open_err := os.open(out_path, {.Create})
		if open_err != nil {
			log.log(.Fatal, "Error opening theme file", open_err)
			os.exit(1)
		}

		_, write_err := os.write(out_file, data)
		if write_err != nil {
			log.log(.Fatal, "Error writing to theme file", write_err)
			os.exit(1)
		}

		log.log(.Info, "Successfully wrote theme to", out_path)

		free_all(context.temp_allocator)
	}

	destroy_vscode_theme(theme)
}