# Developing Power over Ethernet

## Runtime behavior

The game keeps mains power and Ethernet in separate graphs. This mod bridges them only while a physical Ethernet cable connects a powered switch to an eligible endpoint. It transfers the endpoint's `Power` loads with `PowerController.remove_local()` and `add_local()`, then updates the `Power.controller` reference. It also transfers auxiliary `Power` objects used by components such as status lights. It does not create or move physical power sockets.

On disconnect, the mod returns transferred loads to their original power controller and broadcasts the power-lost event while preserving the device's power intent. After transfer it refreshes the involved controllers, calls `Power.on()` when needed, and broadcasts power-restored so normal device listeners can start the OS and update indicators.

The endpoint's original controller must not be disabled. Already-powered endpoints remain on their existing supply. A switch powered by PoE is treated as a terminal endpoint: it may switch network traffic but is not considered a PoE source. An active endpoint keeps its current PoE source until the link is removed; a different source can be selected on a later scan.

## Limits and selection

The limits are `TOTAL_BUDGET_W = 120` per switch and `PORT_BUDGET_W = 15` per endpoint in `entry.lua`. The mod estimates demand using the live endpoint load, configured fallback load, logic-controller load, and original controller rate. Unknown or over-limit loads are rejected. It checks combined live load again after auxiliary components start.

The game is scanned every 30 ticks after an initial 120-tick delay. The hover label is corrected from “Unpowered” to green “Powered” while a PoE link is active, then restored when the link is lost. The correction runs when the hover label's `finished` signal fires, with the periodic scan as a fallback.

## Diagnostics

Set `AUDIT = true` near the top of `entry.lua` to log detailed diagnostics on each scan. It defaults to `false`; summaries, transfers, and errors are still logged. Audit output includes device electrical and OS state, power controllers and auxiliary loads, cable/socket edges, and candidate source decisions with estimated wattage. A snapshot is capped at 128 devices, 256 edges, and 256 candidates; truncation is reported. Diagnostics do not change routing.

## Implementation notes

- In game 0.12.7, `add_local()` adds a load to the new controller's `locals` but does not update the load's `Power.controller` reference. The mod sets the back-reference and refreshes both controllers.
- The device hover can display “Unpowered” while the PoE-powered `Power` object is live. The visual correction currently recognizes the English label.
- Per-tick hover polling caused sandbox illegal-opcode faults, so the implementation uses the label signal and the existing scan fallback.
- Repeated scans previously exhausted the sandbox heap. The implementation reuses each device's Ethernet socket list within a scan, logs only meaningful scan changes, and drains wrapper allocations at the end of each game tick.
- Updating `Power.controller` causes the game to emit `untested codeflow: controller change on power object`.

See `entry.lua` for implementation and tuning constants. The manifest (`mod.jsonc`) declares the game and `luajit-support` dependencies.
