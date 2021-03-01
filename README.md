# cyan-bundler

A proof-of-concept for using [cyan](https://github.com/teal-language/cyan) to bundle a lua project into a single native executable.

Doesn't do anything with dependencies, doesn't optimize code. Just creates a simple C shim, statically links it to Lua, and compiles it.

For a more complete/working version of this kind of thing, check out [LuaPak](https://github.com/jirutka/luapak)
