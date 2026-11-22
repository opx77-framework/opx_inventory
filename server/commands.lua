-- Staff commands. Registered restricted: the host checks the ACL right `command.<name>`.
-- Feedback goes to the caller as a notification (locale key); from the server console it is printed in English.

local CONSOLE = {
	cmd_usage = 'Usage: %s',
	cmd_no_player = 'No loaded character for player %s',
	cmd_failed = 'Failed: %s',
	cmd_in_game = 'Use this command in game',
	cmd_given = 'Given %s x%s to player %s',
	cmd_removed = 'Removed %s x%s from player %s',
	cmd_cleared = 'Inventory of player %s cleared (%s entries)',
}

local function reply(source, key, args, kind)
	if source == 0 then
		local ok, text = pcall(string.format, CONSOLE[key] or key, table.unpack(args or {}))
		print('[opx_inventory] ' .. (ok and text or key))
		return
	end
	-- Params travel as a positional list; the client formats its locale string with them.
	Inv.Notify(source, key, { list = args }, kind)
end

-- The target player with a loaded inventory, or nil after telling the caller. `me` = the caller.
local function target(source, value)
	local id = Inv.ToSource(value)
	if not id and source ~= 0 and type(value) == 'string' and value:lower() == 'me' then id = source end
	if id and Inv.Get(id) then return id end
	reply(source, 'cmd_no_player', { tostring(value) }, 'error')
	return nil
end

-- "key=value" words -> metadata (integers stay numbers, true/false booleans).
local function metaArgs(args, first)
	local meta
	for i = first, args.n do
		local key, value = tostring(args[i]):match('^([%w_]+)=(.*)$')
		if key then
			meta = meta or {}
			if value == 'true' or value == 'false' then meta[key] = value == 'true'
			else meta[key] = Inv.ToInteger(value) or value end
		end
	end
	return meta
end

local handlers = {}

function handlers.giveitem(source, args, name)
	if args.n < 2 then return reply(source, 'cmd_usage', { name .. ' <playerId|me> <item> [count] [key=value ...]' }, 'error') end
	local id = target(source, args[1])
	if not id then return end
	local item = tostring(args[2]):lower()
	if not Inv.Def(item) then return reply(source, 'cmd_failed', { 'unknown_item' }, 'error') end
	local count, metaFrom = 1, 3
	if args[3] and not tostring(args[3]):find('=', 1, true) then
		count = Inv.ToCount(args[3], 1000000)
		metaFrom = 4
		if not count then return reply(source, 'cmd_failed', { 'invalid_count' }, 'error') end
	end
	local meta, why = metaArgs(args, metaFrom), nil
	if meta then
		meta, why = Inv.CleanMeta(meta)
		if not meta then return reply(source, 'cmd_failed', { why }, 'error') end
	end
	local ok, err = Inv.AddTo(Inv.Get(id), item, count, meta)
	if not ok then return reply(source, 'cmd_failed', { tostring(err) }, 'error') end
	Inv.Info(('staff %s gave %s x%d to player %d'):format(tostring(source), item, count, id))
	reply(source, 'cmd_given', { item, count, id }, 'success')
	if id ~= source then Inv.Notify(id, 'received', { item = item, count = count }, 'success') end
end

function handlers.giveweapon(source, args, name)
	if args.n < 2 then return reply(source, 'cmd_usage', { name .. ' <playerId|me> <weaponItem> [ammo]' }, 'error') end
	local id = target(source, args[1])
	if not id then return end
	local item = tostring(args[2]):lower()
	local def = Inv.Def(item)
	if not def or not def.weapon then return reply(source, 'cmd_failed', { 'not_a_weapon' }, 'error') end
	local ammo = args[3] and Inv.ToCount(args[3], 100000) or 0
	if args[3] and ammo == nil then return reply(source, 'cmd_failed', { 'invalid_count' }, 'error') end
	local ok, err = Inv.AddTo(Inv.Get(id), item, 1, nil)
	if not ok then return reply(source, 'cmd_failed', { tostring(err) }, 'error') end
	Inv.Info(('staff %s gave %s to player %d'):format(tostring(source), item, id))
	reply(source, 'cmd_given', { item, 1, id }, 'success')
	if ammo > 0 and def.ammo then
		ok, err = Inv.AddTo(Inv.Get(id), def.ammo, ammo, nil)
		if not ok then return reply(source, 'cmd_failed', { tostring(err) }, 'error') end
		reply(source, 'cmd_given', { def.ammo, ammo, id }, 'success')
	end
	if id ~= source then Inv.Notify(id, 'received', { item = item, count = 1 }, 'success') end
end

function handlers.removeitem(source, args, name)
	if args.n < 2 then return reply(source, 'cmd_usage', { name .. ' <playerId|me> <item> [count]' }, 'error') end
	local id = target(source, args[1])
	if not id then return end
	local item = tostring(args[2]):lower()
	local count = args[3] and Inv.ToCount(args[3], 1000000) or 1
	if not count then return reply(source, 'cmd_failed', { 'invalid_count' }, 'error') end
	local ok, err = Inv.WithLock(id, 10000, function(st)
		local fine, why = Inv.UnequipLeaving(st, item, count, nil)
		if not fine then return false, why end
		return Inv.RemoveFrom(st, item, count, nil)
	end)
	if not ok then return reply(source, 'cmd_failed', { tostring(err) }, 'error') end
	Inv.Info(('staff %s removed %s x%d from player %d'):format(tostring(source), item, count, id))
	reply(source, 'cmd_removed', { item, count, id }, 'success')
end

-- Empties the hands (spent ammo synced first), then everything in the pockets, in one step.
local function clearAll(st)
	local state = Weapons.State(st)
	if next(state.slots) then
		local ok, why = Weapons.Reconcile(st)
		if not ok then Inv.Warn('clear: ammo not synced: ' .. tostring(why)) end
		if Inv.players[st.source] ~= st then return false, 'not_loaded' end
		pcall(Open77.weapons.clear, st.source)
		state.slots, state.synced = {}, {}
	end
	local c = st.pockets
	local total = 0
	for _ in pairs(c.stacks) do total = total + 1 end
	for _ in pairs(c.instances) do total = total + 1 end
	c.stacks, c.instances = {}, {}
	Inv.Touch(c)
	return true, total
end

function handlers.clearinventory(source, args, name)
	if args.n < 1 then return reply(source, 'cmd_usage', { name .. ' <playerId|me>' }, 'error') end
	local id = target(source, args[1])
	if not id then return end
	local ok, result = Inv.WithLock(id, 10000, clearAll)
	if not ok then return reply(source, 'cmd_failed', { tostring(result) }, 'error') end
	Inv.Info(('staff %s cleared the inventory of player %d'):format(tostring(source), id))
	reply(source, 'cmd_cleared', { id, result }, 'success')
end

-- Read-only view of another player's pockets, in the staff member's menu.
function handlers.inventory(source, args, name)
	if source == 0 then return reply(source, 'cmd_in_game', nil, 'error') end
	if args.n < 1 then return reply(source, 'cmd_usage', { name .. ' <playerId>' }, 'error') end
	local id = target(source, args[1])
	if not id then return end
	local other = Inv.Get(id)
	if not other then return reply(source, 'cmd_failed', { 'not_loaded' }, 'error') end
	Inv.viewing[source] = { target = id, untilMs = Inv.Now() + 300000 }
	Inv.Info(('staff %d views the inventory of player %d'):format(source, id))
	TriggerClientEvent('opx_inventory:staffView', source, id, Inv.View(other.pockets))
end

function Inv.RegisterCommands()
	for key, handler in pairs(handlers) do
		local name = Config.commands and Config.commands[key]
		if type(name) == 'string' and name ~= '' then
			local ok, err = pcall(RegisterCommand, name, function(source, args)
				args = type(args) == 'table' and args or {}
				args.n = args.n or #args
				local caller = Inv.ToSource(source) or 0
				CreateThread(function()
					local fine, failure = pcall(handler, caller, args, name)
					if not fine then Inv.Error(('command %s raised: %s'):format(name, tostring(failure))) end
				end)
			end, true)
			if not ok then Inv.Warn(('command %s not registered: %s'):format(name, tostring(err))) end
		end
	end
end

-- Command help shown in opx_chat when it runs (optional: nothing happens without it). Chat is not a
-- provider slot, so opx_chat is named here; its export only describes the commands above.
local PLAYER = { name = { en = 'playerId|me', fr = 'idJoueur|me' } }
local COMMAND_HELP = {
	giveitem = { help = { en = 'Give an item to a player.', fr = 'Donner un objet à un joueur.' }, parameters = {
		PLAYER,
		{ name = { en = 'item', fr = 'objet' } },
		{ name = { en = 'count', fr = 'quantité' }, optional = true },
		{ name = { en = 'key=value ...', fr = 'clé=valeur ...' }, help = { en = 'Metadata of the item', fr = "Métadonnées de l'objet" }, optional = true },
	} },
	giveweapon = { help = { en = 'Give a weapon to a player.', fr = 'Donner une arme à un joueur.' }, parameters = {
		PLAYER,
		{ name = { en = 'weaponItem', fr = 'arme' }, help = { en = 'Weapon item id', fr = "Id de l'objet arme" } },
		{ name = { en = 'ammo', fr = 'munitions' }, optional = true },
	} },
	removeitem = { help = { en = 'Remove an item from a player.', fr = "Retirer un objet à un joueur." }, parameters = {
		PLAYER,
		{ name = { en = 'item', fr = 'objet' } },
		{ name = { en = 'count', fr = 'quantité' }, optional = true },
	} },
	clearinventory = { help = { en = 'Empty the inventory of a player.', fr = "Vider l'inventaire d'un joueur." }, parameters = { PLAYER } },
	inventory = { help = { en = "View a player's inventory (read-only).", fr = "Voir l'inventaire d'un joueur (lecture seule)." }, parameters = {
		{ name = { en = 'playerId', fr = 'idJoueur' } },
	} },
}

local function publishCommandHelp()
	if GetResourceState('opx_chat') ~= 'running' then return end
	for key, info in pairs(COMMAND_HELP) do
		local name = type(Config.commands) == 'table' and Config.commands[key]
		if type(name) == 'string' and name ~= '' then
			pcall(Open77.exports.callSync, 'opx_chat', 'SetCommandHelp', name, info.help, info.parameters)
		end
	end
end

AddEventHandler('onResourceStart', function(name)
	if name == GetCurrentResourceName() or name == 'opx_chat' then publishCommandHelp() end
end)
