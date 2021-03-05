
local common <const> = require("cyan.tlcommon")
local config <const> = require("cyan.config")
local cs <const> = require("cyan.colorstring")
local fs <const> = require("cyan.fs")
local graph <const> = require("cyan.graph")
local log <const> = require("cyan.log")
local util <const> = require("cyan.util")

local lfs <const> = require("lfs")

local parser <const> = require "argparse" ("cyan-bundler", "A proof-of-concept Teal project bundler powered by Cyan")

parser:argument("file", "The .tl file that contains the code to execute")
parser:argument("target", "Whether to compile to a single Lua file or single C file")
	:choices{"c", "lua"}
parser:argument("output", "Output file name")

parser:option("--header"):count("*")
parser:option("--clib"):count("*")

parser:option("--lua-module")
	:args(2)
	:count("*")

local args <const> = parser:parse()
-- log.debug(args)

local file <const> = args.file as string
local target <const> = args.target as string

local ivalues <const>, split <const>, map <const>
	= util.tab.ivalues, util.str.split, util.tab.map

local function assert_log<T>(x: T, msg: string): T
	if not x then
		log.err(msg)
		os.exit(1)
	end
	return x
end

local main <const> = fs.path.new(file)

local starting_dir <const> = fs.current_dir()
local config_path <const> = fs.search_parent_dirs(starting_dir:to_real_path(), config.filename)
if not config_path then
	log.err(config.filename .. " not found")
	os.exit(1)
end

local root_dir <const> = config_path:copy()
table.remove(root_dir)
if not lfs.chdir(root_dir:to_real_path()) then
	log.err("Unable to chdir into root directory ", cs.highlight(cs.colors.file, root_dir:to_real_path()))
	os.exit(1)
end

local loaded_config, errs = config.load()
assert_log(config, "error loading config: " .. table.concat(errs or {}, "\n"))
assert(lfs.chdir(starting_dir:to_real_path()))

loaded_config.gen_target = "5.3"
loaded_config.gen_compat = "off"

local env <const> = common.init_env_from_cfg(loaded_config)

local dag <const> = graph.empty()
dag:insert_file(main)

local exit = 0

local function display_filename(f: fs.Path): cs.ColorString
	return cs.highlight(cs.colors.file, f:relative_to(starting_dir))
end

local to_write <const> = {}
local module_names <const>: {graph.Node:string} = {}

local function process_node(n: graph.Node)
	local path <const> = n.input:to_real_path()
	local parsed <const> = common.parse_file(path)
	if #parsed.errs > 0 then
		common.report_errors(log.err, parsed.errs, path, "syntax error")
		exit = 1
		return
	end

	local result <const> = common.parse_result_to_tl_result(parsed)
	common.type_check_ast(parsed.ast, {
		filename = path,
		env = env,
		result = result,
	})
	if not common.report_result(path, result, loaded_config) then
		exit = 1
		return
	end
	log.info("Type checked ", display_filename(n.input))
	for mod, mod_path in pairs(n.modules) do
		local mod_node <const> = dag:find(mod_path)
		if mod_node then
			module_names[mod_node] = mod
		end
	end
	table.insert(to_write, {n, parsed.ast})
end

for n in dag:nodes() do
	process_node(n)
end

if exit ~= 0 then os.exit(exit) end

local compiled_main: string
local modules <const>: {string:string} = {}
for tup in ivalues(to_write) do
	local n <const>, ast <const> = tup[1], tup[2]
	local mod_name <const> = module_names[n]
	if mod_name then
		modules[mod_name] = common.compile_ast(ast)
	else
		compiled_main = common.compile_ast(ast)
	end
end

--- Write out to executable lua file
local function write_lua()
	local outfile <const> = "out"
	local fh <const> = assert(io.open(outfile, "w"))
	fh:write("#!/usr/bin/env lua\n")

	for name, mod in pairs(modules) do
		fh:write(("package.preload[%q] = function(...)\n"):format(name))
		fh:write(mod, "\n")
		fh:write("end\n")
	end

	fh:write("\n\n", compiled_main or "error('no main')")
	fh:close()
	log.info("Wrote ", cs.highlight(cs.colors.file, outfile))
end

--- Write out to a C file to compile
local function write_c()
	local function inc(header: string): string
		return string.format("#include <%s>", header)
	end

	local headers <const> = {
		"lua.h",
		"lualib.h",
		"lauxlib.h",
		"stdio.h",
	}

	for h in ivalues(args.header as {string}) do
		table.insert(headers, h)
	end

	local pre <const> = {
		table.concat(map(headers, inc), "\n"),
	}

	table.insert(pre, [[
#define ADD_LIBRARY(name) \
	lua_pushcfunction(L, luaopen_ ## name ); \
	lua_setfield(L, -2, #name )
]])

	table.insert(pre,[[
int main(int argc, char **argv) {
	lua_State *L = luaL_newstate();
	if (!L) {
		fprintf(stderr, "Could not open Lua state\n");
		return 3;
	}
]])

	table.insert(pre, [[
	luaL_openlibs(L);
]])

	local clibs <const> = args.clib as {string}
	if #clibs > 0 then
		table.insert(pre, [[
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "preload");
]])
		for lib in ivalues(clibs) do
			table.insert(pre, "\tADD_LIBRARY(" .. lib .. ");")
		end
		table.insert(pre, "\tlua_pop(L, 1);")
	end

	local footer <const> = [[

	int exit_code = 0;

	if (loaded != 0) {
		const char *err = lua_tostring(L, -1);
		fprintf(stderr, "Error compiling lua chunk: %s\n", err);
		exit_code = 2;
		goto cleanup;
	}

	lua_createtable(L, argc, 1);
	for (int i = 0; i < argc; ++i) {
		lua_pushstring(L, argv[i]);
		lua_rawseti(L, -2, i);
	}
	lua_setglobal(L, "arg");

	for (int i = 1; i < argc; ++i)
		lua_pushstring(L, argv[i]);

	if (lua_pcall(L, argc - 1, 0, 0) != 0) {
		const char *err = lua_tostring(L, -1);
		fprintf(stderr, "Error: %s\n", err);
		exit_code = 1;
		goto cleanup;
	}

cleanup:
	lua_close(L);
	return exit_code;
}]]

	local outfile <const> = "out.c"
	local fh <const> = assert(io.open(outfile, "w"))

	for s in ivalues(pre) do fh:write(s, "\n") end
	local function quoteln(s: string): string
		return "\t\t\"" .. s:gsub("\\", "\\\\"):gsub("\"", "\\\""):match("^%s*(.-)%s*$") .. '\\n"\n'
	end

	local function writeln(ln: string)
		if #ln:match("^%s*(.-)%s*$") > 0 then
			fh:write(quoteln(ln))
		end
	end

	local function write_module(name: string, content: string)
		fh:write(quoteln(("package.preload[%q] = function(...)"):format(name)))
		for ln in split(content, "\n", true) do
			writeln(ln)
		end
		fh:write(quoteln("end"))
	end

	fh:write("\tconst int loaded = luaL_loadstring(L,\n")

	for name, mod in pairs(modules) do
		write_module(name, mod)
	end

	for m in ivalues(args.lua_module as {{string, string}} or {}) do
		local name <const> = m[1]
		local mod_fh <const> = assert(io.open(m[2], "r"))
		local mod <const> = mod_fh:read("*a")
		mod_fh:close()
		log.info("Source copied ", cs.highlight(cs.colors.file, m[2]), " for module ", cs.highlight(cs.colors.file, name))
		write_module(name, mod)
	end

	for ln in split(compiled_main, "\n", true) do
		writeln(ln)
	end
	fh:write("\t);\n")

	fh:write(footer)
	fh:close()
	log.info("Wrote ", cs.highlight(cs.colors.file, outfile))
end

if target == "lua" then
	write_lua()
else
	write_c()
end
