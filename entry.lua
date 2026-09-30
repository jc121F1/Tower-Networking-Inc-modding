-- Reversible rack power proof of concept.
-- A supported UPS can power eligible devices in the same locked Mount.
local gd = require("lib.gd")

local SCAN_PERIOD = 30
local START_DELAY = 120
local MIN_CHARGE_MULTIPLIER = 10
local HOVER_POLL_PERIOD = 6
local HOVER_PARENT_STEPS = 7
local LOCAL_MEMBERSHIP_MAX_ATTEMPTS = 8
local DEBUG_F_KEYCODE = 70
local DEBUG_LOGGING = false -- Set true for mount, array, power, and hover probes.
-- Add one distinctive, lowercase product_name fragment per supported UPS.
local SUPPORTED_UPS_PRODUCT_FRAGMENTS = {
	"mountable tenabolt ups2e",
	"mountable tenabolt ups2h",
	"tenabolt ups2x"
}
local RACK_MOUNT_NAME = "Mount"
local POWER_NODE_NAME = "Power"
local LIGHT_NODE_FRAGMENT = "light"
local SWITCH_NODE_FRAGMENT = "switch"
local HOVER_UNPOWERED_TEXT = "Unpowered"
local HOVER_UNPOWERED_BBCODE_PATTERN = "%[color=[^%]]+%]" .. HOVER_UNPOWERED_TEXT .. "%[/color%]"
local HOVER_POWERED_BBCODE = "[color=green]Powered[/color]"
local tick, ready, scan_after = 0, false, math.huge
local active_world_id = nil
local links = {} -- target device id -> reversible transfer record
local link_ids, tracked_link_ids = {}, {}
local last_rejection = {}
local last_mount_state = {}
local last_source_selection = {}
local hover_patch = nil
local array_probe_sequence = 0
local array_probe_logged = 0
local ARRAY_PROBE_BUDGET = 240
local ARRAY_PROBE_FULL_WINDOW = 120
local array_probe_budget_reported = false
local NODE_ARRAY_SAMPLE_PERIOD = 32

local function log(fmt, ...)
	if DEBUG_LOGGING then print("[ups-powered-racks] " .. string.format(fmt, ...)) end
end

local function warn(fmt, ...)
	print("[ups-powered-racks] WARNING: " .. string.format(fmt, ...))
end

-- Emit a bounded checkpoint immediately before each Godot Array traversal.
-- If the sandbox faults while iterating, the last checkpoint identifies the
-- caller and owning object without dumping the array or retaining its entries.
local function audit_array_iteration(site, owner, array, fn, detail)
	if not DEBUG_LOGGING then return gd.each(array, fn) end
	array_probe_sequence = array_probe_sequence + 1
	local should_log = site ~= "node_children"
		or array_probe_sequence <= ARRAY_PROBE_FULL_WINDOW
		or array_probe_sequence % NODE_ARRAY_SAMPLE_PERIOD == 0
	if should_log and array_probe_logged < ARRAY_PROBE_BUDGET then
		array_probe_logged = array_probe_logged + 1
		log("array checkpoint op=%d logged=%d tick=%d site=%s owner=%s#%s detail=%s",
			array_probe_sequence, array_probe_logged, tick, site, gd.name(owner),
			tostring(gd.id(owner) or "?"), tostring(detail or "-"))
	elseif should_log and not array_probe_budget_reported then
		array_probe_budget_reported = true
		log("array checkpoint budget exhausted at %d; further array probes suppressed", ARRAY_PROBE_BUDGET)
	end
	gd.each(array, fn)
end

local function has(text, fragment)
	return string.find(string.lower(tostring(text or "")), string.lower(fragment), 1, true) ~= nil
end

local function is_ups_source(device)
	local product = gd.get(device, "product_name")
	for i = 1, #SUPPORTED_UPS_PRODUCT_FRAGMENTS do
		if has(product, SUPPORTED_UPS_PRODUCT_FRAGMENTS[i]) then return true end
	end
	return false
end

local function label(device)
	return string.format("%s#%s(%s)", gd.name(device), tostring(gd.id(device) or "?"),
		tostring(gd.get(device, "product_name") or "?"))
end

local function log_mount_state(device, reason, force)
	if not DEBUG_LOGGING then return end
	if not (is_ups_source(device) or gd.get(device, "logic_controller") ~= nil) then return end
	local id = tostring(gd.id(device) or "?")
	local area = gd.get(device, "base_mounted_area")
	local device_pc = gd.get(device, "power_controller")
	local logic = gd.get(device, "logic_controller")
	local logic_power = logic and gd.get(logic, "power") or nil
	local state = string.format("device=%s parent=%s area=%s#%s mount_type=%s locked=%s fixed=%s freeze=%s picked=%s power_disabled=%s logic_power=%s logic_intent=%s",
		label(device), gd.name(gd.parent(device)), gd.name(area), tostring(gd.id(area) or "?"),
		tostring(gd.get(device, "mount_type")), tostring(gd.get(device, "is_mount_locked")),
		tostring(gd.get(device, "fixed")), tostring(gd.get(device, "freeze")),
		tostring(gd.get(device, "is_picked")), tostring(gd.get(device_pc, "disabled")),
		tostring(gd.get(logic_power, "is_powered")), tostring(gd.get(logic_power, "manifest_intent")))
	if force or last_mount_state[id] ~= state then
		last_mount_state[id] = state
		log("mount audit reason=%s %s", reason, state)
	end
end

local function snapshot(power, pc)
	return string.format("power=%s powered=%s intent=%s load=%s controller=%s; pc=%s supply=%s load=%s charge=%s/%s rate=%s enabled=%s disabled=%s",
		tostring(gd.id(power)), tostring(gd.get(power, "is_powered")),
		tostring(gd.get(power, "manifest_intent")), tostring(gd.get(power, "current_load")),
		tostring(gd.id(gd.get(power, "controller"))), tostring(gd.id(pc)),
		tostring(gd.get(pc, "can_supply_power")), tostring(gd.get(pc, "current_load")),
		tostring(gd.get(pc, "charges")), tostring(gd.get(pc, "charge_capacity")),
		tostring(gd.get(pc, "charge_rate")), tostring(gd.get(pc, "is_enabled_and_functional")),
		tostring(gd.get(pc, "disabled")))
end

local function refresh(pc)
	if pc then gd.call(pc, "start_charge_timer") end
end

local function local_count(pc, power)
	local want, count = gd.id(power), 0
	if not pc or not want then return 0 end
	-- `locals` is exposed as an iterable Godot array in the working PoE path;
	-- it is not a Node with a `count(power)` method. Keep this probe aligned
	-- with PoE and avoid emitting a Godot error on every scan.
	audit_array_iteration("controller_locals", pc, gd.get(pc, "locals"), function(_, item)
		if gd.id(item) == want then count = count + 1 end
	end, "power=" .. want)
	return count
end

-- Keep a boolean membership probe for the same validation used by PoE.
local function has_local(pc, power)
	return local_count(pc, power) > 0
end

local function normalize_one_local(pc, power)
	local count = local_count(pc, power)
	if count == 0 then
		local ok, err = pcall(function() pc.add_local(power) end)
		if not ok then return false, 0, tostring(err) end
		count = local_count(pc, power)
	end
	local attempts = 0
	while count > 1 and attempts < LOCAL_MEMBERSHIP_MAX_ATTEMPTS do
		local before = count
		local ok, err = pcall(function() pc.remove_local(power) end)
		if not ok then return false, count, tostring(err) end
		attempts = attempts + 1
		count = local_count(pc, power)
		if count >= before then break end
	end
	if count == 1 then return true, count, nil end
	return false, count, "membership count did not normalize"
end

local function remove_all_locals(pc, power)
	local attempts = 0
	local count = local_count(pc, power)
	while count > 0 and attempts < LOCAL_MEMBERSHIP_MAX_ATTEMPTS do
		local before = count
		local ok, err = pcall(function() pc.remove_local(power) end)
		if not ok then return false, count, tostring(err) end
		attempts = attempts + 1
		count = local_count(pc, power)
		if count >= before then break end
	end
	if count == 0 then return true, count, nil end
	return false, count, "could not remove all memberships"
end

local function restore_power(item, source_alive)
	local power, source, original = item.power, item.source_pc, item.original_pc
	if source_alive and source then remove_all_locals(source, power) end
	if original and power then
		pcall(function() original.add_local(power) end)
		gd.set(power, "controller", original)
		local ok, count, err = normalize_one_local(original, power)
		if not ok then warn("restore membership power=%s count=%d error=%s", tostring(gd.id(power)), count, tostring(err)) end
	end
	if source_alive then refresh(source) end
	refresh(original)
	if item.original_powered then
		pcall(function() power.on() end)
		pcall(function() power.broadcast_restored() end)
	else
		local intent = gd.get(power, "manifest_intent")
		pcall(function() power.broadcast_lost() end)
		if intent ~= nil then gd.set(power, "manifest_intent", intent) end
	end
end

-- Link records hold only values. Resolve nodes from a live device each time
-- they are needed, so a world change cannot strand GDObject wrappers in links.
local function resolve_link(link, by_id)
	local target = by_id[link.target_id]
	local source = by_id[link.source_id]
	local source_pc = source and gd.get(source, "power_controller") or nil
	if source_pc and gd.id(source_pc) ~= link.source_pc_id then source_pc = nil end
	local powers = {}
	if target then
		for _, saved in ipairs(link.powers) do
			local power = gd.call(target, "get_node_or_null", saved.power_path)
			local original_pc = gd.call(target, "get_node_or_null", saved.original_pc_path)
			if gd.id(power) == saved.power_id and gd.id(original_pc) == saved.original_pc_id then
				powers[#powers + 1] = {
					power = power, source_pc = source_pc, original_pc = original_pc,
					original_powered = saved.original_powered, primary = saved.primary,
				}
			elseif not link.resolve_warned then
				link.resolve_warned = true
				warn("link node resolution failed target=%s power=%s original_pc=%s",
					link.target_label, saved.power_id, saved.original_pc_id)
			end
		end
	end
	return source_pc, powers
end

local function restore_link(link, alive, by_id)
	local target_alive = link.target_id and alive[link.target_id]
	local source_alive = link.source_id and alive[link.source_id]
	if target_alive then
		local source_pc, powers = resolve_link(link, by_id)
		if #powers ~= #link.powers then return false end
		for i = #powers, 1, -1 do restore_power(powers[i], source_alive and source_pc ~= nil) end
	end
	log("restored link target=%s source=%s target_alive=%s source_alive=%s reason=%s",
		link.target_label, link.source_label, tostring(target_alive == true),
		tostring(source_alive == true), tostring(link.restore_reason or "rack condition ended"))
	return true
end

local function link_has_power(link, target)
	if not link or not target then return false end
	local target_pc = gd.get(target, "power_controller")
	if not target_pc or gd.get(target_pc, "disabled") ~= false then return false end
	for _, item in ipairs(link.powers) do
		local power = item.primary and gd.call(target, "get_node_or_null", item.power_path) or nil
		if power and gd.id(power) == item.power_id and gd.get(power, "is_powered") == true
			and gd.id(gd.get(power, "controller")) == link.source_pc_id then
			return true
		end
	end
	return false
end

local function update_hover_power_text()
	local camera = ModApiV1.get_player_camera()
	local mouse = gd.get(camera, "mp_mouse")
	local hover_label = gd.get(mouse, "hovertxt")
	local hovered = gd.get(mouse, "curr_hover")
	if not hover_label or not hovered then
		hover_patch = nil
		return
	end
	local device = hovered
	for _ = 1, HOVER_PARENT_STEPS do
		if not device or gd.get(device, "logic_controller") ~= nil
			or gd.get(device, "power_controller") ~= nil then break end
		device = gd.parent(device)
	end
	if not device or (gd.get(device, "logic_controller") == nil
		and gd.get(device, "power_controller") == nil) then
		hover_patch = nil
		return
	end
	local device_id = gd.id(device)
	local text = gd.get(hover_label, "text")
	if type(text) ~= "string" then return end
	local link = links[device_id]
	local powered = link_has_power(link, device)
	if hover_patch and hover_patch.device_id == device_id
		and text == hover_patch.patched and not powered then
		gd.set(hover_label, "text", hover_patch.original)
		hover_patch = nil
		return
	end
	if not powered then
		hover_patch = nil
		return
	end
	if string.find(text, HOVER_UNPOWERED_TEXT, 1, true) then
		if gd.get(hover_label, "bbcode_enabled") ~= true then return end
		local patched, count = string.gsub(text,
			HOVER_UNPOWERED_BBCODE_PATTERN, HOVER_POWERED_BBCODE, 1)
		if count == 0 then
			patched = string.gsub(text, HOVER_UNPOWERED_TEXT, HOVER_POWERED_BBCODE, 1)
		end
		gd.set(hover_label, "text", patched)
		hover_patch = { device_id = device_id, original = text, patched = patched }
		if not link.hover_logged then
			log("corrected hover power label for %s", link.target_label)
			link.hover_logged = true
		end
	end
end

local function transfer_one(power, source_pc, original_pc)
	if not power or not source_pc or not original_pc then return false, "missing power/controller" end
	if gd.id(source_pc) == gd.id(original_pc) then return false, "source is original controller" end
	local original_intent = gd.get(power, "manifest_intent")
	local removed, remove_err = pcall(function() original_pc.remove_local(power) end)
	if not removed then return false, "remove_local failed: " .. tostring(remove_err) end
	local added, add_err = pcall(function() source_pc.add_local(power) end)
	if not added then
		pcall(function() original_pc.add_local(power) end)
		refresh(original_pc)
		return false, "add_local failed: " .. tostring(add_err)
	end
	refresh(original_pc)
	refresh(source_pc)
	local observed_controller = gd.get(power, "controller")
	local controller_matches = gd.id(observed_controller) == gd.id(source_pc)
	local local_registered = has_local(source_pc, power)
	if DEBUG_LOGGING then
		log("transfer membership power=%s original_count=%d source_count=%d controller_matches=%s",
			tostring(gd.id(power)), local_count(original_pc, power),
			local_count(source_pc, power), tostring(controller_matches))
	end
	if not (controller_matches or local_registered) then
		remove_all_locals(source_pc, power)
		pcall(function() original_pc.add_local(power) end)
		gd.set(power, "controller", original_pc)
		normalize_one_local(original_pc, power)
		refresh(source_pc); refresh(original_pc)
		return false, "add_local did not register Power in controller"
	end
	-- Match the known-good PoE route: add_local registers membership but leaves
	-- the Power back-reference on its previous controller on this game build.
	if not controller_matches then gd.set(power, "controller", source_pc) end
	local membership_ok, membership_count, membership_err = normalize_one_local(source_pc, power)
	if DEBUG_LOGGING then
		log("post-controller membership power=%s source_count=%d controller=%s normalized=%s error=%s",
			tostring(gd.id(power)), membership_count,
			tostring(gd.id(gd.get(power, "controller"))), tostring(membership_ok), tostring(membership_err))
	end
	if not membership_ok then
		remove_all_locals(source_pc, power)
		pcall(function() original_pc.add_local(power) end)
		gd.set(power, "controller", original_pc)
		normalize_one_local(original_pc, power)
		refresh(source_pc); refresh(original_pc)
		return false, "source membership normalization failed: " .. tostring(membership_err)
	end
	if gd.id(gd.get(power, "controller")) ~= gd.id(source_pc) then
		remove_all_locals(source_pc, power)
		pcall(function() original_pc.add_local(power) end)
		gd.set(power, "controller", original_pc)
		normalize_one_local(original_pc, power)
		refresh(source_pc); refresh(original_pc)
		return false, "Power.controller back-reference did not update"
	end
	refresh(original_pc)
	refresh(source_pc)
	local powered, power_err = pcall(function()
		if gd.get(power, "is_powered") ~= true then power.on() end
		power.broadcast_restored()
	end)
	if not powered then
		remove_all_locals(source_pc, power)
		pcall(function() original_pc.add_local(power) end)
		gd.set(power, "controller", original_pc)
		normalize_one_local(original_pc, power)
		refresh(source_pc); refresh(original_pc)
		pcall(function() power.broadcast_lost() end)
		if original_intent ~= nil then gd.set(power, "manifest_intent", original_intent) end
		return false, "power restore callback failed: " .. tostring(power_err)
	end
	return true
end

local function collect_devices()
	local devices = {}
	local ok, all_devices = pcall(function() return ModApiV1.get_devices() end)
	if not ok or not all_devices then return devices end
	audit_array_iteration("mod_api_devices", nil, all_devices, function(_, device)
		if gd.get(device, "power_controller") ~= nil
			or gd.get(device, "logic_controller") ~= nil
			or is_ups_source(device) then
			devices[#devices + 1] = device
		end
	end)
	return devices
end

local function estimate_load(device, power, original_pc, primary)
	local logic = gd.get(device, "logic_controller")
	local estimates = {
		current = tonumber(gd.get(power, "current_load")),
		fallback = tonumber(gd.get(power, "default_fallback_load")),
		logic = primary and logic and tonumber(gd.get(logic, "power_load")) or nil,
		controller = primary and original_pc and tonumber(gd.get(original_pc, "charge_rate")) or nil,
	}
	local watts = 0
	for _, value in pairs(estimates) do if value and value > watts then watts = value end end
	if watts <= 0 then return nil end
	return watts
end

local function find_power_nodes(device, source_pc)
	local found, seen = {}, {}
	local function add(power)
		local id = gd.id(power)
		local original_pc = gd.get(power, "controller")
		if not id or seen[id] or gd.get(power, "is_powered") == nil
			or gd.get(power, "manifest_intent") ~= true or not original_pc then return end
		if gd.id(original_pc) == gd.id(source_pc) then return end
		seen[id] = true
		found[#found + 1] = { power = power, original_pc = original_pc }
	end
	local logic = gd.get(device, "logic_controller")
	if logic then add(gd.get(logic, "power")) end
	-- Traverse with get_children (the same path used by the rack audit) instead
	-- of find_children's recursive Array result, which faults after save reloads.
	local pending = {}
	audit_array_iteration("device_children", device, gd.call(device, "get_children"),
		function(_, child) pending[#pending + 1] = child end)
	while #pending > 0 do
		local node = pending[#pending]
		pending[#pending] = nil
		local name = gd.name(node)
		if name == POWER_NODE_NAME then add(node)
		elseif has(name, LIGHT_NODE_FRAGMENT) or has(name, SWITCH_NODE_FRAGMENT) then add(gd.get(node, "power")) end
		audit_array_iteration("node_children", node, gd.call(node, "get_children"),
			function(_, child) pending[#pending + 1] = child end)
	end
	return found
end

local function transfer_target(source, target, source_area)
	local source_pc = gd.get(source, "power_controller")
	local target_pc = gd.get(target, "power_controller")
	local target_logic = gd.get(target, "logic_controller")
	local target_power = target_logic and gd.get(target_logic, "power") or nil
	if not (source_pc and target_pc) then return nil, "missing source/target power controller" end
	if gd.get(target_pc, "disabled") ~= false then return nil, "device power switch is disabled or unknown" end
	local powers = find_power_nodes(target, source_pc)
	if #powers == 0 then return nil, "no target Power loads outside the UPS controller" end
	local primary
	for _, item in ipairs(powers) do
		if target_power and gd.id(item.power) == gd.id(target_power) then primary = item; break end
	end
	if not primary then primary = powers[1] end
	if target_power and gd.get(target_power, "manifest_intent") ~= true then
		return nil, "target device power intent is off"
	end
	local wants_power = false
	for _, item in ipairs(powers) do
		if gd.get(item.power, "manifest_intent") == true then wants_power = true; break end
	end
	if not wants_power then return nil, "target power intent is off" end
	if gd.get(primary.power, "is_powered") == true then return nil, "target already powered" end
	local estimated_main = estimate_load(target, primary.power, primary.original_pc, true) or 0
	local live_total, fallback_total = 0, 0
	for _, item in ipairs(powers) do
		live_total = live_total + (tonumber(gd.get(item.power, "current_load")) or 0)
		fallback_total = fallback_total + (tonumber(gd.get(item.power, "default_fallback_load")) or 0)
	end
	local watts = math.max(estimated_main, live_total, fallback_total)
	local source_rate = tonumber(gd.get(source_pc, "charge_rate"))
	local current_load = tonumber(gd.get(source_pc, "current_load")) or 0
	local charges = tonumber(gd.get(source_pc, "charges")) or 0
	if watts <= 0 or not source_rate then return nil, "unknown load or UPS output rate" end
	if watts > source_rate or current_load + watts > source_rate then return nil, "estimated load exceeds UPS output rate" end
	if charges < watts * MIN_CHARGE_MULTIPLIER then
		return nil, string.format("UPS charge below %dx estimated load reserve", MIN_CHARGE_MULTIPLIER)
	end
	-- Resolve paths before changing any controller. NodePath results are Lua
	-- strings in this bridge, and remain relative to the target if it moves.
	local prepared = {}
	for _, candidate in ipairs(powers) do
		local power_path = gd.call(target, "get_path_to", candidate.power)
		local original_pc_path = gd.call(target, "get_path_to", candidate.original_pc)
		if type(power_path) ~= "string" or power_path == ""
			or type(original_pc_path) ~= "string" or original_pc_path == "" then
			return nil, "could not resolve relative Power/controller paths"
		end
		prepared[#prepared + 1] = {
			power = candidate.power, original_pc = candidate.original_pc,
			power_path = power_path, original_pc_path = original_pc_path,
		}
	end
	local link = {
		target_id = gd.id(target), source_id = gd.id(source), source_area_id = gd.id(source_area),
		target_label = label(target), source_label = label(source), source_pc_id = gd.id(source_pc),
		primary_power_id = gd.id(primary.power), powers = {}, estimated_watts = watts,
	}
	local transferred = {}
	for _, candidate in ipairs(prepared) do
		local power, original_pc = candidate.power, candidate.original_pc
		local item = { power_id = gd.id(power), original_pc_id = gd.id(original_pc),
			power_path = candidate.power_path, original_pc_path = candidate.original_pc_path,
			original_powered = gd.get(power, "is_powered") == true,
			primary = gd.id(power) == link.primary_power_id }
		local ok, reason = transfer_one(power, source_pc, original_pc)
		if not ok then
			for i = #transferred, 1, -1 do restore_power(transferred[i], true) end
			return nil, "load " .. tostring(gd.id(power)) .. " transfer failed: " .. tostring(reason)
		end
		transferred[#transferred + 1] = {
			power = power, source_pc = source_pc, original_pc = original_pc,
			original_powered = item.original_powered,
		}
		link.powers[#link.powers + 1] = item
		if DEBUG_LOGGING then
			log("load transfer target=%s source=%s %s source_memberships=%d", link.target_label,
				link.source_label, snapshot(power, source_pc), local_count(source_pc, power))
		end
	end
	local resolved_source, resolved_powers = resolve_link(link,
		{ [link.target_id] = target, [link.source_id] = source })
	if not resolved_source or #resolved_powers ~= #link.powers then
		for i = #transferred, 1, -1 do restore_power(transferred[i], true) end
		return nil, "relative Power/controller paths failed to resolve"
	end
	links[link.target_id] = link
	if not tracked_link_ids[link.target_id] then
		link_ids[#link_ids + 1] = link.target_id
		tracked_link_ids[link.target_id] = true
	end
	log("rack power ON target=%s source=%s rack_mount=%s estimated_w=%d loads=%d",
		link.target_label, link.source_label, tostring(link.source_area_id), watts, #link.powers)
	return link
end

local function audit_link_load(link, by_id)
	if not DEBUG_LOGGING then return end
	local source_pc, powers = resolve_link(link, by_id)
	if not source_pc or #powers ~= #link.powers then return end
	local source_state = string.format("source_pc=%s current_load=%s displayed_load=%s charge=%s/%s rate=%s",
		tostring(gd.id(source_pc)), tostring(gd.get(source_pc, "current_load")),
		tostring(gd.get(source_pc, "displayed_load")), tostring(gd.get(source_pc, "charges")),
		tostring(gd.get(source_pc, "charge_capacity")), tostring(gd.get(source_pc, "charge_rate")))
	local transferred = {}
	for _, item in ipairs(powers) do
		local power = item.power
		transferred[#transferred + 1] = string.format("%s:load=%s:powered=%s:controller=%s",
			tostring(gd.id(power)), tostring(gd.get(power, "current_load")),
			tostring(gd.get(power, "is_powered")), tostring(gd.id(gd.get(power, "controller"))))
	end
	table.sort(transferred)
	local original_controllers, controller_seen = {}, {}
	for _, item in ipairs(powers) do
		local original_pc = item.original_pc
		local original_id = gd.id(original_pc)
		if original_id and not controller_seen[original_id] then
			controller_seen[original_id] = true
			original_controllers[#original_controllers + 1] = string.format(
				"%s:current_load=%s:displayed_load=%s", tostring(original_id),
				tostring(gd.get(original_pc, "current_load")), tostring(gd.get(original_pc, "displayed_load")))
		end
	end
	table.sort(original_controllers)
	local original_state = "original_controllers=[" .. table.concat(original_controllers, ",") .. "]"
	local signature = table.concat({ source_state, table.concat(transferred, ","), original_state }, " | ")
	if signature ~= link.last_load_audit then
		link.last_load_audit = signature
		log("load audit target=%s %s transferred=[%s] %s",
			link.target_label, source_state, table.concat(transferred, ","), original_state)
	end
end

local function reject_once(key, message)
	if not DEBUG_LOGGING then return end
	if last_rejection[key] ~= message then
		last_rejection[key] = message
		log("preflight rejected key=%s reason=%s", key, message)
	end
end

local function source_is_active(source)
	local device, pc = source.device, gd.get(source.device, "power_controller")
	return gd.get(device, "is_mount_locked") == true
		and pc ~= nil
		and gd.get(pc, "can_supply_power") == true
		and gd.get(pc, "is_enabled_and_functional") == true
		and gd.get(pc, "disabled") == false
		and (tonumber(gd.get(pc, "charges")) or 0) > 0
end

local function select_source(matching, area_id)
	local eligible, candidate_ids = {}, DEBUG_LOGGING and {} or nil
	for _, source in ipairs(matching) do
		if DEBUG_LOGGING then
			candidate_ids[#candidate_ids + 1] = tostring(gd.id(source.device) or "?")
		end
		if source_is_active(source) then eligible[#eligible + 1] = source end
	end
	-- Device discovery order is usually stable, but sort explicitly so duplicated
	-- UPS devices do not make targets oscillate between power controllers.
	table.sort(eligible, function(a, b)
		return (tonumber(gd.id(a.device)) or math.huge) < (tonumber(gd.id(b.device)) or math.huge)
	end)
	local selected = eligible[1]
	if DEBUG_LOGGING then
		local signature = table.concat(candidate_ids, ",") .. "|selected="
			.. tostring(selected and gd.id(selected.device) or "none")
		local key = tostring(area_id or "?")
		if #matching > 1 and last_source_selection[key] ~= signature then
			log("multiple UPS devices in mount=%s candidates=[%s] eligible=%d selected=%s; other UPS units left idle",
				key, table.concat(candidate_ids, ","), #eligible,
				tostring(selected and gd.id(selected.device) or "none"))
		end
		last_source_selection[key] = signature
	end
	return selected
end

local function scan()
	local devices = collect_devices()
	if #devices == 0 then return end
	local alive, by_id, sources, targets, by_target = {}, {}, {}, {}, {}
	for _, device in ipairs(devices) do
		local id = gd.id(device)
		if id then alive[id], by_id[id] = true, device end
		log_mount_state(device, "scan", false)
		local area = gd.get(device, "base_mounted_area")
		if area and gd.name(area) == RACK_MOUNT_NAME then
			local area_id = gd.id(area)
			if is_ups_source(device) then
				sources[#sources + 1] = { device = device, area = area, area_id = area_id }
			elseif gd.get(device, "power_controller") ~= nil
				or gd.get(device, "logic_controller") ~= nil then
				targets[#targets + 1] = { device = device, area = area, area_id = area_id }
			end
		end
	end
	for _, target in ipairs(targets) do
		local area_id, target_id = target.area_id, gd.id(target.device)
		local key = tostring(target_id)
		local matching = {}
		for _, source in ipairs(sources) do
			if source.area_id == area_id then matching[#matching + 1] = source end
		end
		local link = links[target_id]
		local target_locked = gd.get(target.device, "is_mount_locked") == true
		local source_record = select_source(matching, area_id)
		if #matching == 0 then
			if link then link.restore_reason = "no UPS in the same rack"; if restore_link(link, alive, by_id) then links[target_id] = nil end end
			reject_once(key, "no supported UPS in same Mount")
		elseif not target_locked then
			if link then link.restore_reason = "source or target unlocked"; if restore_link(link, alive, by_id) then links[target_id] = nil end end
			reject_once(key, "target must be locked")
		elseif not source_record then
			if link then link.restore_reason = "no eligible locked UPS in the same rack"; if restore_link(link, alive, by_id) then links[target_id] = nil end end
			reject_once(key, "UPS must be locked, enabled, functional, and charged")
		else
			local source = source_record.device
			local source_pc = gd.get(source, "power_controller")
			local target_pc = gd.get(target.device, "power_controller")
			if link and (link.source_id ~= gd.id(source) or link.source_area_id ~= area_id) then
				link.restore_reason = "source or rack changed"
				if restore_link(link, alive, by_id) then links[target_id] = nil; link = nil end
			end
			if not target_pc or gd.get(target_pc, "disabled") ~= false then
				if link then link.restore_reason = "device power switch is disabled"; if restore_link(link, alive, by_id) then links[target_id] = nil end end
				reject_once(key, "device power controller is disabled or unknown")
			elseif not link then
				last_rejection[key] = nil
				local created, reason = transfer_target(source, target.device, target.area)
				if not created then reject_once(key, reason) else by_target[target_id] = true end
			else
				last_rejection[key] = nil
				audit_link_load(link, by_id)
				by_target[target_id] = true
			end
		end
	end
	-- Use the stable ID list here: the sandbox faulted in LuaJIT's table
	-- next iterator just after completed load audits on every linked scan.
	for i = #link_ids, 1, -1 do
		local id = link_ids[i]
		local link = links[id]
		if link and not alive[id] then
			log("dropping stale link record target=%s source=%s (device removed)", link.target_label, link.source_label)
			links[id] = nil
		elseif link and not by_target[id] then
			link.restore_reason = "target no longer qualifies in a shared locked rack Mount"
			if restore_link(link, alive, by_id) then links[id] = nil end
		end
		if not links[id] then
			tracked_link_ids[id] = nil
			table.remove(link_ids, i)
		end
	end
end

local function current_world_id()
	local ok, world = pcall(function() return ModApiV1.get_game_world() end)
	if not ok or not world then return nil end
	-- get_game_world may still hand back the outgoing wrapper during a scene
	-- transition. Do not treat it as usable until the node remains in the tree.
	if gd.call(world, "is_inside_tree") ~= true then return nil end
	return gd.id(world)
end

local function discard_stale_world_state(reason)
	-- A world transition frees these wrappers. Drop references without calling
	-- controller methods, then wait for on_game_state_ready to establish the
	-- replacement world.
	links, link_ids, tracked_link_ids = {}, {}, {}
	last_rejection, last_mount_state = {}, {}
	hover_patch = nil
	active_world_id = nil
	ready = false
	log("suspending scans during world transition: %s", reason)
end

local function world_is_current()
	local world_id = current_world_id()
	if not world_id then
		if active_world_id ~= nil or ready then discard_stale_world_state("game world unavailable") end
		return false
	end
	if active_world_id and world_id ~= active_world_id then
		discard_stale_world_state("world instance changed")
		return false
	end
	if not active_world_id then active_world_id = world_id end
	return ready
end

function on_mod_load()
	collectgarbage("stop")
	log("loaded: supported locked UPS can power eligible devices in the same rack Mount; respects device power switch, updates hover label, restores original controllers")
end

function on_game_state_ready()
	collectgarbage("stop")
	-- The old world's controllers have already been freed; discard wrappers.
	links, link_ids, tracked_link_ids = {}, {}, {}
	last_rejection, last_mount_state = {}, {}
	last_source_selection = {}
	array_probe_sequence, array_probe_logged, array_probe_budget_reported = 0, 0, false
	active_world_id = current_world_id()
	hover_patch = nil
	ready = true
	scan_after = tick + START_DELAY
	log("world ready id=%s; rack power scan starts after %d ticks",
		tostring(active_world_id), START_DELAY)
end

function on_player_input(event)
	if not DEBUG_LOGGING then return nil end
	if gd.get(event, "pressed") ~= true or gd.get(event, "echo") == true then return nil end
	local keycode = tonumber(gd.get(event, "keycode")) or 0
	local physical_keycode = tonumber(gd.get(event, "physical_keycode")) or 0
	if keycode == DEBUG_F_KEYCODE or physical_keycode == DEBUG_F_KEYCODE then
		if not world_is_current() then return nil end
		for _, device in ipairs(collect_devices()) do log_mount_state(device, "F_key", true) end
	end
	return nil
end

function on_save_export(_data)
	if #link_ids == 0 then return end
	if not world_is_current() then return end
	local alive, by_id = {}, {}
	for _, device in ipairs(collect_devices()) do
		local id = gd.id(device)
		if id then alive[id], by_id[id] = true, device end
	end
	local remaining, remaining_set = {}, {}
	for i = #link_ids, 1, -1 do
		local id = link_ids[i]
		local link = links[id]
		if link then
			link.restore_reason = "save requested; keeping virtual rack power out of saved state"
			if restore_link(link, alive, by_id) then
				links[id] = nil
			else
				warn("save export could not restore link target=%s; retaining link for retry", link.target_label)
				remaining[#remaining + 1], remaining_set[id] = id, true
			end
		end
	end
	link_ids, tracked_link_ids = remaining, remaining_set
end

-- A GDObject finalizer can fault if its Godot node was freed. Keep automatic
-- collection out of scans and drain wrappers only after tick work is finished.
local function drain_heap()
	collectgarbage("collect")
	collectgarbage("stop")
end

function on_game_tick()
	collectgarbage("stop")
	tick = tick + 1
	if ready and tick >= scan_after and tick % SCAN_PERIOD == 0 then
		if world_is_current() then
			local ok, err = pcall(scan)
			if not ok then warn("scan failed safely: %s", tostring(err)) end
		end
	end
	-- Poll instead of entering Lua from RichTextLabel.finished. This interval keeps
	-- the corrected label responsive without a re-entrant signal callback.
	if ready and tick >= scan_after and tick % HOVER_POLL_PERIOD == 0 and world_is_current() then
		pcall(update_hover_power_text)
	end
	return drain_heap()
end
