-- Power over Ethernet. A powered network switch can temporarily adopt an
-- endpoint's Power load through PowerController.add_local/remove_local.
--
-- The game models mains and Ethernet as separate graphs. This mod joins them
-- only while the Ethernet cable remains physically connected.

local gd = require("lib.gd")

local TOTAL_BUDGET_W = 120
local PORT_BUDGET_W = 15
local SCAN_PERIOD = 30
-- Use the game's local-load API. Do not create or move sockets: power sockets
-- participate in physical cable simulation.
local tick = 0
local ready = false
local scan_after = math.huge
local last_scan_summary = nil
local power_links = {} -- endpoint Power instance ID -> controller load transfer
local missing_scans = {} -- consecutive scans with no physical Ethernet cable
local rejected_loads = {} -- last PoE load estimate reported for each over-limit endpoint
local hover_patch = nil -- last visual-only correction to the player's hover label

local function log(fmt, ...)
	print("[poe] " .. string.format(fmt, ...))
end

local function instance_id(node)
	local value = gd.call(node, "get_instance_id")
	return value and tostring(value) or nil
end

local function device_label(device)
	local logic = gd.get(device, "logic_controller")
	local hwid = gd.get(logic, "hardware_address")
	return tostring(gd.get(device, "product_name") or gd.name(device))
		.. " [hw=" .. tostring(hwid or "?") .. ", node=" .. tostring(instance_id(device) or "?") .. "]"
end

local function device_for_socket(sock)
	local node = gd.parent(sock)
	for _ = 1, 6 do
		if not node then return nil end
		if gd.get(node, "logic_controller") ~= nil then return node end
		node = gd.parent(node)
	end
	return nil
end

local function find_named(node, pattern)
	if not node then return nil end
	local ok, found = pcall(function()
		return node.find_children(pattern, "", true, false)
	end)
	return ok and found or nil
end

local function refresh_power_controller(pc)
	if pc then pcall(function() pc.start_charge_timer() end) end
end

local function controller_has_power(pc, power)
	local found = false
	local power_id = instance_id(power)
	gd.each(gd.get(pc, "locals"), function(_, local_power)
		if power_id and instance_id(local_power) == power_id then found = true end
	end)
	return found
end

local function power_state_snapshot(power, source_pc, original_pc)
	local function pc_state(pc)
		if not pc then return "nil" end
		return string.format("pc=%s supply=%s load=%s charge=%s/%s rate=%s enabled=%s functional=%s disabled=%s",
			tostring(instance_id(pc)), tostring(gd.get(pc, "can_supply_power")),
			tostring(gd.get(pc, "current_load")), tostring(gd.get(pc, "charges")),
			tostring(gd.get(pc, "charge_capacity")), tostring(gd.get(pc, "charge_rate")),
			tostring(gd.get(pc, "is_enabled_and_functional")),
			tostring(gd.get(pc, "functional")), tostring(gd.get(pc, "disabled")))
	end
	local power_controller = gd.get(power, "controller")
	return string.format("power=%s powered=%s intent=%s can_manifest=%s load=%s controller=%s in_source_locals=%s source{%s} original{%s}",
		tostring(instance_id(power)), tostring(gd.get(power, "is_powered")),
		tostring(gd.get(power, "manifest_intent")), tostring(gd.get(power, "can_manifest")),
		tostring(gd.get(power, "current_load")), tostring(instance_id(power_controller)),
		tostring(controller_has_power(source_pc, power)), pc_state(source_pc), pc_state(original_pc))
end

local function ensure_power_on(power)
	if gd.get(power, "is_powered") ~= true then
		local ok, err = pcall(function() power.on() end)
		if not ok then return false, "Power.on failed: " .. tostring(err) end
	end
	-- The graph transfer can set is_powered without notifying the device's
	-- normal power listeners. Those listeners drive OS startup and the LEDs.
	local ok, err = pcall(function() power.broadcast_restored() end)
	if not ok then return false, "Power.broadcast_restored failed: " .. tostring(err) end
	return true
end

local function endpoint_load_watts(device, power, original_pc)
	-- current_load is zero while a device is off. Use the configured fallback,
	-- LogicController's declared load, and the endpoint's existing power rate
	-- as conservative estimates so high-load devices are rejected before PoE.
	local estimates = {
		tonumber(gd.get(power, "current_load")),
		tonumber(gd.get(power, "default_fallback_load")),
		tonumber(gd.get(gd.get(device, "logic_controller"), "power_load")),
		tonumber(gd.get(original_pc, "charge_rate")),
	}
	local watts = 0
	for _, estimate in pairs(estimates) do
		if estimate and estimate > watts then watts = estimate end
	end
	if watts <= 0 then return nil end
	return watts
end

local function transfer_power_load(power, source_pc, original_pc)
	if not (power and source_pc and original_pc)
		or instance_id(source_pc) == instance_id(original_pc) then
		return false, "missing or identical controller"
	end
	local original_intent = gd.get(power, "manifest_intent")
	local removed, remove_error = pcall(function() original_pc.remove_local(power) end)
	if not removed then return false, "original remove_local failed: " .. tostring(remove_error) end
	local added, add_error = pcall(function() source_pc.add_local(power) end)
	if not added then
		pcall(function() original_pc.add_local(power) end)
		refresh_power_controller(original_pc)
		return false, "source add_local failed: " .. tostring(add_error)
	end
	refresh_power_controller(original_pc)
	refresh_power_controller(source_pc)
	local observed_controller = gd.get(power, "controller")
	local controller_matches = instance_id(observed_controller) == instance_id(source_pc)
	local local_registered = controller_has_power(source_pc, power)
	if not (controller_matches or local_registered) then
		pcall(function() source_pc.remove_local(power) end)
		pcall(function() original_pc.add_local(power) end)
		refresh_power_controller(source_pc)
		refresh_power_controller(original_pc)
		return false, "add_local did not register Power in controller"
	end
	-- add_local registers membership but, as observed in 0.12.7, leaves the
	-- Power object's back-reference on its old unpowered controller. Keep both
	-- sides of the relationship consistent before requesting power.
	if not controller_matches then gd.set(power, "controller", source_pc) end
	if instance_id(gd.get(power, "controller")) ~= instance_id(source_pc) then
		pcall(function() source_pc.remove_local(power) end)
		pcall(function() original_pc.add_local(power) end)
		gd.set(power, "controller", original_pc)
		refresh_power_controller(source_pc)
		refresh_power_controller(original_pc)
		return false, "could not update Power.controller back-reference"
	end
	refresh_power_controller(original_pc)
	refresh_power_controller(source_pc)
	local powered, power_error = ensure_power_on(power)
	if not powered then
		pcall(function() source_pc.remove_local(power) end)
		pcall(function() original_pc.add_local(power) end)
		gd.set(power, "controller", original_pc)
		refresh_power_controller(source_pc)
		refresh_power_controller(original_pc)
		pcall(function() power.broadcast_lost() end)
		if original_intent ~= nil then gd.set(power, "manifest_intent", original_intent) end
		return false, power_error
	end
	return true, "registered in locals and controller assigned"
end

local function restore_one_power(power, source_pc, original_pc, original_powered)
	if source_pc and power then pcall(function() source_pc.remove_local(power) end) end
	if original_pc and power then
		pcall(function() original_pc.add_local(power) end)
		gd.set(power, "controller", original_pc)
	end
	refresh_power_controller(source_pc)
	refresh_power_controller(original_pc)
	if original_powered and power then
		ensure_power_on(power)
	elseif power then
		-- Losing supply must not simulate the user turning the device off.
		local intent = gd.get(power, "manifest_intent")
		local ok, err = pcall(function() power.broadcast_lost() end)
		if not ok then log("power loss callback failed: %s", tostring(err)) end
		if intent ~= nil and gd.get(power, "manifest_intent") ~= intent then
			gd.set(power, "manifest_intent", intent)
		end
	end
end

local function restore_power_load(link)
	if not link then return end
	for _, extra in ipairs(link.auxiliary_powers or {}) do
		restore_one_power(extra.power, link.source_pc, extra.original_pc, extra.original_powered)
	end
	restore_one_power(link.power, link.source_pc, link.original_pc, link.original_powered)
	local logic = link.endpoint and gd.get(link.endpoint, "logic_controller")
	log("after PoE removal: %s os_running=%s; %s",
		link.endpoint and device_label(link.endpoint) or "unknown",
		tostring(gd.get(logic, "os_running")),
		power_state_snapshot(link.power, link.source_pc, link.original_pc))
end

local function transfer_auxiliary_powers(link)
	local seen = {}
	local main_id = instance_id(link.power)
	local source_id = instance_id(link.source_pc)
	local function consider(power)
		local id = instance_id(power)
		if not id or id == main_id or seen[id] then return end
		seen[id] = true
		local original_pc = gd.get(power, "controller")
		if not original_pc or instance_id(original_pc) == source_id
			or gd.get(power, "is_powered") == nil then return end
		local was_powered = gd.get(power, "is_powered") == true
		local ok, reason = transfer_power_load(power, link.source_pc, original_pc)
		if ok then
			link.auxiliary_powers[#link.auxiliary_powers + 1] = {
				power = power, original_pc = original_pc, original_powered = was_powered,
			}
			log("PoE auxiliary Power transferred for %s: power=%s originally_powered=%s",
				device_label(link.endpoint), id, tostring(was_powered))
		else
			log("PoE auxiliary Power transfer failed for %s: power=%s reason=%s",
				device_label(link.endpoint), id, tostring(reason))
		end
	end
	-- Most device components instantiate a child named Power. Also check the
	-- light and switch components' exported Power reference for other names.
	gd.each(find_named(link.endpoint, "Power"), function(_, node) consider(node) end)
	gd.each(find_named(link.endpoint, "*Light*"), function(_, node)
		consider(gd.get(node, "power"))
	end)
	gd.each(find_named(link.endpoint, "*Switch*"), function(_, node)
		consider(gd.get(node, "power"))
	end)
	log("PoE auxiliary Power loads for %s: %d transferred",
		device_label(link.endpoint), #link.auxiliary_powers)
end

local function power_node(device)
	-- Power is exposed by LogicController.power in the game's typed API. A
	-- name search can accidentally select PowerController or a power switch.
	local logic = gd.get(device, "logic_controller")
	return gd.get(logic, "power")
end

local function powered_now(power)
	return gd.get(power, "is_powered") == true
end

local function collect_devices()
	local result = {}
	local ok, all_devices = pcall(function() return ModApiV1.get_devices() end)
	if not ok or not all_devices then return result end
	gd.each(all_devices, function(_, device)
		result[#result + 1] = device
	end)
	return result
end

-- Logical opposite_socket links can disappear as soon as an endpoint loses
-- power. Pair the two physically seated cable ends so PoE can detect a cable
-- that is still plugged in while its Ethernet link is down.
local function physical_ethernet_peers(devices)
	local by_cable, peers, ports_by_device = {}, {}, {}
	for _, device in ipairs(devices) do
		local ports = find_named(device, "*Ethernet*")
		ports_by_device[device] = ports
		gd.each(ports, function(_, sock)
			local plug = gd.get(sock, "connection")
			local cable = plug and gd.parent(plug)
			local cable_id = cable and instance_id(cable)
			if cable_id then
				local sockets = by_cable[cable_id]
				if not sockets then sockets = {}; by_cable[cable_id] = sockets end
				sockets[#sockets + 1] = sock
			end
		end)
	end
	local cable_count = 0
	for _, sockets in pairs(by_cable) do
		if #sockets == 2 then
			local a, b = instance_id(sockets[1]), instance_id(sockets[2])
			if a and b then
				peers[a], peers[b] = sockets[2], sockets[1]
				cable_count = cable_count + 1
			end
		end
	end
	return peers, cable_count, ports_by_device
end

local function scan()
	local devices = collect_devices()
	if #devices == 0 then
		-- World teardown can leave the mod callback alive briefly after devices
		-- have been freed. Do not retain or touch Godot objects during that gap.
		ready = false
		return
	end
	local physical_peers, physical_cables, ports_by_device = physical_ethernet_peers(devices)
	local candidates, candidate_seen = {}, {}
	local active, budgets = {}, {}
	local ethernet_ports, up_links, powered_switches, poe_supply_switches = 0, 0, 0, 0
	local over_port_limit, over_switch_budget, edge_failures = 0, 0, 0
	local unpowered_endpoints = 0

	for _, device in ipairs(devices) do
		local device_power = power_node(device)
		if (tonumber(gd.get(device, "device_hardware_class")) or 0) == 1
			and device_power and powered_now(device_power) then
			powered_switches = powered_switches + 1
			if gd.get(gd.get(device, "power_controller"), "can_supply_power") == true then
				poe_supply_switches = poe_supply_switches + 1
			end
		end
		if device_power then
			gd.each(ports_by_device[device], function(_, sock)
				ethernet_ports = ethernet_ports + 1
				local logical_peer = gd.get(sock, "opposite_socket")
				local physical_peer = physical_peers[instance_id(sock) or ""]
				local peer = logical_peer or physical_peer
				if logical_peer and gd.get(sock, "is_up") == true then up_links = up_links + 1 end
				if peer then
					local other = device_for_socket(peer)
					if other and other ~= device then
						local source, target = device, other
						if (tonumber(gd.get(source, "device_hardware_class")) or 0) ~= 1 then
							source, target = other, device
						end
						if (tonumber(gd.get(source, "device_hardware_class")) or 0) == 1 then
							local source_power = power_node(source)
							-- The switch's own PowerController is its PoE output. Its
							-- Power.controller is the upstream mains/UPS circuit and must
							-- never receive endpoint loads.
							local source_pc = gd.get(source, "power_controller")
							local source_upstream_pc = gd.get(source_power, "controller")
							local target_power = power_node(target)
							local target_pc = target_power and gd.get(target_power, "controller")
								or gd.get(target, "power_controller")
							local target_id = target_power and instance_id(target_power)
							local existing_link = target_id and power_links[target_id]
							local same_existing_source = existing_link
								and existing_link.source_name == gd.name(source)
							local original_pc = same_existing_source and existing_link.original_pc or target_pc
							local watts = endpoint_load_watts(target, target_power, original_pc)
							if existing_link and existing_link.auxiliary_powers then
								local live_watts = tonumber(gd.get(target_power, "current_load")) or 0
								for _, extra in ipairs(existing_link.auxiliary_powers) do
									live_watts = live_watts + (tonumber(gd.get(extra.power, "current_load")) or 0)
								end
								if live_watts > (watts or 0) then watts = live_watts end
							end
							if source_power and source_pc and target_power and target_pc
								and target_id
								and (source_pc ~= original_pc or same_existing_source)
								and gd.get(source_pc, "can_supply_power") == true
								and powered_now(source_power) then
								local candidate_key = target_id .. "|" .. gd.name(source)
								if not candidate_seen[candidate_key] then
									candidate_seen[candidate_key] = true
									candidates[#candidates + 1] = {
										target = target_power, target_device = target,
										original_pc = original_pc, target_id = target_id,
											source = source, source_pc = source_pc,
											source_upstream_pc = source_upstream_pc,
										watts = watts, original_powered = powered_now(target_power),
									}
								end
							end
						end
					end
				end
			end)
		end
	end

	table.sort(candidates, function(a, b)
		if a.target_id == b.target_id then return gd.name(a.source) < gd.name(b.source) end
		return a.target_id < b.target_id
	end)

	local detected_candidates = #candidates
	for _, item in ipairs(candidates) do
		if not active[item.target_id] then
			local key = instance_id(item.source_pc)
			local budget = key and (budgets[key] or 0) or TOTAL_BUDGET_W
			local watts = item.watts
			if not watts or watts > PORT_BUDGET_W then
				over_port_limit = over_port_limit + 1
				local reported = watts or -1
				if rejected_loads[item.target_id] ~= reported then
					log("excluded PoE endpoint %s: estimated load=%sW, per-endpoint cap=%dW",
						device_label(item.target_device), watts and tostring(watts) or "unknown", PORT_BUDGET_W)
					rejected_loads[item.target_id] = reported
				end
			elseif budget + watts > TOTAL_BUDGET_W then
				over_switch_budget = over_switch_budget + 1
			else
				rejected_loads[item.target_id] = nil
				local link = power_links[item.target_id]
				if link and link.source_name ~= gd.name(item.source) then
					restore_power_load(link)
					power_links[item.target_id] = nil
					link = nil
				end
				if not link then
					local transferred, transfer_method = transfer_power_load(
						item.target, item.source_pc, item.original_pc)
					if transferred then
						link = {
							source_name = gd.name(item.source), source_pc = item.source_pc,
							original_pc = item.original_pc, power = item.target,
							endpoint = item.target_device,
							original_powered = item.original_powered,
							auxiliary_powers = {},
						}
						transfer_auxiliary_powers(link)
						power_links[item.target_id] = link
						log("transferred endpoint estimated at %dW: %s -> %s via %s; output_pc=%s can_supply=%s upstream_pc=%s; %s",
							watts, gd.name(item.source), device_label(item.target_device),
							transfer_method, tostring(instance_id(item.source_pc)),
							tostring(gd.get(item.source_pc, "can_supply_power")),
							tostring(instance_id(item.source_upstream_pc)),
							power_state_snapshot(item.target, item.source_pc, item.original_pc))
					else
						edge_failures = edge_failures + 1
						log("could not transfer load %s -> %s: %s (source can_supply_power=%s, controller=%s, locals_contains_power=%s)",
							gd.name(item.source), device_label(item.target_device),
							tostring(transfer_method),
							tostring(gd.get(item.source_pc, "can_supply_power")),
							tostring(instance_id(gd.get(item.target, "controller"))),
							tostring(controller_has_power(item.source_pc, item.target)))
					end
				end
				if link then
					missing_scans[item.target_id] = nil
					if powered_now(item.target) then
						link.last_powered = true
						if not link.powered_logged then
							local logic = gd.get(item.target_device, "logic_controller")
							log("PoE endpoint reports electrical power: %s (os_running=%s)",
								device_label(item.target_device), tostring(gd.get(logic, "os_running")))
							link.powered_logged = true
						end
					else
						if link.last_powered ~= false then
							log("PoE endpoint lost electrical power while Ethernet remains connected: %s; %s",
								device_label(item.target_device),
								power_state_snapshot(item.target, link.source_pc, link.original_pc))
						end
						link.last_powered = false
						unpowered_endpoints = unpowered_endpoints + 1
					end
					if key then budgets[key] = budget + watts end
					active[item.target_id] = true
				end
			end
		end
	end

	for id, link in pairs(power_links) do
		if active[id] then
			missing_scans[id] = nil
		else
			missing_scans[id] = (missing_scans[id] or 0) + 1
			if missing_scans[id] >= 1 then
				restore_power_load(link)
				power_links[id] = nil
				missing_scans[id] = nil
				log("restored endpoint's original power controller: %s",
					link.endpoint and device_label(link.endpoint) or id)
			end
		end
	end

	local active_count = 0
	for _ in pairs(active) do active_count = active_count + 1 end
	local summary_key = string.format("%d/%d/%d/%d/%d/%d/%d/%d/%d/%d/%d",
		#devices, ethernet_ports, physical_cables, powered_switches, poe_supply_switches,
		detected_candidates, active_count, unpowered_endpoints, over_port_limit,
		over_switch_budget, edge_failures)
	if summary_key ~= last_scan_summary then
		local summary = string.format("scan: devices=%d ethernet_ports=%d physical_cables=%d up_links=%d powered_switches=%d poe_supply_switches=%d candidates=%d power_transfers=%d unpowered_endpoints=%d over_port_limit=%d over_switch_budget=%d transfer_failures=%d",
		#devices, ethernet_ports, physical_cables, up_links, powered_switches, poe_supply_switches, detected_candidates,
		active_count, unpowered_endpoints, over_port_limit, over_switch_budget, edge_failures)
		log("%s", summary)
		last_scan_summary = summary_key
	end
end

function on_mod_load()
	log("loaded (120W per switch, 15W per endpoint; power loads use controller local APIs)")
end


-- The sandbox's Godot wrappers allocate on every scan. Its GDObject finalizer
-- can fault if the game freed an object first, so run collection only as the
-- last operation of a tick. This mirrors the established wireless-access mod.
local function drain_heap()
	collectgarbage("collect")
	collectgarbage("stop")
end

local function update_hover_power_text()
	local camera = ModApiV1.get_player_camera()
	local mouse = gd.get(camera, "mp_mouse")
	local label = gd.get(mouse, "hovertxt")
	local hovered = gd.get(mouse, "curr_hover")
	if not label or not hovered then
		hover_patch = nil
		return
	end
	local device = hovered
	for _ = 1, 7 do
		if not device or gd.get(device, "logic_controller") ~= nil then break end
		device = gd.parent(device)
	end
	if not device or gd.get(device, "logic_controller") == nil then
		hover_patch = nil
		return
	end
	local power = power_node(device)
	local device_id = instance_id(device)
	local text = gd.get(label, "text")
	if type(text) ~= "string" then return end
	local link = power and power_links[instance_id(power)]
	local poe_powered = link and instance_id(link.endpoint) == device_id and powered_now(power)
	if hover_patch and hover_patch.device_id == device_id
		and text == hover_patch.patched and not poe_powered
		and not powered_now(power) then
		gd.set(label, "text", hover_patch.original)
		hover_patch = nil
		return
	end
	if not poe_powered then
		hover_patch = nil
		return
	end
	if string.find(text, "Unpowered", 1, true) then
		if gd.get(label, "bbcode_enabled") ~= true then return end
		local patched, colored = string.gsub(text,
			"%[color=[^%]]+%]Unpowered%[/color%]", "[color=green]Powered[/color]", 1)
		if colored == 0 then
			patched = string.gsub(text, "Unpowered", "[color=green]Powered[/color]", 1)
		end
		gd.set(label, "text", patched)
		hover_patch = {device_id = device_id, original = text, patched = patched}
		if not link.hover_logged then
			log("corrected hover power label for %s", device_label(device))
			link.hover_logged = true
		end
	end
end

function on_game_tick()
	collectgarbage("stop")
	tick = tick + 1
	-- DeviceSpawner and controller graphs are incomplete during initial load.
	-- Walking them before the ready callback can surface nil Objects through the
	-- sandbox bridge, which is a fatal std::bad_cast rather than a Lua exception.
	if ready and tick >= scan_after and tick % SCAN_PERIOD == 0 then
		pcall(scan)
		if next(power_links) or hover_patch then
			pcall(update_hover_power_text)
		end
	end
	return drain_heap()
end

function on_game_state_ready()
	-- The previous world's nodes have already been freed by this callback.
	-- Drop their wrappers without calling methods on the stale objects.
	power_links = {}
	missing_scans = {}
	rejected_loads = {}
	hover_patch = nil
	last_scan_summary = nil
	ready = true
	scan_after = tick + 120
	log("world ready; PoE scan starts after 120 ticks")
end
