Config = {}

-- Language of the menus: 'auto' follows opx_core's language, or 'en' / 'fr'.
Config.locale = 'auto'

-- Default key that opens the inventory (each player can rebind it in Settings > Key bindings).
Config.key = 'I'

-- Pockets of every character (container char:<citizenId>): carried weight in grams, and the most
-- different stacks + unique items they hold. Keep slots at 60 or less (one menu row each).
Config.pockets = {
	capacityG = 30000,
	slots = 40,
}

-- Stashes opened by other resources (exports OpenStash) when they pass no size, and how far (metres)
-- the player may walk from where the stash was opened before put / take are refused.
Config.stash = {
	capacityG = 100000,
	slots = 50,
	maxDistance = 4.0,
}

-- Seconds between a change and the write of that inventory to the database (a burst of changes costs one
-- write). Inventories are also written when a character unloads, a stash is closed, and at resource stop.
Config.saveSeconds = 5

-- Give: metres between the two players (the server checks it again, same routing bucket only).
Config.giveDistance = 3.0

-- Give cash: a "Cash" row at the top of the pockets and "Give cash" in the targeting eye.
-- account: opx_core account that moves ('money' = cash); max: most one give may move (integer).
Config.cash = {
	enabled = true,
	account = 'money',
	max = 1000000,
}

-- open77_animations profile the giver plays once after a give (item or cash) was accepted; false = none.
-- Purely cosmetic: skipped when open77_animations does not run.
Config.giveAnimation = 'give'

-- Requests per second a player may send (menu actions). One menu action runs at a time per player.
Config.actionsPerSecond = 4

-- Block the game's own RPG hub (vanilla inventory, crafting...) while a character is loaded.
Config.blockHub = true

-- Weapons. slots: weapon slots used for equipped items (1..3 are the normal slots).
-- syncSeconds: how often the ammo of an armed player is read back from the game (0 = only on unequip).
-- stripUnknown: remove a weapon the inventory did not equip (a modified client, a leftover).
Config.weapons = {
	slots = { 1, 2, 3 },
	syncSeconds = 60,
	stripUnknown = true,
}

-- "Give item" (and "Give cash" when Config.cash.enabled) on players in the targeting eye (opx_target), when
-- opx_target runs.
Config.target = true

-- Show a card: "Show" on `showable` items and "Show ID" in the targeting eye. The nearby player (giveDistance,
-- same bucket) reads one notification with the card's details for `seconds`. Nothing changes hands.
Config.show = {
	enabled = true,
	seconds = 10,
}

-- Given once to every character, the first time its pockets load (characters created earlier get it at their
-- next load; an item already in the pockets is skipped). count defaults to 1. false = no starter items.
-- There is no item list here: each item is registered by the resource that gives it a meaning (exports
-- RegisterItem). opx_inventory registers id_card; water and bread come from opx_needs. A row whose item is not
-- registered when the kit is given is skipped (with a warning in the log) and not given later.
Config.starterItems = {
	{ item = 'id_card' },
	{ item = 'water', count = 2 },
	{ item = 'bread', count = 2 },
}

-- Staff commands, restricted: grant the ACL right `command.<name>` in acl.jsonc. false = not registered.
Config.commands = {
	giveitem = 'giveitem',             -- giveitem <playerId|me> <item> [count] [key=value ...]
	giveweapon = 'giveweapon',         -- giveweapon <playerId|me> <weaponItem> [ammo]
	removeitem = 'removeitem',         -- removeitem <playerId|me> <item> [count]
	clearinventory = 'clearinventory', -- clearinventory <playerId|me>
	inventory = 'inventory',           -- inventory <playerId>: shows that player's items (read-only)
}

-- Update check at start: compares this version with the one published on GitHub and prints a line in the
-- server console when an update is out. Needs outbound HTTP in server.jsonc ("http": "enabled": true, with
-- "raw.githubusercontent.com" in "allowedHosts"). false = no request.
Config.versionCheck = true
