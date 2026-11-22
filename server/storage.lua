-- Storage: one row per container in opx_inventories (MySQL / MariaDB through Open77.database).
-- The server keeps the authoritative contents IN MEMORY while a container is in use (pockets of a loaded
-- character, a stash someone has open): every change is a plain Lua step, so it cannot half-happen.
-- Rows are written a few seconds after a change (one write per burst), when the container is released
-- (unload, disconnect, stash closed) and at resource stop. Every write uses the callback form: nothing here
-- yields, so the exports that change items stay synchronous.
--
-- Container in memory: { id, stacks = { [item] = count }, instances = { [instanceId] = { item, meta } },
--   capacityG, slots, refs, dirty, writing, timer }

Store = {
	ready = false,
	cache = {},   -- [id] = container in memory
	pending = {}, -- [id] = { callbacks waiting for its row }
}

local SCHEMA = [[CREATE TABLE IF NOT EXISTS opx_inventories (
	id VARCHAR(96) NOT NULL,
	items LONGTEXT NOT NULL,
	updated_at BIGINT NOT NULL DEFAULT 0,
	PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]

-- updated_at is a version (unix ms, strictly increasing in this VM): a write that lands after a newer one
-- (two writes in flight at stop, or the VM of a hot reload) never overwrites it.
local UPSERT = [[INSERT INTO opx_inventories (id, items, updated_at) VALUES (?, ?, ?)
	ON DUPLICATE KEY UPDATE items = IF(VALUES(updated_at) >= updated_at, VALUES(items), items),
	updated_at = GREATEST(updated_at, VALUES(updated_at))]]

local SELECT = 'SELECT items FROM opx_inventories WHERE id = ? LIMIT 1'

local ITEM_PATTERN = '^[a-z0-9_]+$'
local RETRY_MS = 5000

local lastVersion = 0
local function nextVersion()
	lastVersion = math.max(lastVersion + 1, math.floor((Open77.time.unix() or 0) * 1000))
	return lastVersion
end

local function saveDelay()
	local seconds = tonumber(Config.saveSeconds) or 5
	if seconds ~= seconds or seconds < 1 or seconds > 300 then seconds = 5 end
	return math.floor(seconds * 1000)
end

-- Rows -------------------------------------------------------------------------------------

-- The JSON of a row -> stacks, instances. Bad entries are skipped (logged); an unreadable row refuses the
-- load, so an empty container is never saved over data we could not read.
local function decode(id, text)
	if text == nil then return {}, {} end
	local doc = text
	if type(text) == 'string' then
		local ok, decoded = pcall(json.decode, text)
		if not ok then return nil end
		doc = decoded
	end
	if type(doc) ~= 'table' then return nil end
	local stacks, instances, skipped = {}, {}, 0
	for item, n in pairs(type(doc.stacks) == 'table' and doc.stacks or {}) do
		local count = Inv.ToInteger(n)
		if type(item) == 'string' and item:match(ITEM_PATTERN) and count and count > 0 then
			stacks[item] = count
		else
			skipped = skipped + 1
		end
	end
	for instanceId, rec in pairs(type(doc.instances) == 'table' and doc.instances or {}) do
		if type(instanceId) == 'string' and #instanceId >= 4 and #instanceId <= 64 and type(rec) == 'table'
			and type(rec.item) == 'string' and rec.item:match(ITEM_PATTERN) then
			local meta = type(rec.meta) == 'table' and Inv.Encodable(rec.meta) and rec.meta or {}
			instances[instanceId] = { item = rec.item, meta = meta }
		else
			skipped = skipped + 1
		end
	end
	if skipped > 0 then Inv.Warn(('%s: %d unreadable entr(ies) skipped'):format(id, skipped)) end
	return stacks, instances
end

local function encode(c)
	local doc = { stacks = c.stacks, instances = {} }
	for instanceId, rec in pairs(c.instances) do
		doc.instances[instanceId] = { item = rec.item, meta = rec.meta }
	end
	if not Inv.Encodable(doc) then return nil end
	local ok, text = pcall(json.encode, doc)
	if ok and type(text) == 'string' then return text end
	return nil
end

-- Writes ------------------------------------------------------------------------------------

local function evicted(c)
	return Store.cache[c.id] ~= c
end

-- Forgets a container nobody uses once everything it holds is in the database.
function Store.TryEvict(c)
	if c.refs <= 0 and not c.dirty and not c.writing and not c.timer and not evicted(c) then
		Store.cache[c.id] = nil
		c.gone = true
	end
end

local function retryLater(c)
	if c.timer or c.gone then return end
	c.timer = SetTimeout(RETRY_MS, function()
		c.timer = nil
		Store.Save(c)
	end)
end

-- Writes the container now (callback form, never yields). One write in flight per container: a change
-- made meanwhile is written when it answers.
function Store.Save(c)
	if c.timer then
		ClearTimeout(c.timer)
		c.timer = nil
	end
	if c.writing then return end
	if not c.dirty then return Store.TryEvict(c) end
	local text = encode(c)
	if not text then
		Inv.Error(('%s not saved: contents are not serialisable'):format(c.id))
		c.dirty = false
		return
	end
	c.dirty, c.writing = false, true
	local ok, accepted, reason = pcall(Open77.database.update, UPSERT, { c.id, text, nextVersion() }, function(_, failure)
		c.writing = false
		if failure then
			Inv.Error(('%s not saved: %s (retrying)'):format(c.id, tostring(failure)))
			c.dirty = true
			return retryLater(c)
		end
		if c.dirty then return Store.Save(c) end
		Store.TryEvict(c)
	end)
	if not ok or accepted == false then
		c.writing, c.dirty = false, true
		Inv.Error(('%s not saved: %s (retrying)'):format(c.id, tostring(ok and reason or accepted)))
		retryLater(c)
	end
end

-- A change: the row is written Config.saveSeconds later (bursts cost one write).
function Store.MarkDirty(c)
	if c.gone then
		Inv.Warn(('%s changed after it was released: change ignored'):format(c.id))
		return
	end
	c.dirty = true
	if c.timer or c.writing then return end
	c.timer = SetTimeout(saveDelay(), function()
		c.timer = nil
		Store.Save(c)
	end)
end

-- Resource stop: only callback-form writes still work, and nothing will answer them here. Everything not
-- yet written goes out now (the version column keeps the newest row if an older write was in flight).
function Store.FlushAll()
	for _, c in pairs(Store.cache) do
		if c.dirty or c.writing then
			local text = encode(c)
			if text then
				pcall(Open77.database.update, UPSERT, { c.id, text, nextVersion() }, function() end)
			end
		end
	end
end

-- Loads ---------------------------------------------------------------------------------------

-- done(container) | done(nil, reason). Takes one reference: give it back with Store.Release.
-- Answers synchronously when the container is already in memory.
function Store.Acquire(id, done)
	local c = Store.cache[id]
	if c then
		c.refs = c.refs + 1
		return done(c)
	end
	if not Store.ready then return done(nil, 'not_ready') end
	local waiting = Store.pending[id]
	if waiting then
		waiting[#waiting + 1] = done
		return
	end
	Store.pending[id] = { done }

	local function finish(container, reason)
		local list = Store.pending[id] or {}
		Store.pending[id] = nil
		for _, callback in ipairs(list) do
			if container then container.refs = container.refs + 1 end
			local ok, err = pcall(callback, container, reason)
			if not ok then Inv.Error(('load of %s: callback raised: %s'):format(id, tostring(err))) end
		end
		if container then Store.TryEvict(container) end
	end

	local ok, accepted, reason = pcall(Open77.database.query, SELECT, { id }, function(rows, failure)
		if failure or type(rows) ~= 'table' then
			Inv.Error(('%s not loaded: %s'):format(id, tostring(failure or 'no_rows')))
			return finish(nil, 'db_error')
		end
		local loaded = Store.cache[id]
		if not loaded then
			local row = rows[1]
			local stacks, instances = decode(id, type(row) == 'table' and row.items or nil)
			if not stacks then
				Inv.Error(('%s not loaded: its row is not valid JSON (left untouched)'):format(id))
				return finish(nil, 'db_error')
			end
			loaded = { id = id, stacks = stacks, instances = instances, capacityG = 0, slots = 0, refs = 0,
				dirty = false, writing = false }
			Store.cache[id] = loaded
		end
		finish(loaded)
	end)
	if not ok or accepted == false then
		Inv.Error(('%s not loaded: %s'):format(id, tostring(ok and reason or accepted)))
		finish(nil, 'db_error')
	end
end

-- Gives a reference back. The last one writes the container now and forgets it once written.
function Store.Release(c)
	if not c or c.gone then return end
	c.refs = math.max(0, c.refs - 1)
	if c.refs > 0 then return end
	if c.dirty then return Store.Save(c) end
	Store.TryEvict(c)
end

-- Start: the table, then Store.ready (pockets and stashes wait for it).
function Store.Start(onReady)
	if type(Open77.database) ~= 'table' then
		Inv.Error('no database bridge: enable the database in server.jsonc (and the database.access permission)')
		return
	end
	local queued, reason = Open77.database.ready(function()
		Open77.database.update(SCHEMA, {}, function(_, failure)
			if failure then return Inv.Error('table opx_inventories not created: ' .. tostring(failure)) end
			Store.ready = true
			Inv.Info('database ready')
			if onReady then onReady() end
		end)
	end)
	if not queued then Inv.Error('database unavailable: ' .. tostring(reason)) end
end
