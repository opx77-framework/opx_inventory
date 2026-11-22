# opx_inventory

A simple inventory in an opx_menu menu: pockets, stashes, unique items with metadata, weapons, give items or cash, show your ID card. Every character gets a starter kit once.

## Install
- Needs: `opx_core`, `opx_menu`, `opx_dialog`, `open77_weapons >= 0.1.0`. Load after them.
- Creates its `opx_inventories` table at start.
- Staff commands: grant `command.giveitem`, `command.giveweapon`, `command.removeitem`, `command.clearinventory`, `command.inventory` (the `admin` role's `command.*` covers them).
- Provider of the inventory slot (`opx_core` `Config.providers.inventory`): a replacement implements the exports in `types.lua`.
- Weapons are client state: a disconnect between two syncs keeps the last synced ammo.
- No item list here: each item comes from the resource that gives it a meaning (`opx_needs` food and drink, `opx_medical` bandage and medkit, weapon resources...). opx_inventory registers only `id_card`.

## In game
- I (rebindable): open the inventory. Each item: Use, Equip, Give, Show, Inspect, Destroy. The Cash row gives cash.
- Targeting eye on a player: Give item, Give cash, Show ID.
- `giveitem <id|me> <item> [count] [key=value ...]`, `giveweapon <id|me> <weapon> [ammo]`, `removeitem <id|me> <item> [count]` (staff).
- `clearinventory <id|me>`, `inventory <id>` (read-only view) (staff).

## Config
`config.lua`: `Config.pockets`, `Config.starterItems` (id_card, water, bread; a row whose item no resource registered is skipped), `Config.cash`, `Config.weapons`. Everything else is commented in the file.

## For developers
- All exports are synchronous.
- `AddItem(source, item, count, meta?)` / `RemoveItem(source, item, count, instanceId?)` → `true` or `false, reason`.
- `HasItem(source, item, count?)` → boolean. `CanCarry(source, item, count)` → `true` or `false, reason`.
- `GetItems(source)` → rows or `nil, reason`.
- `RegisterItem(item, { label, description?, weightG, unique?, maxStack?, usable?, showable?, weapon?, ammo?, characterMeta? })` / `UnregisterItem(item)` → `true` or `false, reason`. The only way an item exists. Call it on your start and on `onResourceStart` of the provider from `exports.opx_core:GetProvider('inventory')`. `weapon` = TweakDB record (unique), `ammo` = its stack ammo item. `GetItemNames()` → sorted ids.
- `RegisterUsable(item, exportName)`: your export runs when a player uses the item; return `true` to consume one. The inventory has no effect of its own.
- Client exports `GetItemCount(item)`, `HasItem(item, count?)`, `GetItems()`, `GetItemNames()`, and the client event `opx:inventory:counts (counts)`: what the player carries, without a callback (display only).
- `OpenStash(source, name, { label?, capacityG?, slots? })` → `true` or `false, reason`. Your resource decides who may open it.
- Events: `opx:inventory:changed (source, item, delta)`, `opx:inventory:itemRegistered (item, resource)`, `opx:inventory:itemUnregistered (item)` (optional in the contract).
- Full contract: `types.lua`.
