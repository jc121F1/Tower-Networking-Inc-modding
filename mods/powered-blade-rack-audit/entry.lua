-- Read-only inventory for investigating powered blade chassis feasibility.
local gd = require("lib.gd")

local PREFIX = "[rack-audit] "
local START_DELAY = 120
local MAX_NODES_PER_SEGMENT = 2000
local MAX_TOTAL_NODES = 12000
local NODES_PER_TICK = 16
local MAX_LOG_LINES = 2400
local MAX_RUNTIME_PROPERTIES = 160
local tick, ready, scan_after = 0, false, math.huge
local audit = nil
local rack_watches = {}
local device_watches = {}
local next_rack_poll = 0
local pending_f_snapshot = false

local function log_timestamp()
	local ok, value = pcall(function()
		if os and os.date then return os.date("!%Y-%m-%dT%H:%M:%SZ") end
		if Time and Time.get_datetime_string_from_system then
			return Time.get_datetime_string_from_system(true, false)
		end
		return nil
	end)
	if ok and type(value) == "string" then return value end
	return "utc-unavailable"
end

local function log(fmt, ...)
	print(PREFIX .. "[" .. log_timestamp() .. " tick=" .. tostring(tick) .. "] "
		.. string.format(fmt, ...))
end

local function has(text, word)
	return string.find(string.lower(tostring(text or "")), word, 1, true) ~= nil
end

local function short(v)
	if v == nil then return "nil" end
	local t = type(v)
	if t == "string" or t == "number" or t == "boolean" then
		local s = tostring(v):gsub("[\r\n\t]", " ")
		if #s > 100 then s = string.sub(s, 1, 97) .. "..." end
		return s
	end
	return "<" .. t .. ">"
end

local function object_ref(value)
	if value == nil then return "nil" end
	if type(value) ~= "userdata" then return short(value) end
	return gd.name(value) .. "#" .. gd.id(value) .. "/" .. gd.class(value)
end

local PROPS = {
	"product_name", "device_hardware_class", "hardware_address", "network_address",
	"power_controller", "logic_controller", "controller", "power", "locals",
	"is_powered", "manifest_intent", "can_manifest", "current_load",
	"can_supply_power", "is_enabled_and_functional", "functional", "disabled",
	"charges", "charge_capacity", "charge_rate", "mount", "mounted", "rack",
	"rack_id", "chassis", "slot", "bay",
	"base_mounted_area", "mount_type", "base_size", "fixed", "is_mount_locked",
	"freeze", "freeze_mode", "sleeping", "lock_rotation",
	"is_picked", "is_picked_by_mouse", "is_picked_by_attaching", "picker", "picker_type",
	"collision_layer", "collision_mask", "monitoring", "monitorable",
}

local function object_summary(node)
	local props = {}
	for _, key in ipairs(PROPS) do
		local value = gd.get(node, key)
		if value ~= nil then
			local rendered = short(value)
			if key == "power_controller" or key == "logic_controller" or key == "controller"
				or key == "power" or key == "base_mounted_area" or key == "picker" then
				rendered = object_ref(value)
			end
			props[#props + 1] = key .. "=" .. rendered
		end
	end
	return table.concat(props, " ")
end

local function is_interesting(node)
	local name, class = gd.name(node), gd.class(node)
	if has(name, "rack") or has(name, "chassis") or has(name, "blade")
		or name == "Mount" or name == "RackBorder"
		or has(class, "rack") or has(class, "chassis") or has(class, "blade")
		or has(class, "powercontroller") or has(class, "power") then return true end
	for _, key in ipairs({ "power_controller", "logic_controller", "controller", "power", "locals" }) do
		if gd.get(node, key) ~= nil then return true end
	end
	return false
end

local function ancestry(device)
	local parts, node = {}, device
	for i = 1, 12 do
		if not node then break end
		parts[#parts + 1] = gd.name(node) .. "#" .. gd.id(node) .. "/" .. gd.class(node)
		node = gd.parent(node)
	end
	return table.concat(parts, " <- ")
end

local function start_scan()
	local world = nil
	local ok = pcall(function() world = ModApiV1.get_game_world() end)
	if not ok or not world then log("scan aborted: game world unavailable"); return false end
	local roots, tail = {}, 0
	for _, path in ipairs({ "DeviceSpawner", "FixtureSpawner" }) do
		local root = gd.call(world, "get_node", path)
		if root then
			tail = tail + 1
			roots[tail] = { node = root, depth = 0 }
		end
	end
	if tail == 0 then
		log("scan aborted: DeviceSpawner and FixtureSpawner were not found")
		return false
	end
	audit = {
		queue = roots, head = 1, tail = tail,
		visited = 0, segment_visited = 0, segment = 1, candidates = 0, logged = 0,
	}
	rack_watches = {}
	device_watches = {}
	next_rack_poll = tick
	log("scan started tick=%d roots=DeviceSpawner,FixtureSpawner; %d-node segments, %d-node total cap, %d nodes per tick",
		tick, MAX_NODES_PER_SEGMENT, MAX_TOTAL_NODES, NODES_PER_TICK)
	return true
end

local function log_candidate(node, depth)
	if audit.logged >= MAX_LOG_LINES then return end
	local name, class = gd.name(node), gd.class(node)
	local position = ""
	if has(name, "rack") or has(name, "blade") or name == "Mount" or name == "RackBorder"
		or gd.get(node, "device_hardware_class") ~= nil then
		position = string.format(" global_xy=(%s,%s)", short(gd.gidx(node, "global_position:x")),
			short(gd.gidx(node, "global_position:y")))
	end
	log("node depth=%d name=%s id=%s class=%s props={%s} ancestry={%s}%s", depth,
		name, gd.id(node), class, object_summary(node), ancestry(node), position)
	if gd.get(node, "locals") ~= nil then
		local local_index = 0
		gd.each(gd.get(node, "locals"), function(_, power)
			local_index = local_index + 1
			if local_index <= 20 then
				if type(power) == "userdata" then
					log("controller_local controller=%s#%s index=%d power=%s props={%s}",
						gd.name(node), gd.id(node), local_index, object_ref(power), object_summary(power))
				else
					log("controller_local controller=%s#%s index=%d non_object=%s",
						gd.name(node), gd.id(node), local_index, short(power))
				end
			end
		end)
		if local_index > 20 then log("controller_local output capped controller=%s#%s omitted=%d",
			gd.name(node), gd.id(node), local_index - 20) end
	end
	audit.logged = audit.logged + 1
end

local function mount_signature(device)
	local parent = gd.parent(device)
	return table.concat({
		object_ref(gd.get(device, "base_mounted_area")),
		short(gd.get(device, "mount_type")),
		short(gd.gidx(device, "global_position:x")),
		short(gd.gidx(device, "global_position:y")),
		object_ref(parent),
		short(gd.get(device, "is_picked")),
		short(gd.get(device, "is_picked_by_mouse")),
		short(gd.get(device, "is_picked_by_attaching")),
		short(gd.get(device, "fixed")),
		short(gd.get(device, "is_mount_locked")),
		short(gd.get(device, "freeze")),
		short(gd.get(device, "freeze_mode")),
		short(gd.get(device, "sleeping")),
		short(gd.get(device, "lock_rotation")),
		object_ref(gd.get(device, "picker")),
		short(gd.get(device, "collision_layer")),
		short(gd.get(device, "collision_mask")),
		short(gd.get(device, "z_index")),
	}, "|")
end

local function log_runtime_property_names(device)
	local list = gd.call(device, "get_property_list")
	if list == nil then
		log("runtime_property_list unavailable device=%s", gd.name(device) .. "#" .. gd.id(device))
		return
	end
	local names, total = {}, 0
	gd.each(list, function(_, entry)
		local name = gd.get(entry, "name")
		if type(name) == "string" and name ~= "" then
			total = total + 1
			if #names < MAX_RUNTIME_PROPERTIES then names[#names + 1] = name end
		end
	end)
	table.sort(names)
	log("runtime_property_list device=%s count=%d logged=%d names={%s}",
		gd.name(device) .. "#" .. gd.id(device), total, #names, table.concat(names, ","))
end

local function watch_device_mount_state(node)
	if gd.get(node, "device_hardware_class") == nil then return end
	local id = gd.id(node)
	if id == "?" or device_watches[id] then return end
	local watch = { node = node, name = gd.name(node) .. "#" .. id, last = nil }
	device_watches[id] = watch
	watch.last = mount_signature(node)
	log("mount_state baseline device=%s product=%s state={base_mounted_area=%s mount_type=%s global_xy=(%s,%s) parent=%s picked=%s attaching=%s fixed=%s mount_locked=%s freeze=%s freeze_mode=%s sleeping=%s lock_rotation=%s picker=%s collision=(%s,%s) z_index=%s velocity=(%s,%s,%s)}",
		watch.name, short(gd.get(node, "product_name")),
		object_ref(gd.get(node, "base_mounted_area")), short(gd.get(node, "mount_type")),
		short(gd.gidx(node, "global_position:x")), short(gd.gidx(node, "global_position:y")),
		object_ref(gd.parent(node)), short(gd.get(node, "is_picked")),
		short(gd.get(node, "is_picked_by_attaching")), short(gd.get(node, "fixed")),
		short(gd.get(node, "is_mount_locked")),
		short(gd.get(node, "freeze")), short(gd.get(node, "freeze_mode")),
		short(gd.get(node, "sleeping")), short(gd.get(node, "lock_rotation")),
		object_ref(gd.get(node, "picker")), short(gd.get(node, "collision_layer")),
		short(gd.get(node, "collision_mask")), short(gd.get(node, "z_index")),
		short(gd.gidx(node, "linear_velocity:x")), short(gd.gidx(node, "linear_velocity:y")),
		short(gd.get(node, "angular_velocity")))
end

local function poll_device_mount_state(force_firewatch_sample)
	for id, watch in pairs(device_watches) do
		local current = mount_signature(watch.node)
		local changed = current ~= watch.last
		local product = short(gd.get(watch.node, "product_name"))
		local is_firewatch = has(product, "firewatch")
		if force_firewatch_sample and is_firewatch and not watch.runtime_properties_logged then
			log_runtime_property_names(watch.node)
			watch.runtime_properties_logged = true
		end
		if changed or (force_firewatch_sample and is_firewatch) then
			local kind = changed and "changed" or "sample"
			local reason = force_firewatch_sample and is_firewatch and "F_key" or "field_change"
			log("mount_state %s device=%s product=%s reason=%s state={base_mounted_area=%s mount_type=%s global_xy=(%s,%s) parent=%s picked=%s attaching=%s fixed=%s mount_locked=%s freeze=%s freeze_mode=%s sleeping=%s lock_rotation=%s picker=%s collision=(%s,%s) z_index=%s velocity=(%s,%s,%s)}",
				kind, watch.name, product, reason,
				object_ref(gd.get(watch.node, "base_mounted_area")), short(gd.get(watch.node, "mount_type")),
				short(gd.gidx(watch.node, "global_position:x")), short(gd.gidx(watch.node, "global_position:y")),
				object_ref(gd.parent(watch.node)), short(gd.get(watch.node, "is_picked")),
				short(gd.get(watch.node, "is_picked_by_attaching")), short(gd.get(watch.node, "fixed")),
				short(gd.get(watch.node, "is_mount_locked")),
				short(gd.get(watch.node, "freeze")), short(gd.get(watch.node, "freeze_mode")),
				short(gd.get(watch.node, "sleeping")), short(gd.get(watch.node, "lock_rotation")),
				object_ref(gd.get(watch.node, "picker")), short(gd.get(watch.node, "collision_layer")),
				short(gd.get(watch.node, "collision_mask")), short(gd.get(watch.node, "z_index")),
				short(gd.gidx(watch.node, "linear_velocity:x")),
				short(gd.gidx(watch.node, "linear_velocity:y")),
				short(gd.get(watch.node, "angular_velocity")))
			watch.last = current
		end
	end
	pending_f_snapshot = false
	next_rack_poll = tick + 60
end

local function watch_rack_area(node)
	local area_name = gd.name(node)
	if area_name ~= "Mount" and area_name ~= "RackBorder" then return end
	local id = gd.id(node)
	if id == "?" or rack_watches[id] then return end
	local rack = gd.parent(node)
	rack_watches[id] = {
		node = node,
		name = gd.name(rack) .. "#" .. gd.id(rack) .. "/" .. area_name,
		last = nil, last_count = nil,
	}
	log("rack_area discovered rack=%s area=%s#%s class=%s props={%s} local_xy=(%s,%s) global_xy=(%s,%s)",
		rack_watches[id].name, area_name, id, gd.class(node), object_summary(node),
		short(gd.gidx(node, "position:x")), short(gd.gidx(node, "position:y")),
		short(gd.gidx(node, "global_position:x")), short(gd.gidx(node, "global_position:y")))
	gd.each(gd.children(node), function(_, child)
		if gd.class(child) == "CollisionShape2D" then
			local shape = gd.get(child, "shape")
			log("rack_area_shape rack=%s shape=%s#%s resource=%s local_xy=(%s,%s) size=(%s,%s)",
				rack_watches[id].name, gd.name(child), gd.id(child), object_ref(shape),
				short(gd.gidx(child, "position:x")), short(gd.gidx(child, "position:y")),
				short(gd.gidx(shape, "size:x")), short(gd.gidx(shape, "size:y")))
		end
	end)
end

local function poll_rack_areas()
	for area_id, watch in pairs(rack_watches) do
		local bodies = gd.call(watch.node, "get_overlapping_bodies")
		if bodies == nil then
			if watch.last ~= "unavailable" then
				log("rack_overlap rack=%s area=%s query=unavailable", watch.name, area_id)
				watch.last = "unavailable"
			end
		else
			local current = {}
			local count = 0
			gd.each(bodies, function(_, body)
				local body_id = gd.id(body)
				if body_id ~= "?" then
					count = count + 1
					current[body_id] = true
					if watch.last == nil or watch.last == "unavailable" or not watch.last[body_id] then
						local parent = gd.parent(body)
						log("rack_overlap rack=%s area=%s body=%s#%s/%s product=%s parent=%s#%s hw=%s",
							watch.name, area_id, gd.name(body), body_id, gd.class(body),
							short(gd.get(body, "product_name")), gd.name(parent), gd.id(parent),
							short(gd.get(gd.get(body, "logic_controller"), "hardware_address")))
					end
				end
			end)
			if watch.last_count ~= count then
				log("rack_overlap_state rack=%s area=%s count=%d", watch.name, area_id, count)
			end
			if type(watch.last) == "table" then
				for body_id in pairs(watch.last) do
					if not current[body_id] then
						log("rack_overlap_lost rack=%s area=%s body_id=%s", watch.name, area_id, body_id)
					end
				end
			end
			watch.last = current
			watch.last_count = count
		end
	end
	 next_rack_poll = tick + 120
end

local function advance_scan()
	local processed = 0
	while audit and processed < NODES_PER_TICK and audit.head <= audit.tail
		and audit.segment_visited < MAX_NODES_PER_SEGMENT
		and audit.visited < MAX_TOTAL_NODES do
		local item = audit.queue[audit.head]
		-- Keep only the frontier in memory; processed Godot wrappers can be freed.
		audit.queue[audit.head] = nil
		audit.head = audit.head + 1
		local node = item.node
		if node then
			watch_rack_area(node)
			watch_device_mount_state(node)
			audit.visited = audit.visited + 1
			audit.segment_visited = audit.segment_visited + 1
			processed = processed + 1
			if is_interesting(node) then
				audit.candidates = audit.candidates + 1
				log_candidate(node, item.depth)
			end
			gd.each(gd.children(node), function(_, child)
				audit.tail = audit.tail + 1
				audit.queue[audit.tail] = { node = child, depth = item.depth + 1 }
			end)
		end
	end
	if audit and audit.head <= audit.tail
		and audit.segment_visited >= MAX_NODES_PER_SEGMENT
		and audit.visited < MAX_TOTAL_NODES then
		log("scan checkpoint tick=%d segment=%d total_visited=%d candidates=%d logged=%d queued=%d; resuming from saved frontier",
			tick, audit.segment, audit.visited, audit.candidates, audit.logged, audit.tail - audit.head + 1)
		audit.segment = audit.segment + 1
		audit.segment_visited = 0
	elseif audit and (audit.head > audit.tail or audit.visited >= MAX_TOTAL_NODES) then
		local completed = audit.head > audit.tail
		log("scan finished tick=%d segments=%d total_visited=%d candidate_nodes=%d logged=%d complete=%s total_cap_reached=%s",
			tick, audit.segment, audit.visited, audit.candidates, audit.logged,
			tostring(completed), tostring(not completed))
		audit = nil
		scan_after = math.huge
	end
end

function on_game_state_ready()
	-- Drop queued scene wrappers before a new world starts.
	audit = nil
	rack_watches = {}
	device_watches = {}
	pending_f_snapshot = false
	next_rack_poll = 0
	ready = true
	scan_after = tick + START_DELAY
	log("world ready; read-only scene audit begins after %d ticks; thereafter only changed mount state is logged", START_DELAY)
end

function on_player_input(event)
	if gd.class(event) ~= "InputEventKey" then return nil end
	if gd.get(event, "pressed") ~= true or gd.get(event, "echo") == true then return nil end
	local keycode = tonumber(gd.get(event, "keycode")) or 0
	local physical_keycode = tonumber(gd.get(event, "physical_keycode")) or 0
	if keycode == 70 or physical_keycode == 70 then
		log("input key=F pressed; scheduling immediate FireWatch state sample")
		pending_f_snapshot = true
		next_rack_poll = tick
	end
	return nil
end

function on_game_tick()
	tick = tick + 1
	if ready then
		if not audit and tick >= scan_after then
			local ok, started = pcall(start_scan)
			if not ok then
				log("scan start error: %s", tostring(started))
				scan_after = tick + START_DELAY
			elseif not started then
				scan_after = tick + START_DELAY
			end
		end
		if audit then
			local ok, err = pcall(advance_scan)
			if not ok then log("scan error: %s", tostring(err)); audit = nil; scan_after = math.huge end
		end
		if tick >= next_rack_poll and (next(rack_watches) or next(device_watches)) then
			local ok, err = pcall(function()
				poll_rack_areas()
				poll_device_mount_state(pending_f_snapshot)
			end)
			if not ok then log("mount state poll error: %s", tostring(err)); next_rack_poll = tick + 60 end
		end
	end
	return nil
end
