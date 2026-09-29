-- Small guarded Godot access helpers. Array iteration uses iter(false) to
-- avoid the sandbox bad_cast that raw indexing can cause for freed objects.
local M = {}
local function _get(o, k) return o[k] end
local function _call0(o, m) return o[m]() end
local function _call1(o, m, a) return o[m](a) end
local function _set(o, k, v) o[k] = v end

function M.get(o, k)
	if o == nil then return nil end
	local ok, v = pcall(_get, o, k)
	if ok then return v end
	return nil
end

function M.call(o, m, a)
	if o == nil then return nil end
	local ok, v
	if a == nil then ok, v = pcall(_call0, o, m) else ok, v = pcall(_call1, o, m, a) end
	if ok then return v end
	return nil
end

function M.set(o, k, v)
	if o ~= nil then return pcall(_set, o, k, v) end
	return false, "nil object"
end

function M.name(o)
	if o == nil then return "nil" end
	local value = M.get(o, "name")
	return value ~= nil and tostring(value) or "?"
end

function M.id(o)
	if o == nil then return nil end
	local value = M.call(o, "get_instance_id")
	return value ~= nil and tostring(value) or nil
end

function M.parent(o)
	return M.call(o, "get_parent")
end

function M.each(arr, fn)
	if arr == nil then return end
	local ok, iter = pcall(function() return arr:iter(false) end)
	if not ok or type(iter) ~= "function" then return end
	for i, value in iter, arr, -1 do
		if value ~= false and value ~= nil then fn(i, value) end
	end
end

function M.find_named(root, pattern)
	if root == nil then return nil end
	local ok, found = pcall(function() return root.find_children(pattern, "", true, false) end)
	if ok then return found end
	return nil
end

return M
