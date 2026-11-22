-- opx_inventory client: renders the menus and sends intents. The server decides everything.

local Locale = assert(require('client.modules.locale'))
local UI = assert(require('client.modules.ui'))
local Target = assert(require('client.modules.target'))
local Catalogue = assert(require('client.modules.catalogue'))
Target.ui = UI

local loaded = false
local counts = {} -- [item] = total in the pockets (opx:inventory:counts), empty without a character

-- Feedback through opx_core (notify provider), else the game's own toast.
local function notify(text, kind)
	if type(text) ~= 'string' or text == '' then return end
	if pcall(Open77.exports.callSync, 'opx_core', 'Notify', text, kind or 'info', 3500) then return end
	pcall(Open77.hud.notify, text)
end

-- The vanilla RPG hub (inventory, crafting...) is blocked while a character plays.
local function setLoaded(state)
	loaded = state
	if Config.blockHub then
		local ok, reason = Open77.input.setActionBlocked('Hub', state)
		if not ok then print('[opx_inventory] Hub block: ' .. tostring(reason)) end
	end
	if not state then UI.closeAll() end
end

RegisterNetEvent('opx:playerLoaded', function() setLoaded(true) end)
RegisterNetEvent('opx:playerUnloaded', function()
	setLoaded(false)
	counts = {}
end)

RegisterNetEvent('opx_inventory:view', function(view, open)
	UI.showPockets(view, open == true)
end)

RegisterNetEvent('opx_inventory:stash', function(name, label, box, pockets)
	if type(name) ~= 'string' then return end
	UI.showStash(name, label, box, pockets)
end)

RegisterNetEvent('opx_inventory:staffView', function(target, view)
	UI.showStaff(tonumber(target) or 0, view)
end)

RegisterNetEvent('opx_inventory:nearby', function(token, list)
	UI.answer(token, list)
end)

RegisterNetEvent('opx_inventory:inspect', function(token, instanceId, item, meta)
	UI.answer(token, instanceId, item, meta)
end)

-- After an accepted give (item or cash) the giver plays Config.giveAnimation once. Cosmetic and local: never
-- awaited by anything, skipped when open77_animations does not run.
local function playGive()
	local profile = Config.giveAnimation
	if type(profile) ~= 'string' or profile == '' then return end
	if GetResourceState('open77_animations') ~= 'running' then return end
	CreateThread(function()
		local pending, why = Open77.exports.call('open77_animations', 'request', profile, { loop = false })
		if not pending then return print('[opx_inventory] give animation: ' .. tostring(why)) end
		local id, reason = pending:await()
		if not id then print('[opx_inventory] give animation: ' .. tostring(reason)) end
	end)
end

local GIVE_DONE = { done_give = true, done_givecash = true }

-- A server message as a locale key. `item` becomes its label, `amount` money text; an unknown error_* key
-- shows its code.
RegisterNetEvent('opx_inventory:notify', function(key, params, kind)
	if type(key) ~= 'string' then return end
	params = type(params) == 'table' and params or {}
	if type(params.item) == 'string' then params.item = Locale.itemLabel(params.item) end
	if type(params.amount) == 'number' then params.amount = UI.formatMoney(params.amount) end
	if GIVE_DONE[key] then playGive() end
	if not Locale.has(key) then
		if key:sub(1, 6) ~= 'error_' then return end
		params = { code = key:sub(7) }
		key = 'error_generic'
	end
	notify(Locale.t(key, params), kind)
end)

-- Runtime items and usable handlers of the server (internal: other resources read the exports below).
RegisterNetEvent('opx_inventory:items', function(list, piece, pieces, rev, usables)
	Catalogue.receive(list, piece, pieces, rev, usables)
end)

-- Totals of the pockets, a full snapshot from the server after every change (public event, other
-- resources may listen to it too).
RegisterNetEvent('opx:inventory:counts', function(data)
	if type(data) ~= 'table' then return end
	local fresh = {}
	for item, n in pairs(data) do
		n = math.tointeger(tonumber(n))
		if type(item) == 'string' and n and n > 0 then fresh[item] = n end
	end
	counts = fresh
end)

-- The key: opens or closes the pockets.
CreateThread(function()
	-- Runtime items and the counts of a character already loaded (a restart of this resource).
	TriggerServerEvent('opx_inventory:hello')
	local ok, reason = RegisterKeyMapping('opx_inventory.open', Locale.t('key_open'), Config.key or 'I', function()
		if loaded then UI.toggle() end
	end)
	if not ok then print('[opx_inventory] key not registered: ' .. tostring(reason)) end
	-- A character loaded before this resource (re)started.
	local fine, isLoaded = pcall(Open77.exports.callSync, 'opx_core', 'IsPlayerLoaded')
	if fine and isLoaded == true then setLoaded(true) end
	Target.register()
end)

-- opx_core synced the character's balances: the pockets' "Cash" row follows.
-- The new balances come with the event (opx_core's own copy may not be updated yet when this runs).
RegisterNetEvent('opx:setPlayerData', function(key, value)
	if key == 'accounts' and type(value) == 'table' then UI.refreshCash(value) end
end)

-- opx_target's give options call these exports of ours.
exports('targetGive', function(ctx)
	Target.onGive(ctx)
	return true
end)

exports('targetGiveCash', function(ctx)
	Target.onGiveCash(ctx)
	return true
end)

exports('targetShow', function(ctx)
	Target.onShow(ctx)
	return true
end)

-- Item texts for other resources (shops, menus): optional members of the inventory contract.
-- Localised label | nil for an item outside the catalogue.
exports('GetItemLabel', function(item)
	if type(item) ~= 'string' or not Catalogue.get(item) then return nil end
	return Locale.itemLabel(item)
end)

-- Localised description | nil.
exports('GetItemDescription', function(item)
	if type(item) ~= 'string' or not Catalogue.get(item) then return nil end
	return Locale.itemDescription(item)
end)

-- What the player carries, for other resources (target canInteract, crafting menus, HUD): from the last
-- snapshot of the server, display only (the server checks again). Optional members of the inventory contract.

-- Sorted ids of the catalogue (every registered item).
exports('GetItemNames', function()
	return Catalogue.names()
end)

-- Total of `item` in the pockets (stack + instances), 0 when unknown or without a character.
exports('GetItemCount', function(item)
	return type(item) == 'string' and counts[item] or 0
end)

-- count defaults to 1.
exports('HasItem', function(item, count)
	if type(item) ~= 'string' then return false end
	local need = math.tointeger(tonumber(count or 1))
	if not need or need < 1 then need = 1 end
	return (counts[item] or 0) >= need
end)

-- { { item, count }, ... } sorted by item: totals, no metadata.
exports('GetItems', function()
	local out = {}
	for item, n in pairs(counts) do out[#out + 1] = { item = item, count = n } end
	table.sort(out, function(a, b) return a.item < b.item end)
	return out
end)

-- Another player showed us a card: one notification, never a menu.
RegisterNetEvent('opx_inventory:shown', function(from, item, fields)
	if type(item) ~= 'string' or not Catalogue.get(item) then return end
	if not loaded then return end
	UI.shown(item, type(fields) == 'table' and fields or {})
end)

AddEventHandler('onClientResourceStart', function(name)
	if name == 'opx_target' then CreateThread(Target.register) end
end)
