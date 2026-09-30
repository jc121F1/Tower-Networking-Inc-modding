# Everything's UPS Powered Racks

Everything's UPS Powered Racks lets a UPS supply power to devices locked into the same rack.
It is a LuaJIT mod for Tower Networking Inc. 0.12.x, requires
`luajit-support` 0.2.x, and has been tested with game version 0.12.7.

## Install

1. Install and enable `luajit-support`.
2. Copy this mod folder into the game's mods folder, keeping the name
   `ups-powered-racks`.
3. Enable **Everything's UPS Powered Racks** in the in-game Mod Manager and restart the
   game.
4. Lock a mountable UPS and the devices you want to power into the same rack.

On Windows, the mods folder is
`%APPDATA%\Godot\app_userdata\Tower Networking Inc\mods`. On Linux, it is
`~/.local/share/godot/app_userdata/Tower Networking Inc/mods`.

## How it works

The UPS supplies power while it and the target are locked in the same rack,
the UPS is enabled and charged, and it has enough output capacity. The
target's own power switch must be on. A device that already has power keeps
its existing supply.

Unlocking either device, turning off a power switch, or removing the UPS
returns the target to its original power source. The mod also restores that
connection before saving and reconnects the rack power afterward. Its hover
label shows green **Powered** for an active rack link.

For implementation details and diagnostics, see
[DEVELOPING.md](DEVELOPING.md).
