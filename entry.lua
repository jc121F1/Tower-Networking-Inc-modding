-- Reversible rack power proof of concept.
-- Rack UPS Test (R500) can power eligible devices in the same locked Mount.
local gd = require("lib.gd")

local SCAN_PERIOD = 30
local START_DELAY = 120
local MIN_CHARGE_MULTIPLIER = 10
local tick, ready, scan_after = 0, false, math.huge
local links = {} -- target device id -> reversible transfer record
local last_rejection = {}
local last_mount_state = {}
local last_overlap_state = {}
local hover_patch = nil
local hover_signal_label_id = nil
local hover_signal_failed = false
local hover_signal_busy = false

local function log(fmt, ...)
	print("[rack-ups-test] " .. string.format(fmt, ...))
end

local function has(text, fragment)
	return string.find(string.lower(tostring(text or "")), string.lower(fragment), 1, true) ~= nil
end

local function label(device)
	return string.format("%s#%s(%s)", gd.name(device), tostring(gd.id(device) or "?"),
		tostring(gd.get(device, "product_name") or "?"))
end

local function log_mount_state(device, reason, force)
	local product = tostring(gd.get(device, "product_name") or "")
	if not (has(product, "rack ups test") or gd.get(device, "logic_controller") ~= nil) then return end
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

-- Compare the rack's Area2D body list with the custom UPS's own mount state.
-- This distinguishes "body is overlapping but the mount link is missing" from
-- "the rack does not see the body" without walking the scene tree.
local function log_mount_overlap(area, target, source)
	if not area or not target or not source then return end
	local bodies = gd.call(area, "get_overlapping_bodies")
	if bodies == nil then
		local key = tostring(gd.id(area) or "?")
		if last_overlap_state[key] ~= "unavailable" then
			last_overlap_state[key] = "unavailable"
			log("mount overlap audit mount=%s#%s query=unavailable", gd.name(area), key)
		end
		return
	end
	local ids, source_seen = {}, false
	gd.each(bodies, function(_, body)
		local id = gd.id(body)
		if id then
			ids[#ids + 1] = gd.name(body) .. "#" .. id
			if id == gd.id(source) then source_seen = true end
		end
	end)
	table.sort(ids)
	local state = table.concat({ table.concat(ids, ","), tostring(source_seen),
		tostring(gd.get(source, "base_mounted_area") == area),
		tostring(gd.get(source, "collision_layer")), tostring(gd.get(source, "collision_mask")),
		tostring(gd.get(source, "freeze")), tostring(gd.get(source, "is_mount_locked")) }, "|")
	local key = tostring(gd.id(area) or "?")
	if last_overlap_state[key] ~= state then
		last_overlap_state[key] = state
		log("mount overlap audit mount=%s#%s target=%s source=%s source_in_overlaps=%s source_area_matches=%s collision_layer=%s collision_mask=%s freeze=%s locked=%s bodies=[%s]",
			gd.name(area), key, label(target), label(source), tostring(source_seen),
			tostring(gd.get(source, "base_mounted_area") == area),
			tostring(gd.get(source, "collision_layer")), tostring(gd.get(source, "collision_mask")),
			tostring(gd.get(source, "freeze")), tostring(gd.get(source, "is_mount_locked")),
			table.concat(ids, ","))
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
	gd.each(gd.get(pc, "locals"), function(_, item)
		if gd.id(item) == want then count = count + 1 end
	end)
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
	while count > 1 and attempts < 8 do
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
	while count > 0 and attempts < 8 do
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
		if not ok then log("restore membership warning power=%s count=%d error=%s", tostring(gd.id(power)), count, tostring(err)) end
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

local function restore_link(link, alive)
	local target_alive = link.target_id and alive[link.target_id]
	local source_alive = link.source_id and alive[link.source_id]
	if target_alive then
		for i = #link.powers, 1, -1 do restore_power(link.powers[i], source_alive) end
	end
	log("restored link target=%s source=%s target_alive=%s source_alive=%s reason=%s",
		link.target_label, link.source_label, tostring(target_alive == true),
		tostring(source_alive == true), tostring(link.restore_reason or "rack condition ended"))
end

local function link_has_power(link)
	if not link or not link.target or not link.source_pc then return false end
	local target_pc = gd.get(link.target, "power_controller")
	if not target_pc or gd.get(target_pc, "disabled") ~= false then return false end
	for _, item in ipairs(link.powers) do
		if item.primary and gd.get(item.power, "is_powered") == true
			and gd.id(gd.get(item.power, "controller")) == gd.id(link.source_pc) then
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
	for _ = 1, 7 do
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
	local powered = link_has_power(link)
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
	if string.find(text, "Unpowered", 1, true) then
		if gd.get(hover_label, "bbcode_enabled") ~= true then return end
		local patched, count = string.gsub(text,
			"%[color=[^%]]+%]Unpowered%[/color%]", "[color=green]Powered[/color]", 1)
		if count == 0 then
			patched = string.gsub(text, "Unpowered", "[color=green]Powered[/color]", 1)
		end
		gd.set(hover_label, "text", patched)
		hover_patch = { device_id = device_id, original = text, patched = patched }
		if not link.hover_logged then
			log("corrected hover power label for %s", link.target_label)
			link.hover_logged = true
		end
	end
end

local function on_hover_label_finished()
	if hover_signal_busy or not ready or not (next(links) or hover_patch) then return end
	hover_signal_busy = true
	-- Setting RichTextLabel.text can emit finished again; guard re-entry.
	local ok, err = pcall(update_hover_power_text)
	hover_signal_busy = false
	if not ok and not hover_signal_failed then
		log("hover signal correction failed: %s", tostring(err))
		hover_signal_failed = true
	end
end

local function connect_hover_label_signal()
	if hover_signal_failed then return end
	local camera = ModApiV1.get_player_camera()
	local mouse = gd.get(camera, "mp_mouse")
	local hover_label = gd.get(mouse, "hovertxt")
	local id = gd.id(hover_label)
	if not id or id == hover_signal_label_id then return end
	local ok, result = pcall(function()
		return hover_label.connect("finished", on_hover_label_finished)
	end)
	if ok and tonumber(result) == 0 then
		hover_signal_label_id = id
		log("hover label finished signal connected")
	else
		hover_signal_failed = true
		log("hover label finished signal unavailable: %s", tostring(result))
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
	log("transfer membership power=%s original_count=%d source_count=%d controller_matches=%s",
		tostring(gd.id(power)), local_count(original_pc, power),
		local_count(source_pc, power), tostring(controller_matches))
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
	log("post-controller membership power=%s source_count=%d controller=%s normalized=%s error=%s",
		tostring(gd.id(power)), membership_count,
		tostring(gd.id(gd.get(power, "controller"))), tostring(membership_ok), tostring(membership_err))
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
	local ok, all = pcall(function() return ModApiV1.get_devices() end)
	if not ok or not all then return devices end
	gd.each(all, function(_, d) devices[#devices + 1] = d end)
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
	gd.each(gd.find_named(device, "Power"), function(_, node) add(node) end)
	gd.each(gd.find_named(device, "*Light*"), function(_, node) add(gd.get(node, "power")) end)
	gd.each(gd.find_named(device, "*Switch*"), function(_, node) add(gd.get(node, "power")) end)
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
	if charges < watts * MIN_CHARGE_MULTIPLIER then return nil, "UPS charge below 10x estimated load reserve" end
	local link = {
		target_id = gd.id(target), source_id = gd.id(source), source_area_id = gd.id(source_area),
		target = target, source = source, target_label = label(target), source_label = label(source),
		source_pc = source_pc, original_pc = primary.original_pc,
		primary_power_id = gd.id(primary.power), powers = {}, estimated_watts = watts,
	}
	for _, candidate in ipairs(powers) do
		local power, original_pc = candidate.power, candidate.original_pc
		local item = { power = power, source_pc = source_pc, original_pc = original_pc,
			original_powered = gd.get(power, "is_powered") == true,
			primary = gd.id(power) == link.primary_power_id }
		local ok, reason = transfer_one(power, source_pc, original_pc)
		if not ok then
			for i = #link.powers, 1, -1 do restore_power(link.powers[i], true) end
			return nil, "load " .. tostring(gd.id(power)) .. " transfer failed: " .. tostring(reason)
		end
		link.powers[#link.powers + 1] = item
		log("load transfer target=%s source=%s %s source_memberships=%d", link.target_label,
			link.source_label, snapshot(power, source_pc), local_count(source_pc, power))
	end
	links[link.target_id] = link
	log("rack power ON target=%s source=%s rack_mount=%s estimated_w=%d loads=%d",
		link.target_label, link.source_label, tostring(link.source_area_id), watts, #link.powers)
	return link
end

local function audit_link_load(link)
	local source_pc = link.source_pc
	local source_state = string.format("source_pc=%s current_load=%s displayed_load=%s charge=%s/%s rate=%s",
		tostring(gd.id(source_pc)), tostring(gd.get(source_pc, "current_load")),
		tostring(gd.get(source_pc, "displayed_load")), tostring(gd.get(source_pc, "charges")),
		tostring(gd.get(source_pc, "charge_capacity")), tostring(gd.get(source_pc, "charge_rate")))
	local locals = {}
	gd.each(gd.get(source_pc, "locals"), function(_, power)
		locals[#locals + 1] = string.format("%s:load=%s:powered=%s:controller=%s",
			tostring(gd.id(power)), tostring(gd.get(power, "current_load")),
			tostring(gd.get(power, "is_powered")), tostring(gd.id(gd.get(power, "controller"))))
	end)
	table.sort(locals)
	local transferred = {}
	for _, item in ipairs(link.powers) do
		local power = item.power
		transferred[#transferred + 1] = string.format("%s:load=%s:powered=%s:controller=%s",
			tostring(gd.id(power)), tostring(gd.get(power, "current_load")),
			tostring(gd.get(power, "is_powered")), tostring(gd.id(gd.get(power, "controller"))))
	end
	table.sort(transferred)
	local original_controllers, controller_seen = {}, {}
	for _, item in ipairs(link.powers) do
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
	local signature = table.concat({ source_state, table.concat(locals, ","),
		 table.concat(transferred, ","), original_state }, " | ")
	if signature ~= link.last_load_audit then
		link.last_load_audit = signature
		log("load audit target=%s %s source_locals=[%s] transferred=[%s] %s",
			link.target_label, source_state, table.concat(locals, ","),
			table.concat(transferred, ","), original_state)
	end
end

local function reject_once(key, message)
	if last_rejection[key] ~= message then
		last_rejection[key] = message
		log("preflight rejected key=%s reason=%s", key, message)
	end
end

local function scan()
	local devices = collect_devices()
	if #devices == 0 then return end
	local alive, sources, ups_devices, targets, by_target = {}, {}, {}, {}, {}
	for _, device in ipairs(devices) do
		local id = gd.id(device)
		if id then alive[id] = true end
		local product = tostring(gd.get(device, "product_name") or "")
		log_mount_state(device, "scan", false)
		if has(product, "rack ups test") then ups_devices[#ups_devices + 1] = device end
		local area = gd.get(device, "base_mounted_area")
		if area and gd.name(area) == "Mount" then
			local area_id = gd.id(area)
			if has(product, "rack ups test") then
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
		if #matching > 0 then log_mount_overlap(target.area, target.device, matching[1].device)
		elseif #ups_devices > 0 then log_mount_overlap(target.area, target.device, ups_devices[1]) end
		local link = links[target_id]
		local target_locked = gd.get(target.device, "is_mount_locked") == true
		if #matching ~= 1 then
			if link then link.restore_reason = "no unique UPS in the same rack"; restore_link(link, alive); links[target_id] = nil end
			reject_once(key, #matching == 0 and "no Rack UPS Test in same Mount" or "multiple UPS units in same Mount")
		elseif not target_locked or gd.get(matching[1].device, "is_mount_locked") ~= true then
			if link then link.restore_reason = "source or target unlocked"; restore_link(link, alive); links[target_id] = nil end
			reject_once(key, "source and target must both be locked")
		else
			local source = matching[1].device
			local source_pc = gd.get(source, "power_controller")
			local target_pc = gd.get(target.device, "power_controller")
			local source_active = source_pc ~= nil and gd.get(source_pc, "can_supply_power") == true
			if source_active then
				source_active = gd.get(source_pc, "is_enabled_and_functional") == true
					and gd.get(source_pc, "disabled") == false
					and (tonumber(gd.get(source_pc, "charges")) or 0) > 0
			end
			if link and (link.source_id ~= gd.id(source) or link.source_area_id ~= area_id) then
				link.restore_reason = "source or rack changed"; restore_link(link, alive); links[target_id] = nil; link = nil
			end
			if not target_pc or gd.get(target_pc, "disabled") ~= false then
				if link then link.restore_reason = "device power switch is disabled"; restore_link(link, alive); links[target_id] = nil end
				reject_once(key, "device power controller is disabled or unknown")
			elseif not source_active then
				if link then link.restore_reason = "UPS no longer supplying power"; restore_link(link, alive); links[target_id] = nil end
				reject_once(key, "UPS must be enabled, charged, and can_supply_power=true")
			elseif not link then
				last_rejection[key] = nil
				local created, reason = transfer_target(source, target.device, target.area)
				if not created then reject_once(key, reason) else by_target[target_id] = true end
			else
				last_rejection[key] = nil
				audit_link_load(link)
				by_target[target_id] = true
			end
		end
	end
	for id, link in pairs(links) do
		if not alive[id] then
			log("dropping stale link wrappers target=%s source=%s (device removed)", link.target_label, link.source_label)
			links[id] = nil
		elseif not by_target[id] then
			link.restore_reason = "target no longer qualifies in a shared locked rack Mount"
			restore_link(link, alive)
			links[id] = nil
		end
	end
end

function on_mod_load()
	-- Older builds of this test mod stopped the collector on every tick. Restart
	-- it once on load so a hot reload cannot inherit the stopped-GC state.
	local gc_ok, gc_err = pcall(collectgarbage, "restart")
	log("Lua garbage collector restart=%s%s", tostring(gc_ok),
		gc_ok and "" or (" error=" .. tostring(gc_err)))
	log("loaded: locked Rack UPS Test (R500) can power eligible devices in the same rack Mount; respects device power switch, updates hover power label, and restores original controllers")
end

function on_game_state_ready()
	-- The old world's controllers have already been freed; discard wrappers.
	links, last_rejection, last_mount_state, last_overlap_state = {}, {}, {}, {}
	hover_patch, hover_signal_label_id, hover_signal_failed, hover_signal_busy = nil, nil, false, false
	ready = true
	scan_after = tick + START_DELAY
	pcall(connect_hover_label_signal)
	log("world ready; rack power scan starts after %d ticks", START_DELAY)
end

function on_player_input(event)
	if gd.get(event, "pressed") ~= true or gd.get(event, "echo") == true then return nil end
	local keycode = tonumber(gd.get(event, "keycode")) or 0
	local physical_keycode = tonumber(gd.get(event, "physical_keycode")) or 0
	if keycode == 70 or physical_keycode == 70 then
		for _, device in ipairs(collect_devices()) do log_mount_state(device, "F_key", true) end
	end
	return nil
end

function on_save_export(_data)
	if not next(links) then return end
	local alive = {}
	for _, device in ipairs(collect_devices()) do
		local id = gd.id(device)
		if id then alive[id] = true end
	end
	for id, link in pairs(links) do
		link.restore_reason = "save requested; keeping virtual rack power out of saved state"
		restore_link(link, alive)
		links[id] = nil
	end
end

function on_game_tick()
	tick = tick + 1
	if ready and tick >= scan_after and tick % SCAN_PERIOD == 0 then
		local ok, err = pcall(scan)
		if not ok then log("scan failed safely: %s", tostring(err)) end
		pcall(connect_hover_label_signal)
		if next(links) or hover_patch then pcall(update_hover_power_text) end
	end
	return nil
end
