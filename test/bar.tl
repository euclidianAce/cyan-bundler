
local bar = {}
function bar.do_things(): number
	print("hi")
	require"baz"
	return 1
end
return bar
