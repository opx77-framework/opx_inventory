-- The item catalogue as this client knows it: the items resources registered on the server (exports
-- RegisterItem; there is no item config) and the ids that have a usable handler (RegisterUsable), received
-- through opx_inventory:items. Display only: the server decides everything.

local Catalogue = {}

local registered, usables = {}, {}
local building = nil -- { rev, pieces, got, items = {}, usables = {} }

-- The definition of `item`, or nil.
function Catalogue.get(item)
	if type(item) ~= 'string' then return nil end
	return registered[item]
end

-- Whether the menu shows "Use": `usable` in the catalogue, or a handler registered on the server.
function Catalogue.usable(item)
	local def = Catalogue.get(item)
	return def ~= nil and (def.usable == true or usables[item] == true)
end

-- Sorted ids of the whole catalogue.
function Catalogue.names()
	local out = {}
	for item in pairs(registered) do out[#out + 1] = item end
	table.sort(out)
	return out
end

local function text(value)
	if type(value) == 'string' then return value end
	if type(value) ~= 'table' then return nil end
	local out = {}
	for lang, s in pairs(value) do
		if type(lang) == 'string' and type(s) == 'string' then out[lang] = s end
	end
	return next(out) and out or nil
end

local function entryOf(row)
	if type(row) ~= 'table' or type(row.item) ~= 'string' or not row.item:match('^[a-z0-9_]+$') then return nil end
	local weight = math.tointeger(tonumber(row.weightG))
	if not weight or weight < 0 then return nil end
	return row.item, {
		label = text(row.label) or row.item,
		description = text(row.description),
		weightG = weight,
		unique = row.unique == true,
		maxStack = math.tointeger(tonumber(row.maxStack)),
		usable = row.usable == true,
		showable = row.showable == true,
		weapon = row.weapon == true,
	}
end

-- One piece of the server's snapshot. When every piece of the same revision arrived, it replaces the
-- catalogue and the usable ids.
function Catalogue.receive(list, piece, pieces, rev, uses)
	piece, pieces = math.tointeger(tonumber(piece)), math.tointeger(tonumber(pieces))
	if type(list) ~= 'table' or not piece or not pieces or pieces < 1 or pieces > 1000 or piece < 1 or piece > pieces then
		return
	end
	rev = tostring(rev)
	if not building or building.rev ~= rev or building.pieces ~= pieces then
		building = { rev = rev, pieces = pieces, got = {}, count = 0, items = {}, usables = {} }
	end
	if building.got[piece] then return end
	building.got[piece] = true
	building.count = building.count + 1
	for _, row in ipairs(list) do
		local item, def = entryOf(row)
		if item then building.items[item] = def end
	end
	for _, item in ipairs(type(uses) == 'table' and uses or {}) do
		if type(item) == 'string' then building.usables[item] = true end
	end
	if building.count < building.pieces then return end
	registered, usables = building.items, building.usables
	building = nil
end

return Catalogue
