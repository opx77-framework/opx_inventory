-- The item catalogue (exports RegisterItem / UnregisterItem) and its sync to clients. There is no item config:
-- every item is registered by the resource that gives it a meaning (opx_inventory itself registers id_card).
-- An item lives in Inv.items with `resource` (its owner), `generation` (the owner's VM; nil once that VM
-- stopped) and the texts the clients need. It stays in the catalogue when its owner stops (pockets keep its
-- weight and label): only the claim goes, so another resource may then take the id. It leaves with
-- UnregisterItem or an opx_inventory restart.
-- Clients get the items and the ids that have a RegisterUsable handler through the internal event
-- opx_inventory:items (list, piece, pieces, rev, usables): on their hello, and after a change (coalesced).

Catalogue = {}

local ITEM_PATTERN = '^[a-z0-9_]+$'
local RECORD_PATTERN = '^[%w_.]+$' -- TweakDB record of a weapon, e.g. Items.Preset_Lexington_Default
local RECORD_BYTES = 128
local LANG_PATTERN = '^[a-z][a-z]$'
local PER_RESOURCE = 64   -- items one resource may own
local TOTAL = 500         -- items in all (GetItemNames stays far under the 48 KiB sync result limit)
local LANGS = 4           -- languages per text table
local LABEL_BYTES, DESCRIPTION_BYTES = 64, 200
local PIECE_ITEMS, PIECE_USABLES = 8, 100 -- per event: under 35 KiB even with every text escaped, limit 48 KiB
local HELLO_MS = 3000     -- one catalogue request per player per 3 s
local SYNC_DELAY = 250    -- registrations of one burst cost one broadcast

local ALLOWED = { label = true, description = true, weightG = true, unique = true, maxStack = true,
	usable = true, showable = true, weapon = true, ammo = true, characterMeta = true }

-- Text ---------------------------------------------------------------------------------------

-- A non-empty UTF-8 string of at most `max` bytes without control characters, or nil.
local function cleanText(value, max)
	if type(value) ~= 'string' or #value < 1 or #value > max or value:find('%c') then return nil end
	if utf8 and not utf8.len(value) then return nil end
	return value
end

-- A string, or { en = '...', fr = '...' } (2-letter codes, LANGS at most), or nil.
local function cleanTexts(value, max)
	if type(value) == 'string' then return cleanText(value, max) end
	if type(value) ~= 'table' then return nil end
	local out, n = {}, 0
	for lang, text in pairs(value) do
		n = n + 1
		if n > LANGS or type(lang) ~= 'string' or not lang:match(LANG_PATTERN) then return nil end
		out[lang] = cleanText(text, max)
		if not out[lang] then return nil end
	end
	return n > 0 and out or nil
end

local function flag(value)
	if value == nil then return false end
	if type(value) ~= 'boolean' then return nil end
	return value
end

-- definition -> normalised entry, or nil (invalid_definition). Any key outside ALLOWED is refused.
-- weapon: TweakDB record (makes the item unique). ammo: id of the stack item its rounds come from, weapons only
-- (it may be registered later; checked when the weapon is equipped). characterMeta: an instance given without
-- metadata is filled from the receiving character (name, citizenId, birthdate).
local function validate(item, definition)
	if type(definition) ~= 'table' then return nil end
	for key in pairs(definition) do
		if not ALLOWED[key] then return nil end
	end
	local label = cleanTexts(definition.label, LABEL_BYTES)
	if not label then return nil end
	local description
	if definition.description ~= nil then
		description = cleanTexts(definition.description, DESCRIPTION_BYTES)
		if not description then return nil end
	end
	local weight = Inv.ToInteger(definition.weightG)
	if not weight or weight < 0 or weight > 1000000 then return nil end
	local maxStack
	if definition.maxStack ~= nil then
		maxStack = Inv.ToCount(definition.maxStack)
		if not maxStack then return nil end
	end
	local unique, usable, showable = flag(definition.unique), flag(definition.usable), flag(definition.showable)
	local characterMeta = flag(definition.characterMeta)
	if unique == nil or usable == nil or showable == nil or characterMeta == nil then return nil end
	local weapon, ammo = definition.weapon, definition.ammo
	if weapon ~= nil then
		if type(weapon) ~= 'string' or #weapon < 1 or #weapon > RECORD_BYTES or not weapon:match(RECORD_PATTERN) then
			return nil
		end
		unique = true
	end
	if ammo ~= nil then
		if not weapon or type(ammo) ~= 'string' or #ammo > 48 or not ammo:match(ITEM_PATTERN) or ammo == item then
			return nil
		end
	end
	return {
		weightG = weight, unique = unique, usable = usable, showable = showable, maxStack = maxStack,
		characterMeta = characterMeta, weapon = weapon, ammo = ammo, label = label, description = description,
	}
end

-- Sync ----------------------------------------------------------------------------------------

local rev, syncQueued = 0, false
local BOOT = Inv.Base36(math.floor((Open77.time.unix() or 0) * 1000))
local helloAt = {} -- [source] = ms of the last hello answered

local function token()
	return BOOT .. '.' .. rev
end

local function sortedKeys(map, keep)
	local out = {}
	for key, value in pairs(map) do
		if keep(key, value) then out[#out + 1] = key end
	end
	table.sort(out)
	return out
end

-- The items as clients read them (weapon: a boolean, the record stays on the server), and the ids with a registered usable handler.
local function snapshot()
	local list = {}
	for _, item in ipairs(sortedKeys(Inv.items, function(_, def) return def.resource ~= nil end)) do
		local def = Inv.items[item]
		list[#list + 1] = {
			item = item, label = Inv.Copy(def.label), description = Inv.Copy(def.description), weightG = def.weightG,
			unique = def.unique, maxStack = def.maxStack, usable = def.usable, showable = def.showable,
			weapon = def.weapon ~= nil,
		}
	end
	local usables = sortedKeys(Inv.usables, function(item) return Inv.items[item] ~= nil end)
	return list, usables
end

-- target: a player id, or -1 for everyone.
function Catalogue.Send(target)
	local list, usables = snapshot()
	local pieces = math.max(1, math.ceil(#list / PIECE_ITEMS), math.ceil(#usables / PIECE_USABLES))
	local rv = token()
	for p = 1, pieces do
		local items, uses = {}, {}
		for i = (p - 1) * PIECE_ITEMS + 1, math.min(#list, p * PIECE_ITEMS) do items[#items + 1] = list[i] end
		for i = (p - 1) * PIECE_USABLES + 1, math.min(#usables, p * PIECE_USABLES) do uses[#uses + 1] = usables[i] end
		TriggerClientEvent('opx_inventory:items', target, items, p, pieces, rv, uses)
	end
end

-- Something clients show changed (an item, a usable handler): one broadcast per burst.
function Catalogue.Changed()
	if syncQueued then return end
	syncQueued = true
	SetTimeout(SYNC_DELAY, function()
		syncQueued = false
		rev = rev + 1
		Catalogue.Send(-1)
	end)
end

-- A client (re)started: it asks for the catalogue, and the counts of its pockets.
RegisterNetEvent('opx_inventory:hello', function()
	local src = Inv.ToSource(source)
	if not src then return end
	local now = Inv.Now()
	if helloAt[src] and now - helloAt[src] < HELLO_MS then return end
	helloAt[src] = now
	Catalogue.Send(src)
	if Inv.Get(src) then Inv.SendCounts(src) end
end)

function Catalogue.Forget(source)
	helloAt[source] = nil
end

-- Exports -------------------------------------------------------------------------------------

local function hostEvent(name, ...)
	local ok, err = pcall(TriggerEvent, name, ...)
	if not ok then Inv.Warn(name .. ' raised: ' .. tostring(err)) end
end

-- Sorted ids of the whole catalogue.
function Catalogue.Names()
	return sortedKeys(Inv.items, function() return true end)
end

-- true | false, reason. Adds or replaces `item`, owned by `owner` (a resource name) and its VM `generation`.
-- Shared by the export (the caller) and opx_inventory's own items (Catalogue.RegisterOwn).
local function put(item, definition, owner, generation)
	if type(item) ~= 'string' or #item > 48 or not item:match(ITEM_PATTERN) then return false, 'invalid_item' end
	local existing = Inv.items[item]
	if existing and existing.resource ~= owner and existing.generation ~= nil then
		local ok, state = pcall(GetResourceState, existing.resource)
		if not ok or state == 'running' or state == 'starting' then return false, 'item_taken' end
	end
	local def = validate(item, definition)
	if not def then return false, 'invalid_definition' end
	if not existing or existing.resource ~= owner then
		local mine, total = 0, 0
		for _, entry in pairs(Inv.items) do
			total = total + 1
			if entry.resource == owner then mine = mine + 1 end
		end
		if mine >= PER_RESOURCE or total >= TOTAL then return false, 'item_limit' end
	end
	if existing and existing.resource ~= owner then
		Inv.Warn(('item %s moved from %s (stopped) to %s'):format(item, tostring(existing.resource), owner))
	end
	def.id = item
	def.resource = owner
	def.generation = generation
	Inv.items[item] = def
	if not existing then Inv.Info(('item %s registered by %s'):format(item, owner)) end
	hostEvent('opx:inventory:itemRegistered', item, owner)
	Catalogue.Changed()
	-- Weapons whose item was not registered yet when the pockets loaded go back in the hands now.
	if def.weapon then Weapons.ItemRegistered(item) end
	return true
end

-- true | false, reason. The caller (GetInvokingResource + its VM generation) owns the item.
function Catalogue.Register(item, definition)
	local owner = GetInvokingResource()
	if not owner then return false, 'export_call_required' end
	return put(item, definition, owner, GetInvokingResourceGeneration() or Open77.resource.generation(owner))
end

-- opx_inventory's own items, at its start (same validation, owner opx_inventory).
function Catalogue.RegisterOwn(item, definition)
	local ok, why = put(item, definition, Inv.RESOURCE, Open77.resource.generation(Inv.RESOURCE))
	if not ok then Inv.Error(('own item %s not registered: %s'):format(item, tostring(why))) end
	return ok, why
end

-- true | false, reason. Only the owner (by resource name) removes its item; pockets keep what they hold
-- (it weighs nothing and shows its id until registered again).
function Catalogue.Unregister(item)
	local owner = GetInvokingResource()
	if not owner then return false, 'export_call_required' end
	local entry = type(item) == 'string' and Inv.items[item] or nil
	if not entry then return false, 'unknown_item' end
	if entry.resource ~= owner then return false, 'not_owner' end
	Inv.items[item] = nil
	Inv.Info(('item %s unregistered by %s'):format(item, owner))
	hostEvent('opx:inventory:itemUnregistered', item)
	Catalogue.Changed()
	return true
end

-- A resource stopped: its usable handlers go and its items lose their claim (they stay in the
-- catalogue). By VM generation, never by name alone: on a hot reload the new VM registers again BEFORE this
-- stop notice of the old one arrives, and what it registered stays.
function Catalogue.DropOwner(resource)
	local current = Open77.resource.generation(resource)
	local changed = false
	for item, entry in pairs(Inv.usables) do
		if entry.resource == resource and entry.generation ~= current then
			Inv.usables[item] = nil
			changed = true
		end
	end
	for _, def in pairs(Inv.items) do
		if def.resource == resource and def.generation ~= nil and def.generation ~= current then
			def.generation = nil
		end
	end
	if changed then Catalogue.Changed() end
end
