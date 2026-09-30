# Developing Rack UPS Power

## Runtime behavior

The mod bridges a UPS power controller to devices locked in the same rack
`Mount`. Source matching uses the case-insensitive product-name fragments in
`SUPPORTED_UPS_PRODUCT_FRAGMENTS` near the top of `entry.lua`. A matching UPS
still needs a power controller that can supply power, is enabled and charged,
and is locked in the same `Mount` instance as the target. The target must also
be locked, have its power switch on, and want power. Already-powered targets
keep their existing supply.

For an eligible target, the mod transfers its main and auxiliary `Power` loads
from their original controllers using `remove_local()` and `add_local()`. It
sets each `Power.controller` back-reference when the game leaves it on the
original controller, refreshes both controllers, and broadcasts power
restoration. When the rack relationship ends, it restores the original
memberships and power state. The transfer does not create physical power
sockets.

Before save export, the mod restores active links so virtual rack power is
not serialized. A later scan can re-establish eligible links in the live
world. During world transitions it drops old node references rather than
calling freed controllers. On a new world, scanning starts after an initial
delay so the device graph can settle.

## Limits and selection

`SCAN_PERIOD = 30` and `START_DELAY = 120` control the scan schedule. The
source's output rate limits the estimated watts of each target and the
combined load already on the UPS. The mod estimates target demand from live,
fallback, logic, and original-controller loads. It also requires UPS charge
of at least `MIN_CHARGE_MULTIPLIER = 10` times the estimated watts. Unknown or
over-limit loads are rejected.

When multiple eligible UPS units share a rack, the one with the lowest
instance ID is selected. The hover label is polled every
`HOVER_POLL_PERIOD = 6` ticks and corrected from English “Unpowered” to green
“Powered” only while a rack link is active. The previous label text is
restored when that link stops supplying power.

The stock Mountable Tenabolt UPS2E (R500) has passed the stock-device test
sequence. The source list also contains UPS2H and UPS2X fragments, but their
rack behavior is not validated. The local device catalog marks stock UPS2X
as non-rack; matching its product name does not bypass the shared locked
`Mount` requirement. To add a model, add one distinctive lowercase fragment
to `SUPPORTED_UPS_PRODUCT_FRAGMENTS`, then test actual mounting and power
behavior before describing it as supported.

## Diagnostics

Set `DEBUG_LOGGING = true` near the top of `entry.lua` and fully restart the
game to enable array checkpoints, mount and F-key probes, transfer and load
audits, source-selection messages, and hover corrections. It defaults to
`false` for normal play. Scan, link-resolution, membership-restoration, and
save-restoration warnings still print when debug logging is off. Array
checkpoint output is bounded by `ARRAY_PROBE_BUDGET`; the last checkpoint is
emitted before traversal and does not prove that traversal caused a later
fault.

Use a preset with only `luajit-support` and this mod for a baseline. Test
lock and power-switch changes, hover text, save/reload, floor changes, and
world cleanup. Compare the first failure with preceding actions. Avoid Quick
Mods Reload when diagnosing runtime faults. The repository's
`tools/inspect_logs.py` can summarize `godot.log`; archive useful full logs
before the next launch replaces them. See [INVESTIGATION.md](../../dist/UPR_INVESTIGATION.md)
for the runbook, archived runs, and unresolved observations.

## Implementation notes

- Device discovery uses `ModApiV1.get_devices()`. Target descendants are
  walked through `get_children()`, and controller `locals` use the Godot
  array iterator in `lib/gd.lua`. Earlier broad traversals and callbacks
  were associated with sandbox faults; change one traversal at a time and
  validate it across save/reload.
- Hover correction is polled instead of entering Lua from the label's
  `finished` signal, which produced callback errors in earlier runs. Link
  cleanup walks a stable list of target IDs because table iteration faulted
  after linked scans in the sandbox.
- The mod stops automatic Lua collection and drains wrappers after tick work
  to avoid finalizing a Godot object after its node is freed.
- Updating `Power.controller` still makes game 0.12.7 log
  `untested codeflow: controller change on power object`. Successful stock
  tests contained these engine messages without sandbox faults. Exit RID
  leaks and occasional world artifact timeouts are tracked separately.

The manifest (`mod.jsonc`) declares the game and `luajit-support`
dependencies. Keep the workspace and installed mod copies synchronized when
testing; editing source alone does not change the code the game loads.
