
local bar <const> = require("bar")
local baz <const> = require("baz")

for k, v in pairs(arg as {number:string}) do
	print(k, v)
end
print("Oh boy command line args: ", ...)
local x <const> = bar.do_things() + baz.other_things()
print(x + 1)
