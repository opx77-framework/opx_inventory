-- Stashes: containers stash:<name>, opened on demand by another resource (export OpenStash). A stash is
-- kept in memory while someone has it open (one storage reference per viewer), written and forgotten
-- when the last one leaves. A player may put / take only while the stash they were shown stays open
-- and they stay near where it opened.

Stash = {
	list = {}, -- [name] = { label, capacityG, slots, viewers = { [source] = true } }
}

local NAME_PATTERN = '^[a-z0-9_.%-]+$'

local function position(source)
	local read = Open77.players.get(source)
	local pos = type(read) == 'table' and read.position or nil
	if type(pos) ~= 'table' then return nil end
	return pos
end

local function near(st)
	local session = st.stash
	if not session then return false end
	local pos = position(st.source)
	if not pos or not session.position then return true end -- no reading: the open check stands
	local dx, dy, dz = pos.x - session.position.x, pos.y - session.position.y, pos.z - session.position.z
	local max = tonumber(Config.stash.maxDistance) or 4.0
	return dx * dx + dy * dy + dz * dz <= max * max
end

function Stash.SendView(st)
	local session = st.stash
	local stash = session and Stash.list[session.name]
	if not stash or not session.box then return end
	TriggerClientEvent('opx_inventory:stash', st.source, session.name, stash.label,
		Inv.View(session.box), Inv.View(st.pockets))
end

function Stash.Close(st)
	local session = st.stash
	if not session then return end
	st.stash = nil
	local stash = Stash.list[session.name]
	if stash then
		stash.viewers[st.source] = nil
		if not next(stash.viewers) then Stash.list[session.name] = nil end
	end
	local box = session.box
	session.box = nil
	if box then Store.Release(box) end -- an open still loading releases its own reference
end

-- Opens and shows a stash. Synchronous: true means it is shown now, or as soon as its row is read when
-- nobody had it open (a failed read is told to the player). options = { label?, capacityG?, slots? }.
function Stash.Open(source, name, options)
	local st = Inv.Get(source)
	if not st then return false, 'not_loaded' end
	if not Store.ready then return false, 'not_ready' end
	if type(name) ~= 'string' or #name < 1 or #name > 48 or not name:match(NAME_PATTERN) then return false, 'invalid_name' end
	options = type(options) == 'table' and options or {}
	local capacity = Inv.ToCount(options.capacityG, 100000000) or Config.stash.capacityG
	local slots = Inv.ToCount(options.slots, 200) or Config.stash.slots
	local label = type(options.label) == 'string' and options.label:sub(1, 48):gsub('%c', ' ') or nil

	if st.stash and st.stash.name ~= name then Stash.Close(st) end
	local stash = Stash.list[name] or { viewers = {} }
	Stash.list[name] = stash
	stash.capacityG, stash.slots = capacity, slots
	stash.label = label or stash.label

	-- Already looking at it: new sizes and position, same reference.
	if st.stash and st.stash.box then
		st.stash.position = position(source)
		st.stash.box.capacityG, st.stash.box.slots = capacity, slots
		Stash.Refresh(name)
		return true
	end

	local session = { name = name, position = position(source) }
	st.stash = session
	stash.viewers[source] = true
	Store.Acquire('stash:' .. name, function(c, why)
		if not c then
			if st.stash == session then
				Stash.Close(st)
				Inv.Notify(source, 'error_target_unavailable', nil, 'error')
			end
			return
		end
		if Inv.players[source] ~= st or st.stash ~= session then return Store.Release(c) end
		session.box = c
		c.capacityG, c.slots = stash.capacityG, stash.slots
		Stash.SendView(st)
	end)
	return true
end

-- 'put' (pockets -> stash) or 'take' (stash -> pockets). Lock held by the caller (a thread): an equipped
-- weapon put away is unequipped first, its ammo written back.
function Stash.Move(st, direction, name, item, count, instanceId)
	local session = st.stash
	if not session or session.name ~= name or not session.box then return false, 'stash_closed' end
	if not near(st) then
		Stash.Close(st)
		return false, 'too_far'
	end
	if direction == 'put' then
		local ok, why = Inv.UnequipLeaving(st, item, count, instanceId)
		if not ok then return false, why end
		if st.stash ~= session or not session.box then return false, 'stash_closed' end
		return Inv.Move(st.pockets, session.box, item, count, instanceId, st, 'target_')
	end
	return Inv.Move(session.box, st.pockets, item, count, instanceId, nil, nil)
end

-- After a change of a stash: everyone looking at it gets the new contents.
function Stash.Refresh(name)
	local stash = Stash.list[name]
	if not stash then return end
	for source in pairs(stash.viewers) do
		local st = Inv.Get(source)
		if st and st.stash and st.stash.name == name then Stash.SendView(st) end
	end
end
