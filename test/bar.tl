
local mod = {}
function mod.do_things(): number
	print("hi")
	require"baz"
	return 1
end
return mod
