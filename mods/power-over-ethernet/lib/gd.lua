-- lib/gd.lua -- allocation-free reads across the sandbox boundary.

local M = {}

-- pcall takes arguments, so these are created once instead of per call.
-- A `pcall(function() ... end)` allocates a closure every call, and enough of
-- them in a hot path (transform runs on every spawn) churns the sandbox heap
-- until a push faults. These shared functions do the boundary op with no
-- allocation.
local function _index(o, k)   return o[k] end
local function _indexed(o, k) return o.get_indexed(k) end
local function _parent(o)     return o.get_parent() end
local function _children(o)   return o.get_children() end
local function _find(o, pat, cls) return o.find_children(pat, cls, true, false) end
local function _set(o, k, v)  o[k] = v end
local function _seti(o, k, v) o.set_indexed(k, v) end
-- Split by arity: passing an explicit nil to a zero-arg method sends one
-- argument, which a strict binding rejects (and unblock() would never run).
local function _call0(o, m)    return o[m]() end
local function _call1(o, m, a) return o[m](a) end

--- Read a field. nil if absent or unreadable.
function M.get(o, k)
    if o == nil then return nil end
    local ok, v = pcall(_index, o, k)
    if ok then return v end
    return nil
end

--- Read one component of a Vector2/Color, e.g. "position:x".
function M.gidx(o, k)
    if o == nil then return nil end
    local ok, v = pcall(_indexed, o, k)
    if ok then return v end
    return nil
end

function M.parent(o)
    if o == nil then return nil end
    local ok, v = pcall(_parent, o)
    if ok then return v end
    return nil
end

function M.children(o)
    if o == nil then return nil end
    local ok, v = pcall(_children, o)
    if ok then return v end
    return nil
end

--- Recursive find_children, owned-only=false.
function M.find(o, cls)
    if o == nil then return nil end
    local ok, v = pcall(_find, o, "*", cls)
    if ok then return v end
    return nil
end

--- Set a field. Silent no-op if o is nil or the set faults.
function M.set(o, k, v)  if o ~= nil then pcall(_set, o, k, v) end end

--- Set a Vector2/Color component, e.g. "position:x".
function M.seti(o, k, v) if o ~= nil then pcall(_seti, o, k, v) end end

--- Call a 0- or 1-arg method by name: gd.call(n, "unblock"), gd.call(pc, "add_local", pwr).
--- Returns the method's result, so it also stands in for a pcall'd duplicate().
function M.call(o, m, a)
    if o == nil then return nil end
    local ok, v
    if a == nil then ok, v = pcall(_call0, o, m) else ok, v = pcall(_call1, o, m, a) end
    if ok then return v end
    return nil
end

function M.name(o) return tostring(M.get(o, "name")) end

--- Walk a GDArray, skipping elements that cannot be read.
---
--- Array.iter(sentinel) substitutes the sentinel for a banned or freed element
--- instead of raising -- and a raw `arr[i]` on such an element throws
--- std::bad_cast when the binding pushes a null Object, which `pcall` CANNOT
--- catch (it is a host fault, not a Lua error). This is the only safe way to
--- iterate get_devices(), whose list holds transient nulls during world setup
--- and teardown.
---
--- Called as `iter, arr, -1` so it works whether iter is the stateless form the
--- typings describe or a stateful closure: a closure ignores the extra args.
function M.each(arr, fn)
    if arr == nil then return end
    local ok, iter = pcall(function() return arr:iter(false) end)
    if not ok or type(iter) ~= "function" then return end
    for i, v in iter, arr, -1 do
        if v ~= false and v ~= nil then fn(i, v) end
    end
end

--- Case-insensitive substring match, for the many name lookups.
function M.matches(haystack, needle)
    if not haystack or not needle or needle == "" then return false end
    return string.find(string.lower(tostring(haystack)),
                       string.lower(needle), 1, true) ~= nil
end

return M
