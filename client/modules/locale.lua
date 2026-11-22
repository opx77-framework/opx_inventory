-- Player-facing text from locales/<lang>.json (English as the fallback), item labels and weights.

local Catalogue = assert(require('client.modules.catalogue'))

local Locale = {}

local strings, fallback, loaded = {}, {}, false

local function read(code)
	if type(code) ~= 'string' or not code:match('^[%w_%-]+$') then return nil end
	local text = Open77.resource.readFile(('locales/%s.json'):format(code))
	if not text then return nil end
	local ok, data = pcall(Open77.json.decode, text)
	return ok and type(data) == 'table' and data or nil
end

-- 'auto' = opx_core's language. Asked on first use: at file scope this VM cannot call other resources yet.
local function language()
	if Config.locale ~= 'auto' then return tostring(Config.locale or 'en') end
	local ok, lang = pcall(Open77.exports.callSync, 'opx_core', 'GetLocale')
	return ok and type(lang) == 'string' and lang or 'en'
end

local function load()
	if loaded then return end
	loaded = true
	fallback = read('en') or {}
	strings = read(language()) or fallback
end

function Locale.lang()
	load()
	return strings == fallback and 'en' or language()
end

function Locale.has(key)
	load()
	return strings[key] ~= nil or fallback[key] ~= nil
end

-- t(key, params): `{name}` placeholders from a table; params.list = positional values for `%s`.
function Locale.t(key, params)
	load()
	local text = strings[key] or fallback[key]
	if type(text) ~= 'string' then return tostring(key) end
	if type(params) ~= 'table' then return text end
	if type(params.list) == 'table' then
		local values = {}
		for i, v in ipairs(params.list) do values[i] = tostring(v) end
		local ok, formatted = pcall(string.format, text, table.unpack(values))
		return ok and formatted or text
	end
	return (text:gsub('{([%w_]+)}', function(name)
		local value = params[name]
		return value ~= nil and tostring(value) or nil
	end))
end

-- A catalogue text: a string, or { en = '...', fr = '...' }.
function Locale.pick(value)
	if type(value) == 'string' then return value end
	if type(value) ~= 'table' then return nil end
	return value[Locale.lang()] or value.en or select(2, next(value))
end

function Locale.itemLabel(item)
	local def = Catalogue.get(item)
	return (def and Locale.pick(def.label)) or tostring(item)
end

function Locale.itemDescription(item)
	local def = Catalogue.get(item)
	return def and Locale.pick(def.description) or nil
end

-- 1250 g -> "1.3 kg" ("1,3 kg" in French); under a kilo in grams.
function Locale.weight(grams)
	grams = tonumber(grams) or 0
	if grams < 1000 then return ('%d g'):format(math.floor(grams + 0.5)) end
	local text = ('%.1f kg'):format(grams / 1000)
	local sign = Locale.t('decimal')
	if sign ~= '.' and sign ~= 'decimal' then text = text:gsub('%.', sign, 1) end
	return text
end

return Locale
