resource "opx_inventory"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true

-- OPX//77 inventory: items, metadata, stashes and weapons, shown in opx_menu. Contents live in memory on the
-- server and in the MySQL table opx_inventories (created at start). Give cash moves money through opx_core.
-- Optional, never required: opx_target (eye options), open77_animations (the giver's `give` animation).
dependency "opx_core"
dependency "opx_menu"
dependency "opx_dialog"
dependency "open77_weapons >=0.1.0"

shared_script "config.lua"

-- No `require` on the server: the files share the `Inv` table, in this order.
server_script "server/util.lua"
server_script "server/storage.lua"
server_script "server/inventory.lua"
server_script "server/weapons.lua"
server_script "server/stash.lua"
server_script "server/catalogue.lua"
server_script "server/actions.lua"
server_script "server/commands.lua"
server_script "server/main.lua"
server_script "server/version.lua"

client_script "client/main.lua"

files {
	"client/modules/*.lua",
	"locales/*.json",
}

permissions {
	"database.access",      -- server: Open77.database.* (table opx_inventories)
	"network.events",       -- both: menu intents and views; server: Open77.weapons.* requests (assign, setAmmo, remove, clear, requestSnapshot)
	"players.life.read",    -- server: Open77.players.get (stash distance), Open77.players.isDead (no use / give while dead)
	"input.actions",        -- client: RegisterKeyMapping (inventory key), Open77.input.setActionBlocked('Hub')
	"ui.vanilla.hud",       -- client: Open77.hud.notify when opx_core does not answer
	"http.request", -- server: Open77.http.get (update check, Config.versionCheck)
}
