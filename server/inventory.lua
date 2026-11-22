-- Containers (pockets char:<citizenId>, stashes stash:<name>) and the moves between them. Everything here
-- is synchronous: it reads and changes the containers in memory (server/storage.lua writes them out).
-- A move between two containers is one Lua step, so it cannot half-happen.

local MAX_INSTANCES = 50 -- unique items given / moved by count in one action

Inv.owners = {} -- ['char:<cid>'] = source

-- Player state ---------------------------------------------------------------------------

function Inv.Get(source)
	local st = source and Inv.players[source]
	if st and st.ready and st.pockets then return st end
	return nil
end

-- The player lock only serialises what really waits: the weapon handshakes with the game
-- (open77:weapons:completed). `wait` = how long to queue (ms); 0 answers 'busy' at once.
function Inv.Lock(st, wait)
	local deadline = Inv.Now() + (wait or 10000)
	while st.locked do
		if Inv.Now() >= deadline then return false end
		Wait(50)
	end
	st.locked = true
	return true
end

function Inv.Unlock(st)
	st.locked = false
end

-- Runs fn(st, ...) under the player's lock (from a thread): fn's results, or false, reason.
function Inv.WithLock(source, wait, fn, ...)
	local st = Inv.Get(source)
	if not st then return false, 'not_loaded' end
	if not Inv.Lock(st, wait) then return false, 'busy' end
	local results = table.pack(pcall(fn, st, ...))
	Inv.Unlock(st)
	if not results[1] then
		Inv.Error('action raised: ' .. tostring(results[2]))
		return false, 'internal_error'
	end
	return table.unpack(results, 2, results.n)
end

-- Contents -------------------------------------------------------------------------------

function Inv.StackOf(c, item)
	return c.stacks[item] or 0
end

-- Instances of one item, sorted by id: { { id, meta }, ... }.
function Inv.InstancesOf(c, item)
	local out = {}
	for id, rec in pairs(c.instances) do
		if rec.item == item then out[#out + 1] = { id = id, meta = rec.meta } end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

function Inv.CountOf(c, item)
	return Inv.StackOf(c, item) + #Inv.InstancesOf(c, item)
end

function Inv.UsedSlots(c)
	local used = 0
	for _, n in pairs(c.stacks) do if n > 0 then used = used + 1 end end
	for _ in pairs(c.instances) do used = used + 1 end
	return used
end

-- Grams carried (an item no longer in the catalogue weighs nothing).
function Inv.Weight(c)
	local total = 0
	for item, n in pairs(c.stacks) do
		local def = Inv.items[item]
		if def then total = total + def.weightG * n end
	end
	for _, rec in pairs(c.instances) do
		local def = Inv.items[rec.item]
		if def then total = total + def.weightG end
	end
	return total
end

-- Whether `count` more of `item` fit (asInstances: each one takes a slot). true, or false, reason.
function Inv.Fits(c, item, count, asInstances)
	local def = Inv.Def(item)
	if not def then return false, 'unknown_item' end
	if Inv.Weight(c) + def.weightG * count > c.capacityG then return false, 'too_heavy' end
	local newSlots = asInstances and count or (Inv.StackOf(c, item) > 0 and 0 or 1)
	if Inv.UsedSlots(c) + newSlots > c.slots then return false, 'no_slot' end
	if def.maxStack and Inv.CountOf(c, item) + count > def.maxStack then return false, 'max_stack' end
	return true
end

-- Changes ---------------------------------------------------------------------------------

-- After a change: the row is written soon, and the views showing it are refreshed (batched).
local touched, flushQueued = {}, false

local function flush()
	flushQueued = false
	local list = touched
	touched = {}
	for id in pairs(list) do
		if id:sub(1, 5) == 'char:' then
			local st = Inv.Get(Inv.owners[id])
			if st then
				if st.viewOpen then Inv.SendView(st) end
				if st.stash then Stash.SendView(st) end
				Weapons.CheckAmmo(st)
			end
		elseif id:sub(1, 6) == 'stash:' then
			Stash.Refresh(id:sub(7))
		end
	end
end

-- Client counts: the public client net event opx:inventory:counts (counts) carries the whole table
-- { [item] = total } of the pockets, sent when they load and after any change, at most once per COUNTS_MS
-- per player. A snapshot, never a delta: clearinventory and burnt ammo cannot drift it.
local COUNTS_MS = 250
local COUNTS_MAX = 400 -- entries per snapshot (keeps the event far under the 48 KiB payload limit)
local countsQueued, countsSent = {}, {} -- [source] = true / ms of the last send

function Inv.Counts(c)
	local out, n = {}, 0
	local function add(item, count)
		if out[item] == nil then
			if n >= COUNTS_MAX or #item > 64 then return end
			n = n + 1
			out[item] = 0
		end
		out[item] = out[item] + count
	end
	for item, count in pairs(c.stacks) do
		if math.type(count) == 'integer' and count > 0 then add(item, count) end
	end
	for _, rec in pairs(c.instances) do add(rec.item, 1) end
	return out
end

-- Sends the counts now (pockets loaded, client hello).
function Inv.SendCounts(source)
	countsQueued[source] = nil
	local st = Inv.Get(source)
	if not st then return end
	countsSent[source] = Inv.Now()
	TriggerClientEvent('opx:inventory:counts', source, Inv.Counts(st.pockets))
end

function Inv.QueueCounts(source)
	source = Inv.ToSource(source)
	if not source or countsQueued[source] then return end
	countsQueued[source] = true
	local wait = math.max(50, (countsSent[source] or -COUNTS_MS) + COUNTS_MS - Inv.Now())
	SetTimeout(wait, function()
		if countsQueued[source] then Inv.SendCounts(source) end
	end)
end

function Inv.ForgetCounts(source)
	countsQueued[source], countsSent[source] = nil, nil
end

function Inv.Touch(c)
	Store.MarkDirty(c)
	if c.id:sub(1, 5) == 'char:' and Inv.owners[c.id] then Inv.QueueCounts(Inv.owners[c.id]) end
	touched[c.id] = true
	if not flushQueued then
		flushQueued = true
		SetTimeout(50, flush)
	end
end

-- What to take for `count` of `item` (or the instance asked): { item, count, ids? } or nil, reason.
-- A stack when there is one, else instances, unequipped first (a give by count leaves the gun in hand).
function Inv.Pick(c, item, count, instanceId)
	if instanceId then
		local rec = type(instanceId) == 'string' and c.instances[instanceId]
		if not rec or rec.item ~= item then return nil, 'not_found' end
		return { item = item, count = 1, ids = { instanceId } }
	end
	local def = Inv.Def(item)
	if not (def and def.unique) and Inv.StackOf(c, item) > 0 then
		if Inv.StackOf(c, item) < count then return nil, 'not_enough' end
		return { item = item, count = count }
	end
	if count > MAX_INSTANCES then return nil, 'too_many' end
	local list = Inv.InstancesOf(c, item)
	table.sort(list, function(a, b)
		local ea, eb = a.meta.equipped and 1 or 0, b.meta.equipped and 1 or 0
		if ea ~= eb then return ea < eb end
		return a.id < b.id
	end)
	if #list < count then return nil, 'not_enough' end
	local ids = {}
	for i = 1, count do ids[i] = list[i].id end
	return { item = item, count = count, ids = ids }
end

-- Takes a picked selection out of `c`: the instance records (nil for a stack).
local function detach(c, sel)
	if not sel.ids then
		local left = Inv.StackOf(c, sel.item) - sel.count
		c.stacks[sel.item] = left > 0 and left or nil
		return nil
	end
	local recs = {}
	for i, id in ipairs(sel.ids) do
		local rec = c.instances[id]
		c.instances[id] = nil
		-- A weapon never travels (or stays stored) marked as equipped.
		if rec.meta.equipped ~= nil then rec.meta.equipped = false end
		recs[i] = rec
	end
	return recs
end

local function attach(c, sel, recs)
	if not recs then
		c.stacks[sel.item] = Inv.StackOf(c, sel.item) + sel.count
		return
	end
	for i, id in ipairs(sel.ids) do c.instances[id] = recs[i] end
end

-- Weapons among a selection that are in the owner's hands leave them at once (no wait).
local function releaseWeapons(st, sel)
	if not st or not sel.ids then return end
	for _, id in ipairs(sel.ids) do
		if Weapons.IsEquipped(st, id) then Weapons.Release(st, id) end
	end
end

-- Metadata a new instance starts with: the caller's (cleaned), plus the weapon keys. nil, reason if too big.
local function newMeta(def, meta, instanceId)
	local out = Inv.Copy(meta) or {}
	if def.weapon then
		out.serial = type(out.serial) == 'string' and out.serial or instanceId:match('_([%w]+)$'):upper()
		out.ammo = Inv.ToInteger(out.ammo) or 0
		out.equipped = false
	end
	return Inv.CleanMeta(out)
end

-- Creates `count` of `item` in `c`. meta (already cleaned) makes each one an instance.
function Inv.Add(c, item, count, meta)
	local def = Inv.Def(item)
	if not def then return false, 'unknown_item' end
	local asInstances = def.unique or meta ~= nil
	if asInstances and count > MAX_INSTANCES then return false, 'too_many' end
	local fits, why = Inv.Fits(c, item, count, asInstances)
	if not fits then return false, why end
	if not asInstances then
		c.stacks[item] = Inv.StackOf(c, item) + count
	else
		local created = {}
		for i = 1, count do
			local id = Inv.NewInstanceId(item)
			local m, err = newMeta(def, meta, id)
			if not m then return false, err end
			created[i] = { id = id, rec = { item = item, meta = m } }
		end
		for _, entry in ipairs(created) do c.instances[entry.id] = entry.rec end
	end
	Inv.Touch(c)
	return true
end

-- Destroys from `c`. st = owner of the pockets (their equipped weapons leave the hands first).
function Inv.Remove(c, item, count, instanceId, st)
	local sel, why = Inv.Pick(c, item, count, instanceId)
	if not sel then return false, why end
	releaseWeapons(st, sel)
	detach(c, sel)
	Inv.Touch(c)
	return true
end

-- `from` -> `to` in one step. st = owner of `from` when it is pockets. prefix: 'target_' for a refusal of
-- the receiving side seen from the giver.
function Inv.Move(from, to, item, count, instanceId, st, prefix)
	if from == to then return false, 'invalid_target' end
	local sel, why = Inv.Pick(from, item, count, instanceId)
	if not sel then return false, why end
	local fits, err = Inv.Fits(to, item, sel.count, sel.ids ~= nil)
	if not fits then return false, (prefix or '') .. err end
	releaseWeapons(st, sel)
	attach(to, sel, detach(from, sel))
	Inv.Touch(from)
	Inv.Touch(to)
	Inv.PocketsChanged(from, item, -sel.count)
	Inv.PocketsChanged(to, item, sel.count)
	return true
end

-- Shallow merge into an instance. The result must stay valid metadata (<= 2048 bytes, depth 4).
function Inv.PatchMeta(c, instanceId, patch)
	local rec = c.instances[instanceId]
	if not rec then return false, 'not_found' end
	local merged = Inv.Copy(rec.meta)
	for k, v in pairs(patch) do merged[k] = v end
	local clean, why = Inv.CleanMeta(merged)
	if not clean then return false, why end
	rec.meta = clean
	Inv.Touch(c)
	return true
end

-- Player-level ----------------------------------------------------------------------------------

-- The player whose loaded pockets `c` is, or nil (a stash, or pockets being forgotten).
local function pocketsOwner(c)
	if type(c) ~= 'table' or type(c.id) ~= 'string' or c.id:sub(1, 5) ~= 'char:' then return nil end
	local source = Inv.owners[c.id]
	local st = source and Inv.players[source]
	if st and st.pockets == c then return source end
	return nil
end

-- Host event opx:inventory:changed (source, item, delta): one per change of a loaded character's pockets,
-- after the change (Inv.Move calls it for both sides). A listener's error never reaches the caller.
function Inv.PocketsChanged(c, item, delta)
	local source = pocketsOwner(c)
	if not source or delta == 0 then return end
	local ok, err = pcall(TriggerEvent, 'opx:inventory:changed', source, item, delta)
	if not ok then Inv.Warn('opx:inventory:changed raised: ' .. tostring(err)) end
end

function Inv.AddTo(st, item, count, meta)
	if not st or not st.pockets then return false, 'not_loaded' end
	local def = Inv.Def(item)
	if not def then return false, 'unknown_item' end
	if def.characterMeta and meta == nil then meta = st.characterMeta end
	local ok, why = Inv.Add(st.pockets, item, count, meta)
	if ok then Inv.PocketsChanged(st.pockets, item, count) end
	return ok, why
end

function Inv.RemoveFrom(st, item, count, instanceId)
	if not st or not st.pockets then return false, 'not_loaded' end
	local pockets = st.pockets
	local ok, why = Inv.Remove(pockets, item, count, instanceId, st)
	if ok then Inv.PocketsChanged(pockets, item, -(instanceId and 1 or count)) end
	return ok, why
end

-- Equipped weapons about to leave the pockets are put away first, with their ammo written back
-- (Weapons.Unequip waits for the game: from a thread, lock held). Callers that cannot wait skip this and
-- the move releases them at once.
function Inv.UnequipLeaving(st, item, count, instanceId)
	if not st.pockets then return false, 'not_loaded' end
	local def = Inv.Def(item)
	if not def or not def.weapon then return true end
	local sel = Inv.Pick(st.pockets, item, count, instanceId)
	for _, id in ipairs(sel and sel.ids or {}) do
		if Weapons.IsEquipped(st, id) then
			local ok, why = Weapons.Unequip(st, id)
			if not ok then return false, why end
		end
	end
	return true
end

-- Views (what the client menu shows) ------------------------------------------------------

-- Rows of a container: stacks { item, count } and instances { item, instance, info }. Sorted by item, id.
function Inv.Rows(c)
	local rows = {}
	for item, n in pairs(c.stacks) do
		if n > 0 then rows[#rows + 1] = { item = item, count = n } end
	end
	for id, rec in pairs(c.instances) do
		local meta = rec.meta
		local info = {}
		if type(meta.serial) == 'string' then info.serial = meta.serial:sub(1, 24) end
		if Inv.ToInteger(meta.ammo) then info.ammo = Inv.ToInteger(meta.ammo) end
		if Inv.ToInteger(meta.equipped) then info.equipped = Inv.ToInteger(meta.equipped) end
		rows[#rows + 1] = { item = rec.item, count = 1, instance = id, info = info }
	end
	table.sort(rows, function(a, b)
		if a.item ~= b.item then return a.item < b.item end
		return (a.instance or '') < (b.instance or '')
	end)
	while #rows > 200 do rows[#rows] = nil end
	return rows
end

function Inv.View(c)
	return {
		weightG = Inv.Weight(c),
		capacityG = c.capacityG,
		slots = c.slots,
		used = Inv.UsedSlots(c),
		rows = Inv.Rows(c),
	}
end

-- Sends the player's pockets to their menu (also used to refresh an open menu).
function Inv.SendView(st, open)
	TriggerClientEvent('opx_inventory:view', st.source, Inv.View(st.pockets), open == true)
end
