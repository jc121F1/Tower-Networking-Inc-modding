# Powered Blade Rack Audit

This is a read-only investigation mod for Tower Networking Inc 0.12.0+.
It records candidate rack/chassis/blade nodes, device ancestry, power objects,
PowerControllers, and selected mount/power properties. It does not mutate
power, sockets, device state, or scene nodes.

Enable it alongside `luajit-support`. After loading a save, look for
`[rack-audit]` lines in the game log. It waits 120 game ticks after the world
ready callback, then walks the `DeviceSpawner` and `FixtureSpawner` subtrees
once, visiting at most 16 nodes per game tick. It saves the pending frontier at
each 2,000-node checkpoint and resumes from there, up to 12,000 nodes total. It
releases processed node references as it goes to limit sandbox heap use.
Detailed output is capped at 2,400 node records for that scan. It records each
device's `base_mounted_area`, `mount_type`, position, parent, picker state,
`fixed`, the runtime-discovered `is_mount_locked`, and inherited rigid-body
freeze/sleep state,
then polls only those fields every 60 ticks and logs changes. It also polls
discovered `Mount` and `RackBorder` areas for overlapping bodies. `Mount` is the
actual seating area in the custom rack builder; `RackBorder` is the visible
frame. Area logs include local/global positions and collision-shape dimensions.
F key presses are timestamped and trigger an immediate FireWatch state sample
including picker, collision, z-index, and velocity fields, to correlate the
in-game lock action with mount/freeze changes. The first F press also logs the
FireWatch runtime property names once, to expose any game-specific lock field
not present in the generated API typings.
Every audit line includes a UTC wall-clock timestamp when available, plus the
current game tick.

The audit is intentionally exploratory: a reported property is evidence that
the binding exposes a value, not proof of its gameplay meaning. In particular,
`PowerController` references and mount ancestry are observed without testing
any load transfer.

