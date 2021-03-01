
local common <const> = require("cyan.tlcommon")
local config <const> = require("cyan.config")
local cs <const> = require("cyan.colorstring")
local fs <const> = require("cyan.fs")
local graph <const> = require("cyan.graph")
local lfs <const> = require("lfs")
local log <const> = require("cyan.log")
local util <const> = require("cyan.util")

local ivalues <const>, split <const>
	= util.tab.ivalues, util.str.split

local function assert_log<T>(x: T, msg: string): T
	if not x then
		log.err(msg)
		os.exit(1)
	end
	return x
end

local file <const> = assert_log(..., "no file given")
local target <const> = assert_log(select(2, ...), "no target given: expected one of 'lua' or 'c'")
assert_log(
	target ~= "lua" or target ~= "c",
	"expected target to be one of 'lua' or 'c', got: " .. target
)

local main <const> = fs.path.new(file)

local starting_dir <const> = fs.current_dir()
local config_path <const> = fs.search_parent_dirs(lfs.currentdir(), config.filename)
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

local cfg_ok <const>, loaded_config <const>, env <const>
	= common.load_cfg_env_report_errs(true)

assert_log(cfg_ok, "error loading config")

assert(lfs.chdir(starting_dir:to_real_path()))

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
	local cmd <const> = "chmod u+x " .. outfile
	log.info("Executing: ", cmd)
	os.execute(cmd)
end

--- Write out to a C file to compile
local function write_c()
	local outfile <const> = "out.c"
	local fh <const> = assert(io.open(outfile, "w"))
	fh:write[[
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <stdio.h>

int main(int argc, char **argv) {
	lua_State *L = luaL_newstate();
	if (!L) {
		fprintf(stderr, "Could not open Lua state\n");
		return 3;
	}

	luaL_openlibs(L);
	
	const int loaded = luaL_loadstring(L,
]]

		local function quoteln(s: string): string
			return "\t\t\"" .. s:gsub("\\", "\\\\"):gsub("\"", "\\\"") .. '" "\\n"' .. "\n"
		end

		for name, mod in pairs(modules) do
			fh:write(quoteln(("package.preload[%q] = function(...)"):format(name)))
				for ln in split(mod, "\n", true) do
					fh:write(quoteln(ln))
				end
				fh:write(quoteln("end"))
			end

			for ln in split(compiled_main, "\n", true) do
				fh:write(quoteln(ln))
			end

			fh:write[[
	);

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
	fh:close()
	log.info("Wrote ", cs.highlight(cs.colors.file, outfile))
	local cmd <const> = "cc -O3 " .. outfile .. " -llua -o out"
	log.info("Executing: ", cmd)
	os.execute(cmd)
end

if target == "lua" then
	write_lua()
else
	write_c()
end
