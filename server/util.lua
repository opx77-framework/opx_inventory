-- Shared server state and small helpers. Every server file reads and extends `Inv`.
-- What must never reach a native or json.encode (measured: it ends the whole server, pcall does not catch it):
-- a non-positive / non-integer player id, NaN or infinity, more than 32 event arguments.

Inv = {
	RESOURCE = GetCurrentResourceName(),
	players = {},  -- [source] = player state (server/inventory.lua)
	items = {},    -- [itemId] = normalised catalogue entry with label, description, resource (owner) and
	               -- generation (server/catalogue.lua)
	usables = {},  -- [itemId] = { resource, export, generation } (RegisterUsable)
}

local function log(level, message)
	local writer = Open77.log and Open77.log[level]
	if writer then writer('[opx_inventory] ' .. message) else print('[opx_inventory] ' .. message) end
end

function Inv.Info(message) log('info', message) end
function Inv.Warn(message) log('warn', message) end
function Inv.Error(message) log('error', message) end

-- A player id a native can read (positive integer in uint32), or nil. Host events pass strings.
function Inv.ToSource(value)
	local n = tonumber(value)
	local id = n and math.tointeger(n) or nil
	if not id or id < 1 or id > 0x7FFFFFFF then return nil end
	return id
end

-- A finite integer, or nil.
function Inv.ToInteger(value)
	local n = tonumber(value)
	if not n or n ~= n or n == math.huge or n == -math.huge or n % 1 ~= 0 then return nil end
	return math.tointeger(n)
end

-- A count between 1 and `max` (default 1,000,000), or nil.
function Inv.ToCount(value, max)
	local n = Inv.ToInteger(value)
	if not n or n < 1 or n > (max or 1000000) then return nil end
	return n
end

function Inv.Copy(value)
	if type(value) ~= 'table' then return value end
	local out = {}
	for k, v in pairs(value) do out[k] = Inv.Copy(v) end
	return out
end

-- Milliseconds, monotonic (GetGameTimer is a float on the server).
function Inv.Now()
	return math.floor(GetGameTimer())
end

local DIGITS = '0123456789abcdefghijklmnopqrstuvwxyz'

function Inv.Base36(n)
	n = math.tointeger(n) or 0
	if n <= 0 then return '0' end
	local out = {}
	while n > 0 do
		local d = n % 36
		out[#out + 1] = DIGITS:sub(d + 1, d + 1)
		n = n // 36
	end
	return string.reverse(table.concat(out))
end

-- Instance ids made by this VM: boot time (ms, base36) + counter + a random tail. The boot time moves
-- forward between two starts, so a restart cannot make an id an earlier run already used.
local BOOT = Inv.Base36(math.floor((Open77.time.unix() or 0) * 1000))
local counter = 0

-- Instance id of a unique item: "<item>_<base36>" (4..64 chars). Never reused, even after a destroy.
function Inv.NewInstanceId(item)
	counter = counter + 1
	return ('%s_%s%s%s'):format(item:sub(1, 36), BOOT, Inv.Base36(counter), Inv.Base36(math.random(36, 1295)))
end

-- Plain metadata: string keys (or a pure array), strings / booleans / finite numbers / nested tables,
-- depth <= 4, <= 2048 bytes encoded. Returns a clean copy, or nil, reason.
local function cleanValue(value, depth)
	local kind = type(value)
	if kind == 'string' then return #value <= 512 and value or nil end
	if kind == 'boolean' then return value end
	if kind == 'number' then
		if value ~= value or value == math.huge or value == -math.huge then return nil end
		return value
	end
	if kind ~= 'table' or depth > 4 then return nil end
	local out, count = {}, 0
	for k, v in pairs(value) do
		count = count + 1
		if count > 64 then return nil end
		local keyOk = (type(k) == 'string' and #k >= 1 and #k <= 32) or math.type(k) == 'integer'
		if not keyOk then return nil end
		local clean = cleanValue(v, depth + 1)
		if clean == nil then return nil end
		out[k] = clean
	end
	return out
end

function Inv.CleanMeta(meta)
	if meta == nil then return nil end
	if type(meta) ~= 'table' then return nil, 'invalid_meta' end
	local clean = cleanValue(meta, 1)
	if clean == nil then return nil, 'invalid_meta' end
	local ok, encoded = pcall(json.encode, clean)
	if not ok or type(encoded) ~= 'string' or #encoded > 2048 then return nil, 'invalid_meta' end
	return clean
end

-- Whether json.encode can take `value` (NaN, +-inf, a function or userdata ABORT the whole server inside
-- json.encode, pcall does not catch it). Used on rows read back from the database and before every write.
local function encodable(value, depth, budget)
	local kind = type(value)
	if kind == 'string' or kind == 'boolean' then return true end
	if kind == 'number' then return value == value and value ~= math.huge and value ~= -math.huge end
	if kind ~= 'table' or depth > 8 then return false end
	for k, v in pairs(value) do
		budget.left = budget.left - 1
		if budget.left < 0 then return false end
		if type(k) ~= 'string' and math.type(k) ~= 'integer' then return false end
		if not encodable(v, depth + 1, budget) then return false end
	end
	return true
end

function Inv.Encodable(value)
	return encodable(value, 1, { left = 50000 })
end

-- Catalogue ---------------------------------------------------------------------------

-- The catalogue is runtime only: every entry comes from RegisterItem (server/catalogue.lua), opx_inventory's own
-- id_card included. An item no longer registered weighs nothing and shows its id.
function Inv.Def(item)
	return type(item) == 'string' and Inv.items[item] or nil
end

-- Client feedback -----------------------------------------------------------------------

-- A translated notification: the client resolves the key in its locale file (the server cannot read them).
-- params: a flat table of strings / integers.
function Inv.Notify(source, key, params, kind)
	if not Inv.ToSource(source) then return end
	TriggerClientEvent('opx_inventory:notify', source, key, params or {}, kind or 'info')
end

pcall(function()
	math.randomseed(math.floor(Open77.time.unix() * 1000), math.floor(GetGameTimer()))
end)
