-- Player intents from the menu. The client only asks: every value is checked here, one action runs at a
-- time per player, and requests are rate-limited.

local ITEM_PATTERN = '^[a-z0-9_]+$'
local INSTANCE_PATTERN = '^[A-Za-z0-9_.:%-]+$'

local rates = {} -- [source] = { since, count }
Inv.viewing = {} -- [staff source] = { target, until } (staff command `inventory`)

local function allowed(source)
	local now = Inv.Now()
	local rate = rates[source]
	if not rate or now - rate.since >= 1000 then
		rates[source] = { since = now, count = 1 }
		return true
	end
	rate.count = rate.count + 1
	return rate.count <= (tonumber(Config.actionsPerSecond) or 4)
end

function Inv.ForgetRate(source)
	rates[source] = nil
	Inv.viewing[source] = nil
end

local function itemArg(value)
	if type(value) ~= 'string' or #value > 64 or not value:match(ITEM_PATTERN) then return nil end
	return value
end

local function instanceArg(value)
	if type(value) ~= 'string' or #value < 4 or #value > 64 or not value:match(INSTANCE_PATTERN) then return nil end
	return value
end

-- Use --------------------------------------------------------------------------------------

-- The usable's owner decides (its RegisterUsable export returns true to consume one). The inventory has no
-- effect of its own: food and drink come from opx_needs, care from opx_medical, and so on.
-- The owner's export may wait and may call AddItem / RemoveItem itself.
function Inv.Use(source, item, instanceId)
	local def = Inv.Def(item)
	-- `usable = true` in the catalogue, or a handler registered with RegisterUsable.
	if not def or not (def.usable or Inv.usables[item]) then return false, 'not_usable' end
	local st = Inv.Get(source)
	if not st then return false, 'not_loaded' end
	local meta
	if instanceId then
		local rec = st.pockets.instances[instanceId]
		if not rec or rec.item ~= item then return false, 'not_found' end
		meta = Inv.Copy(rec.meta)
	elseif Inv.CountOf(st.pockets, item) < 1 then
		return false, 'not_enough'
	end
	if Open77.players.isDead(source) == true then return false, 'dead' end

	local consume = false
	local usable = Inv.usables[item]
	if usable then
		local pending, why = Open77.exports.call(usable.resource, usable.export, source, item, instanceId, meta)
		if not pending then return false, 'use_failed' end
		local answer = pending:await()
		if pending:status() ~= 'resolved' then
			Inv.Warn(('use of %s by %s failed: %s'):format(item, usable.resource, tostring(answer or why)))
			return false, 'use_failed'
		end
		consume = answer == true
	else
		return false, 'not_usable'
	end
	if not consume then return true end
	st = Inv.Get(source)
	if not st then return false, 'not_loaded' end
	return Inv.RemoveFrom(st, item, 1, instanceId)
end

-- Give -------------------------------------------------------------------------------------

-- Is `target` a loaded player within Config.giveDistance of `source`, in the same bucket?
local function isNear(source, target)
	local list = Open77.players.nearby(source, tonumber(Config.giveDistance) or 3.0)
	for _, entry in ipairs(type(list) == 'table' and list or {}) do
		if Inv.ToSource(entry.playerId) == target then return true end
	end
	return false
end

-- Pockets -> another player's pockets, one step (the caller checked distance when it matters).
-- Synchronous: an equipped weapon leaves the hands at once (menu actions unequip it properly first).
function Inv.GiveTo(st, target, item, count, instanceId)
	if not st.pockets then return false, 'not_loaded' end
	if target == st.source then return false, 'invalid_target' end
	local other = Inv.Get(target)
	if not other then return false, 'target_not_loaded' end
	return Inv.Move(st.pockets, other.pockets, item, count, instanceId, st, 'target_')
end

-- Give cash --------------------------------------------------------------------------------

-- The largest amount one give may move (Config.cash.max, integer >= 1).
local function cashMax()
	local cash = type(Config.cash) == 'table' and Config.cash or {}
	local max = Inv.ToInteger(cash.max)
	return (max and max >= 1) and max or 1000000
end

local function cashAccount()
	local cash = type(Config.cash) == 'table' and Config.cash or {}
	return type(cash.account) == 'string' and cash.account or 'money'
end

local function cashEnabled()
	return type(Config.cash) == 'table' and Config.cash.enabled == true
end

-- Cash of `source` -> cash of `target`, all or nothing (opx_core TransferMoney). No distance check: the
-- caller decided. true | false, reason.
function Inv.GiveCash(source, target, amount)
	source, target = Inv.ToSource(source), Inv.ToSource(target)
	if not source or not target then return false, 'invalid_player' end
	if not cashEnabled() then return false, 'disabled' end
	amount = Inv.ToCount(amount, cashMax())
	if not amount then return false, 'invalid_amount' end
	if source == target then return false, 'same_player' end
	local ok, done, why = pcall(Open77.exports.callSync, 'opx_core', 'TransferMoney', source, target, cashAccount(),
		amount, 'give')
	if not ok then
		Inv.Warn('give cash: opx_core did not answer: ' .. tostring(done))
		return false, 'core_unavailable'
	end
	if done ~= true then return false, type(why) == 'string' and why or 'failed' end
	return true
end

-- opx_core reasons whose generic error_* text would mislead (they speak of items).
local CASH_ERRORS = { target_not_loaded = 'error_cash_target_not_loaded' }

-- The `givecash` menu request: only `target` and `amount` are read. Synchronous, so it cannot overlap another
-- action of the same player; refused while a weapon handshake holds the player's lock.
local function giveCashRequest(src, data)
	if not cashEnabled() then return Inv.Notify(src, 'error_disabled', nil, 'error') end
	local target = Inv.ToSource(data.target)
	if not target then return Inv.Notify(src, 'error_invalid_target', nil, 'error') end
	local amount = Inv.ToCount(data.amount, cashMax())
	if not amount then return Inv.Notify(src, 'error_invalid_amount', nil, 'error') end
	local st = Inv.Get(src)
	if not st then return Inv.Notify(src, 'error_not_loaded', nil, 'error') end
	if st.locked then return Inv.Notify(src, 'error_busy', nil, 'error') end
	if Open77.players.isDead(src) == true then return Inv.Notify(src, 'error_dead', nil, 'error') end
	if target == src then return Inv.Notify(src, 'error_same_player', nil, 'error') end
	if not isNear(src, target) then return Inv.Notify(src, 'error_too_far', nil, 'error') end
	local ok, why = Inv.GiveCash(src, target, amount)
	if not ok then
		return Inv.Notify(src, CASH_ERRORS[why] or ('error_' .. tostring(why)), nil, 'error')
	end
	Inv.Notify(src, 'done_givecash', { amount = amount }, 'success')
	Inv.Notify(target, 'received_cash', { amount = amount }, 'success')
end

-- Show a card ------------------------------------------------------------------------------

local function showEnabled()
	return type(Config.show) == 'table' and Config.show.enabled == true
end

-- Catalogue flag `showable`.
local function showable(item)
	local def = Inv.Def(item)
	return def ~= nil and def.showable == true
end

local MAX_FIELDS, MAX_FIELD_BYTES = 8, 64

-- A string cut to `max` bytes without splitting a UTF-8 character, control characters removed.
local function cut(text, max)
	text = text:gsub('%c', ' ')
	if #text > max then text = text:sub(1, max) end
	while utf8 and #text > 0 and not utf8.len(text) do text = text:sub(1, -2) end
	return text
end

-- Metadata -> what the other player reads: string keys with string / finite number values, sorted by key,
-- at most MAX_FIELDS, each value cut to MAX_FIELD_BYTES. Anything else is left out.
local function fieldsOf(meta)
	local keys = {}
	for key, value in pairs(type(meta) == 'table' and meta or {}) do
		local kind = type(value)
		local number = kind == 'number' and value == value and value ~= math.huge and value ~= -math.huge
		if type(key) == 'string' and #key <= 32 and (kind == 'string' or number) then keys[#keys + 1] = key end
	end
	table.sort(keys)
	local out = {}
	for i = 1, math.min(#keys, MAX_FIELDS) do
		local key, value = keys[i], meta[keys[i]]
		out[key] = type(value) == 'string' and cut(value, MAX_FIELD_BYTES) or value
	end
	return out
end

-- What to show from the pockets: the instance asked, else the item asked, else the first showable row.
-- Returns item, meta (nil for a stack), or nil, reason.
local function pickShown(c, item, instanceId)
	if instanceId then
		local rec = c.instances[instanceId]
		if not rec then return nil, 'not_found' end
		if not showable(rec.item) then return nil, 'not_showable' end
		return rec.item, rec.meta
	end
	if item then
		if not showable(item) then return nil, 'not_showable' end
		local first = Inv.InstancesOf(c, item)[1]
		if first then return item, first.meta end
		if Inv.StackOf(c, item) > 0 then return item, nil end
		return nil, 'not_found'
	end
	for _, row in ipairs(Inv.Rows(c)) do
		if showable(row.item) then
			return row.item, row.instance and c.instances[row.instance].meta or nil
		end
	end
	return nil, 'nothing_to_show'
end

-- The `show` menu request: { target, item?, instance? }. Nothing moves: the target's client gets one
-- notification with the item's fields. Synchronous.
local function showRequest(src, data)
	if not showEnabled() then return Inv.Notify(src, 'error_disabled', nil, 'error') end
	local target = Inv.ToSource(data.target)
	if not target or target == src then return Inv.Notify(src, 'error_invalid_target', nil, 'error') end
	local item = data.item ~= nil and itemArg(data.item) or nil
	local instanceId = data.instance ~= nil and instanceArg(data.instance) or nil
	if (data.item ~= nil and not item) or (data.instance ~= nil and not instanceId) then return end
	local st = Inv.Get(src)
	if not st then return Inv.Notify(src, 'error_not_loaded', nil, 'error') end
	if Open77.players.isDead(src) == true then return Inv.Notify(src, 'error_dead', nil, 'error') end
	if not Inv.Get(target) then return Inv.Notify(src, 'error_invalid_target', nil, 'error') end
	if not isNear(src, target) then return Inv.Notify(src, 'error_too_far', nil, 'error') end
	local shown, meta = pickShown(st.pockets, item, instanceId)
	if not shown then return Inv.Notify(src, 'error_' .. meta, nil, 'error') end
	TriggerClientEvent('opx_inventory:shown', target, src, shown, fieldsOf(meta))
	Inv.Notify(src, 'done_show', { item = shown, id = target }, 'success')
end

-- Net events -------------------------------------------------------------------------------

local ACTIONS = {
	give = function(st, data)
		local target = Inv.ToSource(data.target)
		if not target then return false, 'invalid_target' end
		if Open77.players.isDead(st.source) == true then return false, 'dead' end
		if not isNear(st.source, target) then return false, 'too_far' end
		if not Inv.Get(target) then return false, 'target_not_loaded' end
		local ok, why = Inv.UnequipLeaving(st, data.item, data.count, data.instance)
		if not ok then return false, why end
		ok, why = Inv.GiveTo(st, target, data.item, data.count, data.instance)
		if ok then Inv.Notify(target, 'received', { item = data.item, count = data.count }, 'success') end
		return ok, why
	end,
	drop = function(st, data)
		local ok, why = Inv.UnequipLeaving(st, data.item, data.count, data.instance)
		if not ok then return false, why end
		return Inv.RemoveFrom(st, data.item, data.count, data.instance)
	end,
	equip = function(st, data)
		if not data.instance then return false, 'not_found' end
		return Weapons.Equip(st, data.instance)
	end,
	unequip = function(st, data)
		if not data.instance then return false, 'not_found' end
		return Weapons.Unequip(st, data.instance)
	end,
	put = function(st, data) return Stash.Move(st, 'put', data.stash, data.item, data.count, data.instance) end,
	take = function(st, data) return Stash.Move(st, 'take', data.stash, data.item, data.count, data.instance) end,
}

RegisterNetEvent('opx_inventory:action', function(action, data)
	local src = Inv.ToSource(source)
	if not src or not allowed(src) then return end
	if type(data) ~= 'table' then return end
	-- Give cash has its own fields (target, amount) and no item.
	if action == 'givecash' then return giveCashRequest(src, data) end
	-- Show has its own fields (target, item?, instance?) and moves nothing.
	if action == 'show' then return showRequest(src, data) end
	if action ~= 'use' and not ACTIONS[action] then return end
	local clean = {
		item = itemArg(data.item),
		count = Inv.ToCount(data.count or 1, 1000000),
		instance = data.instance ~= nil and instanceArg(data.instance) or nil,
		target = data.target,
		stash = type(data.stash) == 'string' and #data.stash <= 48 and data.stash or nil,
	}
	if action ~= 'equip' and action ~= 'unequip' and (not clean.item or not clean.count) then return end
	if data.instance ~= nil and not clean.instance then return end
	if clean.instance then clean.count = 1 end
	local st = Inv.Get(src)
	if not st then return end
	if st.locked then return Inv.Notify(src, 'error_busy', nil, 'error') end

	CreateThread(function()
		local ok, why
		if action == 'use' then
			ok, why = Inv.Use(src, clean.item, clean.instance)
		else
			ok, why = Inv.WithLock(src, 0, ACTIONS[action], clean)
		end
		local current = Inv.Get(src)
		if not current then return end
		if ok then
			Inv.Notify(src, 'done_' .. action, { item = clean.item, count = clean.count }, 'success')
		else
			Inv.Notify(src, 'error_' .. tostring(why or 'failed'), { item = clean.item }, 'error')
		end
		-- A change refreshes the views by itself; this answers a refusal that changed nothing.
		if current.viewOpen then Inv.SendView(current) end
		if current.stash then Stash.SendView(current) end
	end)
end)

RegisterNetEvent('opx_inventory:open', function()
	local src = Inv.ToSource(source)
	if not src or not allowed(src) then return end
	local st = Inv.Get(src)
	if not st then return Inv.Notify(src, 'error_not_loaded', nil, 'error') end
	st.viewOpen = true
	Inv.SendView(st, true)
end)

-- The rows only (the targeting eye's give list): the menu is not opened.
RegisterNetEvent('opx_inventory:refresh', function()
	local src = Inv.ToSource(source)
	if not src or not allowed(src) then return end
	local st = Inv.Get(src)
	if st then Inv.SendView(st, false) end
end)

RegisterNetEvent('opx_inventory:close', function()
	local src = Inv.ToSource(source)
	local st = src and Inv.players[src]
	if st then st.viewOpen = false end
	if src then Inv.viewing[src] = nil end
end)

RegisterNetEvent('opx_inventory:stashClose', function()
	local src = Inv.ToSource(source)
	local st = src and Inv.players[src]
	if st then Stash.Close(st) end
end)

-- Players the client may give to: id and distance (decimetres). Names are not sent (no metagaming).
RegisterNetEvent('opx_inventory:nearby', function(token)
	local src = Inv.ToSource(source)
	if not src or not allowed(src) or not Inv.Get(src) then return end
	local list = Open77.players.nearby(src, tonumber(Config.giveDistance) or 3.0, { limit = 8 })
	local out = {}
	for _, entry in ipairs(type(list) == 'table' and list or {}) do
		local id = Inv.ToSource(entry.playerId)
		local distance = tonumber(entry.distance)
		if id and id ~= src and Inv.Get(id) and distance and distance == distance and distance < 1000 then
			out[#out + 1] = { id = id, dm = math.floor(distance * 10 + 0.5) }
		end
	end
	TriggerClientEvent('opx_inventory:nearby', src, Inv.ToInteger(token) or 0, out)
end)

-- Metadata of one instance: in the player's pockets, the stash they look at, or the pockets a staff
-- member is viewing (command `inventory`).
RegisterNetEvent('opx_inventory:inspect', function(token, instanceId)
	local src = Inv.ToSource(source)
	if not src or not allowed(src) then return end
	instanceId = instanceArg(instanceId)
	if not instanceId then return end
	local containers = {}
	local st = Inv.Get(src)
	if st then containers[#containers + 1] = st.pockets end
	if st and st.stash and st.stash.box then containers[#containers + 1] = st.stash.box end
	local view = Inv.viewing[src]
	if view and view.untilMs > Inv.Now() then
		local other = Inv.Get(view.target)
		if other then containers[#containers + 1] = other.pockets end
	end
	for _, c in ipairs(containers) do
		local rec = c.instances[instanceId]
		if rec then
			return TriggerClientEvent('opx_inventory:inspect', src, Inv.ToInteger(token) or 0, instanceId,
				rec.item, rec.meta)
		end
	end
	TriggerClientEvent('opx_inventory:inspect', src, Inv.ToInteger(token) or 0, instanceId, nil, nil)
end)
