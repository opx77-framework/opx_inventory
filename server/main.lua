-- Entry: storage start, character lifecycle, exports, the ammo sync loop.

-- Character lifecycle ----------------------------------------------------------------------

local function characterMeta(data)
	return {
		name = ('%s %s'):format(tostring(data.firstname or ''), tostring(data.lastname or '')):sub(1, 64),
		citizenId = data.citizenId,
		birthdate = type(data.birthdate) == 'string' and data.birthdate:sub(1, 10) or nil,
	}
end

local function forget(source, st)
	if Inv.players[source] == st then Inv.players[source] = nil end
	if Inv.owners[st.account] == source then Inv.owners[st.account] = nil end
	Stash.Close(st)
	local pockets = st.pockets
	st.pockets, st.ready = nil, false
	if pockets then Store.Release(pockets) end -- written now, forgotten once written
end

-- Starter items (Config.starterItems): given once per character, the marker `starterKit` lives in the
-- character's opx_core metadata, so a wiped inventory never gets a second kit. A row is skipped when the
-- pockets already hold that item (characters made before the kit existed). Synchronous: no wait between the
-- check, the gifts and the marker. A row whose item is not registered (yet) is skipped: there is no item config.
local function giveStarterKit(st)
	local rows = Config.starterItems
	if type(rows) ~= 'table' or not st.pockets then return end
	local ok, done, why = pcall(Open77.exports.callSync, 'opx_core', 'GetMetadata', st.source, 'starterKit')
	if not ok or why ~= nil then
		return Inv.Warn(('starter kit of %s skipped: opx_core did not answer (%s)'):format(st.cid, tostring(ok and why or done)))
	end
	if done == true then return end
	local given = 0
	for _, row in ipairs(rows) do
		local item = type(row) == 'table' and row.item or nil
		local count = type(row) == 'table' and Inv.ToCount(row.count or 1, 100) or nil
		if not count or type(item) ~= 'string' then
			Inv.Warn(('starter item %s skipped: bad row'):format(tostring(item)))
		elseif not Inv.Def(item) then
			Inv.Warn(('starter item %s skipped for %s: not registered by any resource'):format(item, st.cid))
		elseif Inv.CountOf(st.pockets, item) == 0 then
			local fine, err = Inv.AddTo(st, item, count, nil)
			if fine then given = given + 1
			else Inv.Warn(('starter item %s not given to %s: %s'):format(item, st.cid, tostring(err))) end
		end
	end
	local set, setOk, setWhy = pcall(Open77.exports.callSync, 'opx_core', 'SetMetadata', st.source, 'starterKit', true)
	if not set or setOk ~= true then
		Inv.Warn(('starter kit marker of %s not saved: %s'):format(st.cid, tostring(set and setWhy or setOk)))
	end
	if given > 0 then Inv.Info(('starter kit given to %s (%d rows)'):format(st.cid, given)) end
end

-- Loads the pockets and puts the equipped weapons back in the hands. Runs in a thread.
local function loadPlayer(source, data)
	local cid = type(data) == 'table' and data.citizenId
	if type(cid) ~= 'string' or not cid:match('^[A-Za-z0-9]+$') or cid:match('^%d+$') or #cid > 32 then return end
	local old = Inv.players[source]
	if old then forget(source, old) end
	local st = { source = source, cid = cid, account = 'char:' .. cid, ready = false, locked = true,
		characterMeta = characterMeta(data) }
	Inv.players[source] = st
	Inv.owners[st.account] = source

	CreateThread(function()
		while not Store.ready and Inv.players[source] == st do Wait(500) end
		local c
		for attempt = 1, 5 do
			if Inv.players[source] ~= st then return end
			local box = { done = false }
			Store.Acquire(st.account, function(container, why)
				box.c, box.why, box.done = container, why, true
			end)
			while not box.done do Wait(50) end
			if Inv.players[source] ~= st then
				if box.c then Store.Release(box.c) end
				return
			end
			c = box.c
			if c then break end
			Inv.Warn(('pockets of %s not loaded (%s), attempt %d'):format(cid, tostring(box.why), attempt))
			Wait(2000 * attempt)
		end
		if not c then
			Inv.Error(('pockets of %s not loaded: inventory unavailable for player %d'):format(cid, source))
			Inv.players[source] = nil
			if Inv.owners[st.account] == source then Inv.owners[st.account] = nil end
			return
		end
		c.capacityG, c.slots = Config.pockets.capacityG, Config.pockets.slots
		st.pockets, st.ready = c, true
		giveStarterKit(st)
		Weapons.Restore(st)
		st.locked = false
		if Inv.players[source] == st then
			TriggerClientEvent('opx_inventory:ready', source)
			Inv.SendCounts(source)
		end
	end)
end

local function unloadPlayer(source)
	local st = Inv.players[source]
	if not st then return end
	forget(source, st)
	Weapons.Drop(st)
end

AddEventHandler('opx:playerLoaded', function(playerId, data)
	local source = Inv.ToSource(playerId)
	if source then loadPlayer(source, data) end
end)

AddEventHandler('opx:playerUnloaded', function(playerId)
	local source = Inv.ToSource(playerId)
	if source then unloadPlayer(source) end
end)

AddEventHandler('onPlayerDisconnected', function(playerId)
	local source = Inv.ToSource(playerId)
	if not source then return end
	local st = Inv.players[source]
	if st then forget(source, st) end
	Inv.ForgetRate(source)
	Inv.ForgetCounts(source)
	Catalogue.Forget(source)
end)

-- Characters already loaded when this resource (re)starts.
local function adoptLoaded()
	local ok, list = pcall(Open77.exports.callSync, 'opx_core', 'GetPlayers')
	if not ok or type(list) ~= 'table' then return end
	for _, id in ipairs(list) do
		local source = Inv.ToSource(id)
		local fine, data = pcall(Open77.exports.callSync, 'opx_core', 'GetPlayer', source)
		if source and fine and type(data) == 'table' and not Inv.players[source] then loadPlayer(source, data) end
	end
end

AddEventHandler('onResourceStop', function(name)
	if name == Inv.RESOURCE then
		-- Only callback-form writes still work here.
		Store.FlushAll()
		return
	end
	-- Usables and item claims of a stopped resource, by VM generation: a reloaded resource's new VM may
	-- already have registered again before this notice arrives. The notice may also come while the stopping
	-- VM still answers its generation: checked again once it is gone.
	Catalogue.DropOwner(name)
	SetTimeout(1000, function() Catalogue.DropOwner(name) end)
end)

-- Ammo sync: armed players are read back every Config.weapons.syncSeconds, and right after their ammo
-- stack changed. Skipped while the player is busy.
CreateThread(function()
	while true do
		Wait(1000)
		local now = Inv.Now()
		for source, st in pairs(Inv.players) do
			local state = st.weapons
			if st.ready and not st.locked and state and state.ready and Weapons.HasAmmoWeapon(st) then
				local periodic = (Config.weapons.syncSeconds or 0) > 0 and now >= (state.nextSync or 0)
				if state.dirty or periodic then
					state.dirty = false
					CreateThread(function() Inv.WithLock(source, 0, Weapons.Reconcile) end)
				end
			end
		end
	end
end)

-- Exports ----------------------------------------------------------------------------------
-- All synchronous: they read and change memory and never wait (rows are written by a timer), so
-- exports.opx_inventory:Name(...) and Open77.exports.callSync work, from a thread or not.

local function itemOk(item) return type(item) == 'string' and Inv.Def(item) ~= nil end

local function rowsFor(c)
	local out = {}
	for _, row in ipairs(Inv.Rows(c)) do
		local def = Inv.Def(row.item)
		local entry = { item = row.item, count = row.count, instance = row.instance, weightG = def and def.weightG or nil }
		if row.instance then entry.meta = Inv.Copy(c.instances[row.instance].meta) end
		out[#out + 1] = entry
	end
	return out
end

local api = {}

-- true | false, reason
function api.AddItem(source, item, count, meta)
	local st = Inv.Get(Inv.ToSource(source))
	if not st then return false, Inv.ToSource(source) and 'not_loaded' or 'invalid_player' end
	if not itemOk(item) then return false, 'unknown_item' end
	count = Inv.ToCount(count or 1)
	if not count then return false, 'invalid_count' end
	local why
	if meta ~= nil then
		meta, why = Inv.CleanMeta(meta)
		if not meta then return false, why end
	end
	return Inv.AddTo(st, item, count, meta)
end

-- true | false, reason. An equipped weapon leaves the hands at once (magazine = last synced value).
function api.RemoveItem(source, item, count, instanceId)
	local st = Inv.Get(Inv.ToSource(source))
	if not st then return false, Inv.ToSource(source) and 'not_loaded' or 'invalid_player' end
	if type(item) ~= 'string' then return false, 'unknown_item' end
	count = Inv.ToCount(count or 1)
	if not count then return false, 'invalid_count' end
	if instanceId ~= nil and type(instanceId) ~= 'string' then return false, 'not_found' end
	if instanceId then count = 1 end
	return Inv.RemoveFrom(st, item, count, instanceId)
end

-- { { item, count, instance?, meta?, weightG? }, ... } | nil, reason
function api.GetItems(source)
	local st = Inv.Get(Inv.ToSource(source))
	if not st then return nil, 'not_loaded' end
	return rowsFor(st.pockets)
end

-- { item, count, instances = { [instanceId] = meta } } | nil, reason
function api.GetItem(source, item)
	local st = Inv.Get(Inv.ToSource(source))
	if not st then return nil, 'not_loaded' end
	if type(item) ~= 'string' then return nil, 'unknown_item' end
	local instances = {}
	for _, rec in ipairs(Inv.InstancesOf(st.pockets, item)) do instances[rec.id] = Inv.Copy(rec.meta) end
	return { item = item, count = Inv.CountOf(st.pockets, item), instances = instances }
end

-- boolean
function api.HasItem(source, item, count)
	local st = Inv.Get(Inv.ToSource(source))
	if not st or type(item) ~= 'string' then return false end
	return Inv.CountOf(st.pockets, item) >= (Inv.ToCount(count or 1) or 1)
end

-- true | false, reason ('too_heavy', 'no_slot', 'max_stack', 'unknown_item', 'not_loaded')
function api.CanCarry(source, item, count)
	local st = Inv.Get(Inv.ToSource(source))
	if not st then return false, 'not_loaded' end
	if not itemOk(item) then return false, 'unknown_item' end
	count = Inv.ToCount(count or 1)
	if not count then return false, 'invalid_count' end
	local def = Inv.Def(item)
	return Inv.Fits(st.pockets, item, count, def.unique)
end

local RESERVED = { equipped = true, serial = true, ammo = true }

-- true | false, reason. Shallow merge; weapon keys (equipped, serial, ammo) are the inventory's.
function api.SetItemMeta(source, instanceId, metaPatch)
	local st = Inv.Get(Inv.ToSource(source))
	if not st then return false, Inv.ToSource(source) and 'not_loaded' or 'invalid_player' end
	if type(instanceId) ~= 'string' then return false, 'not_found' end
	local patch, why = Inv.CleanMeta(metaPatch)
	if not patch or not next(patch) then return false, why or 'invalid_meta' end
	for key in pairs(patch) do
		if RESERVED[key] then return false, 'reserved_key' end
	end
	return Inv.PatchMeta(st.pockets, instanceId, patch)
end

-- true | false, reason. No distance check: the calling resource decided. An equipped weapon given away
-- leaves the hands at once.
function api.GiveItemTo(source, target, item, count, instanceId)
	source, target = Inv.ToSource(source), Inv.ToSource(target)
	if not source or not target then return false, 'invalid_player' end
	local st = Inv.Get(source)
	if not st then return false, 'not_loaded' end
	if type(item) ~= 'string' then return false, 'unknown_item' end
	count = Inv.ToCount(count or 1)
	if not count then return false, 'invalid_count' end
	if instanceId ~= nil and type(instanceId) ~= 'string' then return false, 'not_found' end
	if instanceId then count = 1 end
	return Inv.GiveTo(st, target, item, count, instanceId)
end

-- true | false, reason. Cash (Config.cash.account) from one loaded character to another through opx_core's
-- TransferMoney, all or nothing. No distance check: the calling resource decided.
function api.GiveCash(source, target, amount)
	return Inv.GiveCash(source, target, amount)
end

-- true | false, reason. The CALLER's export `exportName(source, item, instanceId, meta)` runs when
-- a player uses the item; it returns true to consume one. Removed when the caller stops. A handler makes the
-- item usable (menu "Use") even without `usable = true` in the catalogue. It is the only way an item has an
-- effect: the inventory has none of its own.
function api.RegisterUsable(item, exportName)
	local owner = GetInvokingResource()
	if not owner then return false, 'export_call_required' end
	if not itemOk(item) then return false, 'unknown_item' end
	if type(exportName) ~= 'string' or not exportName:match('^[%a_][%w_]*$') or #exportName > 64 then
		return false, 'invalid_export'
	end
	local existing = Inv.usables[item]
	if existing and existing.resource ~= owner then
		Inv.Warn(('usable %s moved from %s to %s'):format(item, existing.resource, owner))
	end
	local changed = not existing
	Inv.usables[item] = { resource = owner, export = exportName,
		generation = GetInvokingResourceGeneration() or Open77.resource.generation(owner) }
	if changed then Catalogue.Changed() end -- clients show "Use" for it
	return true
end

-- true | false, reason. Shows the stash (put / take) to the player; when nobody had it open it appears as
-- soon as its row is read.
function api.OpenStash(source, name, options)
	source = Inv.ToSource(source)
	if not source then return false, 'invalid_player' end
	return Stash.Open(source, name, options)
end

-- { item, label, description?, weightG, unique, usable, maxStack?, weapon, showable, resource } | nil. A copy
-- of the catalogue entry; label / description as registered (a string or { en, fr }). usable is true too when a
-- RegisterUsable handler exists; resource = the owner that registered it. Optional member of the contract.
function api.GetItemDefinition(item)
	local def = Inv.Def(item)
	if not def then return nil end
	return {
		item = item,
		label = Inv.Copy(def.label) or item,
		description = Inv.Copy(def.description),
		weightG = def.weightG,
		unique = def.unique,
		usable = def.usable or Inv.usables[item] ~= nil,
		maxStack = def.maxStack,
		weapon = def.weapon ~= nil,
		showable = def.showable == true,
		resource = def.resource,
	}
end

-- Sorted ids of the whole catalogue. Optional member of the inventory contract.
function api.GetItemNames()
	return Catalogue.Names()
end

-- true | false, reason. Adds an item to the catalogue, owned by the caller (it registers again on each start
-- and on this resource's onResourceStart). Optional member.
function api.RegisterItem(item, definition)
	return Catalogue.Register(item, definition)
end

-- true | false, reason. Removes an item the caller registered. Optional member.
function api.UnregisterItem(item)
	return Catalogue.Unregister(item)
end

for name, fn in pairs(api) do
	local ok, reason = exports(name, fn)
	if not ok then Inv.Error(('export %s not registered: %s'):format(name, tostring(reason))) end
end

-- Start ------------------------------------------------------------------------------------

-- opx_inventory's own items: the ID card, filled from the character that receives it.
Catalogue.RegisterOwn('id_card', {
	label = { en = 'ID card', fr = "Carte d'identité" },
	description = { en = 'Night City identity card.', fr = "Carte d'identité de Night City." },
	weightG = 10, unique = true, showable = true, characterMeta = true,
})
Inv.RegisterCommands()
Store.Start(function()
	-- After a hot reload the previous VM's last writes were just sent: give them a moment to land.
	SetTimeout(1500, adoptLoaded)
end)
