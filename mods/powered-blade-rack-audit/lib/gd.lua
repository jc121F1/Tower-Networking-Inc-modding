-- Small protected access layer copied from the kit's PoE experiment.
local M = {}
local function _index(o, k) return o[k] end
local function _children(o) return o.get_children() end
local function _indexed(o, k) return o.get_indexed(k) end
local function _name(o) return o.get_name() end
local function _class(o) return o.get_class() end
local function _id(o) return o.get_instance_id() end
local function _parent(o) return o.get_parent() end
local function _call0(o, m) return o[m]() end
local function _call1(o, m, a) return o[m](a) end

function M.get(o, k)
	if o == nil then return nil end
	local ok, v = pcall(_index, o, k)
	if ok then return v end
	return nil
end
function M.children(o)
	if o == nil then return nil end
	local ok, v = pcall(_children, o)
	if ok then return v end
	return nil
end
function M.gidx(o, k)
	if o == nil then return nil end
	local ok, v = pcall(_indexed, o, k)
	if ok then return v end
	return nil
end
function M.call(o, method, arg)
	if o == nil then return nil end
	local ok, value
	if arg == nil then
		ok, value = pcall(_call0, o, method)
	else
		ok, value = pcall(_call1, o, method, arg)
	end
	if ok then return value end
	return nil
end
function M.parent(o)
	if o == nil then return nil end
	local ok, v = pcall(_parent, o)
	if ok then return v end
	return nil
end
function M.name(o)
	if o == nil then return "?" end
	local ok, v = pcall(_name, o)
	return ok and tostring(v) or "?"
end
function M.class(o)
	if o == nil then return "?" end
	local ok, v = pcall(_class, o)
	return ok and tostring(v) or "?"
end
function M.id(o)
	if o == nil then return "?" end
	local ok, v = pcall(_id, o)
	return ok and tostring(v) or "?"
end
function M.each(arr, fn)
	if arr == nil then return end
	local ok, iter = pcall(function() return arr:iter(false) end)
	if not ok or type(iter) ~= "function" then return end
	for i, value in iter, arr, -1 do
		if value ~= false and value ~= nil then fn(i, value) end
	end
end
return M
