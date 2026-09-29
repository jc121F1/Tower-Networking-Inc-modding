# Power over Ethernet

Power over Ethernet (PoE) lets a powered network switch supply power to a compatible device through its Ethernet connection. The mod is for Tower Networking Inc. 0.12.0 or later and requires the `luajit-support` mod.

## Install

1. Install and enable `luajit-support`.
2. Copy this mod folder into the game's mods folder, keeping the folder name `power-over-ethernet`.
3. Enable **Everything's Power over Ethernet** in the in-game Mod Manager and reload.
4. Connect a powered network switch to a compatible device with an Ethernet cable.

On Windows, the mods folder is `%APPDATA%\Godot\app_userdata\Tower Networking Inc\mods`. On Linux, it is `~/.local/share/godot/app_userdata/Tower Networking Inc/mods`.

## How it works

The mod supplies power only while the Ethernet connection is present. It supports endpoints with an estimated load of up to 15 W and limits each switch to 120 W total. A device that already has power keeps its existing supply. A switch receiving PoE can act as a network switch, but cannot pass PoE on to other devices.

The mod does not add or alter physical power sockets. Disconnecting the Ethernet cable returns the device's power load to its original controller. The device's own power switch must be on for PoE to be supplied.

For technical details, diagnostics, and development notes, see [DEVELOPING.md](DEVELOPING.md).
