-- Weapons are client-owned game state: the server asks (Open77.weapons.*) and learns the outcome on
-- open77:weapons:completed. A weapon item is a unique instance, meta { serial, ammo (magazine), equipped }.
-- The ammo reserve is the stack of the weapon's ammo item. Client-reported ammo is only believed when it
-- went DOWN: rounds leave the reserve (fired, or loaded into a magazine), a magazine may only grow by what
-- left the reserve. Equip / Unequip / Reconcile / Restore wait for the game (lock held by the caller);
-- after every wait they read the containers again, since a synchronous export may have changed them.
-- Release and CheckAmmo never wait. weapon (TweakDB record) and ammo are read from the runtime catalogue
-- (RegisterItem): a weapon equipped at the last unload whose item is not registered yet when the pockets load
-- waits for its RegisterItem (Weapons.ItemRegistered) and goes back in the hands then.

Weapons = {}

local WAIT_MS = 15000 -- the platform answers request_timeout after 10 s; this is the backstop

local pending = {} -- [requestId] = box waiting for its completion

AddEventHandler('open77:weapons:completed', function(playerId, requestId, operation, accepted, reason, result)
	local box = pending[tostring(requestId)]
	if not box then return end
	pending[tostring(requestId)] = nil
	box.accepted = accepted == true or accepted == 'true'
	box.reason, box.result, box.done = reason, result, true
end)

-- Sends one weapons request and waits for its verdict: true, result | false, reason.
local function request(fn, source, ...)
	local requestId, why = fn(source, ...)
	if not requestId then return false, why end
	local key = tostring(requestId)
	local box = { done = false }
	pending[key] = box
	local deadline = Inv.Now() + WAIT_MS
	while not box.done and Inv.Now() < deadline do Wait(50) end
	pending[key] = nil
	if not box.done then return false, 'request_timeout' end
	if not box.accepted then return false, tostring(box.reason or 'refused') end
	return true, box.result
end

-- A count the client reported (-1 or junk = unknown): integer >= 0, or nil.
local function reported(value)
	local n = Inv.ToInteger(value)
	if not n or n < 0 or n > 1000000 then return nil end
	return n
end

local function ammoOf(row)
	if type(row) ~= 'table' then return {} end
	local ammo = type(row.ammo) == 'table' and row.ammo or row
	return { reserve = reported(ammo.reserve), magazine = reported(ammo.magazine), capacity = reported(ammo.capacity) }
end

function Weapons.State(st)
	st.weapons = st.weapons or { slots = {}, synced = {}, waiting = {}, dirty = false, nextSync = 0 }
	return st.weapons
end

function Weapons.IsEquipped(st, instanceId)
	for _, entry in pairs(Weapons.State(st).slots) do
		if entry.instance == instanceId then return true end
	end
	return false
end

function Weapons.HasAmmoWeapon(st)
	for _, entry in pairs(Weapons.State(st).slots) do
		if entry.ammo then return true end
	end
	return false
end

local function freeSlot(st, preferred)
	local slots = Weapons.State(st).slots
	if preferred and not slots[preferred] then
		for _, n in ipairs(Config.weapons.slots) do if n == preferred then return n end end
	end
	for _, n in ipairs(Config.weapons.slots) do
		if not slots[n] then return n end
	end
	return nil
end

-- setAmmo with the whole reserve of that ammo type and the stored magazine (capped by the live capacity).
-- A refused magazine is retried as reserve only (the call fails as a whole on a too-big magazine).
local function loadAmmo(st, slot, entry, capacity)
	local reserve = Inv.StackOf(st.pockets, entry.ammo)
	local magazine = math.min(entry.mag, capacity or 0)
	local amounts = { reserve = reserve }
	if magazine > 0 then amounts.magazine = magazine end
	local ok, why = request(Open77.weapons.setAmmo, st.source, slot, amounts)
	if not ok and amounts.magazine then
		ok, why = request(Open77.weapons.setAmmo, st.source, slot, { reserve = reserve })
	end
	if not ok then Inv.Warn(('ammo of player %d slot %d not set: %s'):format(st.source, slot, tostring(why))) end
	entry.mag = magazine
	local state = Weapons.State(st)
	state.synced[entry.ammo] = reserve
	state.nextSync = Inv.Now() + math.max(1, Config.weapons.syncSeconds or 60) * 1000
end

-- Puts a weapon instance from the pockets in the player's hands. true, or false, reason.
function Weapons.Equip(st, instanceId, preferredSlot)
	local c = st.pockets
	local rec = type(instanceId) == 'string' and c.instances[instanceId]
	if not rec then return false, 'not_found' end
	local def = Inv.Def(rec.item)
	if not def or not def.weapon then return false, 'not_a_weapon' end
	if Weapons.IsEquipped(st, instanceId) then return false, 'already_equipped' end
	local slot = freeSlot(st, preferredSlot)
	if not slot then return false, 'no_weapon_slot' end

	-- The ammo item may be registered after the weapon (its stack is counted all the same), never a unique item.
	local ammo = def.ammo
	local ammoDef = ammo and Inv.Def(ammo)
	if ammoDef and ammoDef.unique then
		Inv.Warn(('item %s: ammo %s is a unique item, ignored'):format(rec.item, ammo))
		ammo = nil
	end
	local entry = { instance = instanceId, item = rec.item, record = def.weapon, ammo = ammo,
		mag = math.max(0, Inv.ToInteger(rec.meta.ammo) or 0) }
	local slots = Weapons.State(st).slots
	slots[slot] = entry -- taken now, so the hardening below never strips it mid-handshake

	local ok, result = request(Open77.weapons.assign, st.source, def.weapon, slot, { active = true })
	if not ok then
		if slots[slot] == entry then slots[slot] = nil end
		Inv.Warn(('equip %s for player %d refused: %s'):format(def.weapon, st.source, tostring(result)))
		return false, 'equip_failed'
	end
	if Inv.players[st.source] ~= st then return false, 'not_loaded' end
	-- Released meanwhile (given away, destroyed by an export): Release already emptied the slot.
	if slots[slot] ~= entry then return false, 'not_found' end
	if entry.ammo then loadAmmo(st, slot, entry, ammoOf(result).capacity) end
	if Inv.players[st.source] ~= st then return false, 'not_loaded' end

	rec = c.instances[instanceId]
	if slots[slot] ~= entry or not rec then
		if slots[slot] == entry then
			slots[slot] = nil
			pcall(Open77.weapons.remove, st.source, slot)
		end
		return false, 'not_found'
	end
	rec.meta.equipped, rec.meta.ammo = slot, entry.mag
	Inv.Touch(c)
	return true
end

-- Takes a weapon out of the hands at once, without waiting for the game or reading its ammo back (a
-- synchronous export moved or destroyed it). The magazine keeps its last synced value.
function Weapons.Release(st, instanceId)
	local state = Weapons.State(st)
	for slot, entry in pairs(state.slots) do
		if entry.instance == instanceId then
			state.slots[slot] = nil
			pcall(Open77.weapons.remove, st.source, slot)
			if entry.ammo then
				local still = false
				for _, other in pairs(state.slots) do if other.ammo == entry.ammo then still = true end end
				if not still then state.synced[entry.ammo] = nil end
			end
		end
	end
end

-- The ammo stack of an equipped weapon changed (bought, given, removed): sync on the next loop pass.
function Weapons.CheckAmmo(st)
	local state = st.weapons
	if not state or not next(state.synced) then return end
	for ammo, synced in pairs(state.synced) do
		if Inv.StackOf(st.pockets, ammo) ~= synced then state.dirty = true end
	end
end

-- Reads the real ammo back (snapshot), empties opts.remove (unequip), then in one step: burns the spent
-- rounds from the ammo stack, writes the magazines and opts.patches; then gives the game the new reserve.
function Weapons.Reconcile(st, opts)
	opts = opts or {}
	local state = Weapons.State(st)
	state.dirty = false
	state.nextSync = Inv.Now() + math.max(1, Config.weapons.syncSeconds or 60) * 1000
	local patches = opts.patches or {}

	-- What is in the hands now; checked again after each wait.
	local entries = {}
	for slot, entry in pairs(state.slots) do entries[slot] = entry end

	local rows = {}
	if Weapons.HasAmmoWeapon(st) then
		local ok, result = request(Open77.weapons.requestSnapshot, st.source)
		if ok and type(result) == 'table' then
			for _, row in ipairs(result) do
				local n = type(row) == 'table' and reported(row.slot)
				if n then rows[n] = row end
			end
		end
	end
	if Inv.players[st.source] ~= st then return false, 'not_loaded' end

	-- Unequip: the slot is emptied before anything is written.
	if opts.remove then
		local ok, why = request(Open77.weapons.remove, st.source, opts.remove)
		if not ok and why ~= 'weapon_slot_empty' then return false, 'unequip_failed' end
		if Inv.players[st.source] ~= st then return false, 'not_loaded' end
	end

	-- No wait from here to the writes: memory is read and changed in one step.
	local c = st.pockets
	local byAmmo = {}
	for slot, entry in pairs(entries) do
		if entry.ammo and state.slots[slot] == entry then
			byAmmo[entry.ammo] = byAmmo[entry.ammo] or {}
			table.insert(byAmmo[entry.ammo], slot)
		end
	end

	local changed = false
	local reserves = {}
	for ammoItem, slotList in pairs(byAmmo) do
		table.sort(slotList)
		local synced = state.synced[ammoItem]
		-- The reserve: the active weapon's, else the lowest one reported.
		local reserve
		for _, slot in ipairs(slotList) do
			local row, a = rows[slot], ammoOf(rows[slot])
			if a.reserve and row and (row.active == true or row.active == 'true') then reserve = a.reserve end
		end
		if not reserve then
			for _, slot in ipairs(slotList) do
				local r = ammoOf(rows[slot]).reserve
				if r and (not reserve or r < reserve) then reserve = r end
			end
		end
		if synced and reserve then
			local drop = math.max(0, synced - reserve)
			local budget = drop
			for _, slot in ipairs(slotList) do
				local entry, a = state.slots[slot], ammoOf(rows[slot])
				if a.magazine then
					local mag = a.magazine
					if mag > entry.mag then
						local grow = math.min(mag - entry.mag, budget)
						budget = budget - grow
						mag = entry.mag + grow
					end
					if a.capacity then mag = math.min(mag, a.capacity) end
					if mag ~= entry.mag then
						entry.mag = mag
						patches[entry.instance] = patches[entry.instance] or {}
						patches[entry.instance].ammo = mag
					end
				end
			end
			local stack = Inv.StackOf(c, ammoItem)
			local burn = math.min(stack, drop)
			if burn > 0 then
				c.stacks[ammoItem] = stack - burn > 0 and stack - burn or nil
				changed = true
			end
			reserves[ammoItem] = { value = stack - burn, game = reserve }
		elseif synced == nil then
			-- Never synced (the first load failed): push our reserve.
			reserves[ammoItem] = { value = Inv.StackOf(c, ammoItem), game = reserve }
		end
	end

	for id, patch in pairs(patches) do
		local rec = c.instances[id]
		if rec then
			for k, v in pairs(patch) do rec.meta[k] = v end
			changed = true
		end
	end
	if opts.remove and state.slots[opts.remove] == entries[opts.remove] then state.slots[opts.remove] = nil end
	if changed then Inv.Touch(c) end

	-- Give the game the new reserve (one slot per ammo type is enough: the reserve is shared).
	for ammoItem, r in pairs(reserves) do
		local target
		for _, slot in ipairs(byAmmo[ammoItem]) do
			if state.slots[slot] then target = target or slot end
		end
		if not target then
			state.synced[ammoItem] = nil
		elseif r.value ~= r.game then
			local set = request(Open77.weapons.setAmmo, st.source, target, { reserve = r.value })
			state.synced[ammoItem] = set and r.value or state.synced[ammoItem]
		else
			state.synced[ammoItem] = r.value
		end
	end
	state.dirty = false
	Weapons.CheckAmmo(st) -- a stack that changed during the last waits is synced next pass
	return true
end

-- Takes a weapon out of the hands: ammo written back, slot emptied, meta equipped = false.
function Weapons.Unequip(st, instanceId)
	local slot
	for n, entry in pairs(Weapons.State(st).slots) do
		if entry.instance == instanceId then slot = n end
	end
	if not slot then return false, 'not_equipped' end
	return Weapons.Reconcile(st, { remove = slot, patches = { [instanceId] = { equipped = false } } })
end

-- Character load: empty every slot, then equip again what the inventory says was equipped. An item not
-- registered yet keeps its marker and waits for its RegisterItem (state.waiting).
function Weapons.Restore(st)
	local state = Weapons.State(st)
	state.slots, state.synced, state.waiting = {}, {}, {}
	local wanted = {}
	for id, rec in pairs(st.pockets.instances) do
		local slot = Inv.ToInteger(rec.meta.equipped)
		if slot and not Inv.Def(rec.item) then
			state.waiting[id] = slot
		elseif slot then
			wanted[#wanted + 1] = { id = id, slot = slot }
		end
	end
	local ok, why = request(Open77.weapons.clear, st.source)
	if not ok then Inv.Warn(('weapons of player %d not cleared: %s'):format(st.source, tostring(why))) end
	if Inv.players[st.source] ~= st then return end
	table.sort(wanted, function(a, b) return a.slot < b.slot end)
	local stale = false
	for _, w in ipairs(wanted) do
		local done = Weapons.Equip(st, w.id, w.slot)
		if Inv.players[st.source] ~= st then return end
		local rec = st.pockets.instances[w.id]
		if not done and rec then
			rec.meta.equipped = false
			stale = true
		end
	end
	if stale then Inv.Touch(st.pockets) end
	state.ready = true
end

-- A weapon item was registered (or registered again): instances waiting since the pockets loaded are equipped
-- in their slot, under each player's lock (from a thread). One that cannot be equipped loses its marker.
local function equipWaiting(st, item)
	local waiting = st.weapons and st.weapons.waiting
	if not waiting then return end
	local stale = false
	for id, slot in pairs(waiting) do
		local rec = st.pockets.instances[id]
		if not rec then
			waiting[id] = nil
		elseif rec.item == item then
			waiting[id] = nil
			local done = Weapons.Equip(st, id, slot)
			if Inv.players[st.source] ~= st then return end
			rec = st.pockets.instances[id]
			if not done and rec and rec.meta.equipped then
				rec.meta.equipped = false
				stale = true
			end
		end
	end
	if stale then Inv.Touch(st.pockets) end
end

function Weapons.ItemRegistered(item)
	for source, st in pairs(Inv.players) do
		local waiting = st.weapons and st.weapons.waiting
		local wants = false
		for id in pairs(waiting or {}) do
			local rec = st.pockets and st.pockets.instances[id]
			if rec and rec.item == item then wants = true end
		end
		if wants then
			CreateThread(function()
				local ok, why = Inv.WithLock(source, 30000, equipWaiting, item)
				if ok == false and why then Inv.Warn(('waiting %s of player %d not equipped: %s'):format(item, source, why)) end
			end)
		end
	end
end

-- Character unload: the hands are emptied (best effort, nothing waits for it).
function Weapons.Drop(st)
	if st.weapons then st.weapons.ready = false end
	pcall(Open77.weapons.clear, st.source)
end

-- Hardening: a weapon appearing in a slot this resource did not fill is removed and logged.
AddEventHandler('onPlayerWeaponChanged', function(playerId, slot, record)
	if not Config.weapons.stripUnknown then return end
	local source = Inv.ToSource(playerId)
	local st = source and Inv.Get(source)
	if not st or st.locked or not st.weapons or not st.weapons.ready then return end
	local n = Inv.ToInteger(slot)
	if not n or n < 1 or n > 6 or type(record) ~= 'string' or record == '' then return end
	if st.weapons.slots[n] then return end
	Inv.Warn(('player %d holds %s in slot %d without the item: removed'):format(source, record:sub(1, 80), n))
	pcall(Open77.weapons.remove, source, n)
end)
