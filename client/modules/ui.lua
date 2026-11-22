-- The menus: pockets, row actions, give, inspect, stash, staff view. The client only renders and asks;
-- the server answers with a fresh view (opx_inventory:view / opx_inventory:stash) and a notification.

local Menu = assert(require('@opx_menu'))
local Dialog = assert(require('@opx_dialog'))
local Locale = assert(require('client.modules.locale'))
local Catalogue = assert(require('client.modules.catalogue'))

local L = Locale.t
local UI = {}

local main, child, childKey = nil, nil, nil -- pockets menu, its open row submenu, that row's key
local stashMenu, stashName = nil, nil
local view = nil
local mainRows, stashRows, staffRows = {}, {}, {} -- value -> row of each menu

-- Server answers that carry a token (nearby players, inspect).
local waiting, nextToken = {}, 0

function UI.answer(token, ...)
	local box = waiting[token]
	if not box then return end
	waiting[token] = nil
	box.values, box.done = table.pack(...), true
end

local function ask(event, ...)
	nextToken = nextToken + 1
	local token = nextToken
	local box = { done = false }
	waiting[token] = box
	TriggerServerEvent(event, token, ...)
	local deadline = GetGameTimer() + 5000
	while not box.done and GetGameTimer() < deadline do Wait(50) end
	waiting[token] = nil
	if not box.done then return nil end
	return table.unpack(box.values, 1, box.values.n)
end

local function send(action, data)
	TriggerServerEvent('opx_inventory:action', action, data)
end

-- Rows ---------------------------------------------------------------------------------------

local function rowKey(row)
	return row.instance or ('stack:' .. tostring(row.item))
end

local function rowLabel(row)
	local label = Locale.itemLabel(row.item)
	if row.info and row.info.serial then label = ('%s #%s'):format(label, row.info.serial) end
	return label
end

local function rowRight(row)
	local def = Catalogue.get(row.item)
	local weight = def and Locale.weight((def.weightG or 0) * row.count) or '?'
	local text = row.count > 1 and ('x%d · %s'):format(row.count, weight) or weight
	if row.info and row.info.equipped then
		text = L('equipped')
		if row.info.ammo then text = ('%s · %d'):format(text, row.info.ammo) end
	end
	return text
end

local function rowIcon(row)
	local def = Catalogue.get(row.item)
	if def and def.weapon then return 'gun' end
	if row.instance then return 'card' end
	return 'box'
end

local function sortRows(rows)
	local list = {}
	for i, row in ipairs(rows or {}) do list[i] = row end
	table.sort(list, function(a, b)
		local la, lb = rowLabel(a), rowLabel(b)
		if la ~= lb then return la < lb end
		return rowKey(a) < rowKey(b)
	end)
	return list
end

local function subtitle(v)
	return ('%s / %s · %d/%d'):format(Locale.weight(v.weightG), Locale.weight(v.capacityG), v.used or 0, v.slots or 0)
end

-- Menu elements of a view's rows; `map` gets value -> row (the menu hands back its own element tables).
local function elementsOf(rows, prefix, map)
	local out = {}
	for _, row in ipairs(sortRows(rows)) do
		local value = (prefix or '') .. rowKey(row)
		map[value] = row
		out[#out + 1] = {
			label = rowLabel(row), value = value,
			icon = rowIcon(row), rightLabel = rowRight(row), description = Locale.itemDescription(row.item),
		}
	end
	return out
end

-- Asks a quantity (1..max); 1 without asking when there is only one.
local function amount(row, title)
	if row.count <= 1 or row.instance then return 1 end
	local values = Dialog.inputDialog(title, {
		{ type = 'number', label = L('amount'), min = 1, max = row.count, default = 1, required = true },
	})
	local n = values and math.tointeger(tonumber(values[1]))
	if not n or n < 1 or n > row.count then return nil end
	return n
end

-- Inspect ------------------------------------------------------------------------------------

local function valueText(value)
	if type(value) == 'table' then
		local ok, text = pcall(Open77.json.encode, value)
		return ok and text:sub(1, 60) or '{...}'
	end
	if type(value) == 'boolean' then return L(value and 'yes' or 'no') end
	return tostring(value):sub(1, 60)
end

local function inspect(row, parent)
	local def = Catalogue.get(row.item) or {}
	local elements = {
		{ label = L('inspect_item'), value = 'item', rightLabel = Locale.itemLabel(row.item), icon = 'info' },
		{ label = L('inspect_weight'), value = 'weight', rightLabel = Locale.weight((def.weightG or 0) * row.count), icon = 'info' },
	}
	if row.instance then
		local _, item, meta = ask('opx_inventory:inspect', row.instance)
		if not item then
			elements[#elements + 1] = { label = L('inspect_unavailable'), value = 'none', disabled = true }
		else
			local keys = {}
			for key in pairs(type(meta) == 'table' and meta or {}) do keys[#keys + 1] = tostring(key) end
			table.sort(keys)
			if #keys > 0 then elements[#elements + 1] = { type = 'separator', label = L('inspect_meta') } end
			for _, key in ipairs(keys) do
				local labelKey = 'meta_' .. key
				elements[#elements + 1] = {
					label = Locale.has(labelKey) and L(labelKey) or key, value = 'meta:' .. key,
					rightLabel = valueText(meta[key]), icon = 'dot',
				}
			end
		end
	end
	Menu.open({ id = 'opx_inventory_inspect', title = L('inspect'), subtitle = rowLabel(row), parent = parent,
		elements = elements })
end

-- Give ---------------------------------------------------------------------------------------

-- Gives `row` to `target` (a player id), asking the quantity.
function UI.giveTo(row, target)
	local n = amount(row, L('give'))
	if not n then return end
	send('give', { item = row.item, count = n, instance = row.instance, target = target })
end

local function give(row, parent)
	local list = ask('opx_inventory:nearby')
	if type(list) ~= 'table' or #list == 0 then
		pcall(Open77.exports.callSync, 'opx_core', 'Notify', L('error_nobody_near'), 'error')
		return
	end
	local elements = {}
	for _, entry in ipairs(list) do
		elements[#elements + 1] = {
			label = L('player_entry', { id = entry.id }), value = entry.id, icon = 'person',
			rightLabel = ('%.1f m'):format((tonumber(entry.dm) or 0) / 10),
		}
	end
	Menu.open({
		id = 'opx_inventory_give', title = L('give'), subtitle = rowLabel(row), parent = parent, elements = elements,
		onSelect = function(element, menu)
			menu:close()
			UI.giveTo(row, element.value)
		end,
	})
end

-- Show a card --------------------------------------------------------------------------------

-- Shows `row` (a showable item) to a nearby player picked from the list. Nothing changes hands.
local function show(row, parent)
	local list = ask('opx_inventory:nearby')
	if type(list) ~= 'table' or #list == 0 then
		pcall(Open77.exports.callSync, 'opx_core', 'Notify', L('error_nobody_near'), 'error')
		return
	end
	local elements = {}
	for _, entry in ipairs(list) do
		elements[#elements + 1] = {
			label = L('player_entry', { id = entry.id }), value = entry.id, icon = 'person',
			rightLabel = ('%.1f m'):format((tonumber(entry.dm) or 0) / 10),
		}
	end
	Menu.open({
		id = 'opx_inventory_show', title = L('show'), subtitle = rowLabel(row), parent = parent, elements = elements,
		onSelect = function(element, menu)
			menu:close()
			send('show', { item = row.item, instance = row.instance, target = element.value })
		end,
	})
end

-- Shows the first showable item of the pockets to `target` (the targeting eye's "Show ID").
function UI.showTo(target)
	send('show', { target = target })
end

-- Fields the server sent: the usual card keys first, then the others by name.
local FIELD_ORDER = { 'name', 'birthdate', 'citizenId' }

function UI.shown(item, fields)
	local title = Locale.itemLabel(item)
	local parts, seen = {}, {}
	local function add(key)
		local value = fields[key]
		if seen[key] or (type(value) ~= 'string' and type(value) ~= 'number') then return end
		seen[key] = true
		local labelKey = 'meta_' .. key
		parts[#parts + 1] = ('%s: %s'):format(Locale.has(labelKey) and L(labelKey) or key, tostring(value):sub(1, 64))
	end
	for _, key in ipairs(FIELD_ORDER) do add(key) end
	local rest = {}
	for key in pairs(fields) do if type(key) == 'string' and not seen[key] then rest[#rest + 1] = key end end
	table.sort(rest)
	for i = 1, math.min(#rest, 8) do add(rest[i]) end
	local text = #parts > 0 and table.concat(parts, ' · ') or (Locale.itemDescription(item) or title)
	local seconds = type(Config.show) == 'table' and tonumber(Config.show.seconds) or 10
	local duration = math.floor(math.max(1, math.min(seconds, 60)) * 1000)
	if pcall(Open77.exports.callSync, 'opx_core', 'Notify', text, 'info', duration, title) then return end
	pcall(Open77.hud.notify, ('%s: %s'):format(title, text))
end

-- Give cash ----------------------------------------------------------------------------------

local function cashEnabled()
	return type(Config.cash) == 'table' and Config.cash.enabled == true
end

-- The character's cash as opx_core's client knows it (synced by the server), 0 when unknown. `accounts`: a
-- fresher copy (opx:setPlayerData) when the caller has one.
local function cashBalance(accounts)
	local account = type(Config.cash) == 'table' and type(Config.cash.account) == 'string' and Config.cash.account or 'money'
	if type(accounts) ~= 'table' then
		local ok, data = pcall(Open77.exports.callSync, 'opx_core', 'GetPlayerData')
		accounts = ok and type(data) == 'table' and type(data.accounts) == 'table' and data.accounts or {}
	end
	local n = tonumber(accounts[account])
	if not n or n ~= n or n == math.huge or n == -math.huge then return 0 end
	return math.max(0, math.floor(n))
end

local function formatMoney(amount)
	local ok, text = pcall(Open77.exports.callSync, 'opx_core', 'FormatMoney', amount)
	return ok and type(text) == 'string' and text or tostring(amount)
end
UI.formatMoney = formatMoney

local function notifyError(key)
	pcall(Open77.exports.callSync, 'opx_core', 'Notify', L(key), 'error')
end

-- Asks the amount (1..min(cash, Config.cash.max)) and sends it to `target` (a player id). The server checks
-- everything again (balance, distance, bucket, alive).
function UI.giveCashTo(target)
	if not cashEnabled() then return end
	local cash = cashBalance()
	local max = math.min(cash, math.tointeger(tonumber(Config.cash.max)) or 1000000)
	if max < 1 then return notifyError('error_insufficient_funds') end
	local values = Dialog.inputDialog(L('give_cash'), {
		{ type = 'number', label = L('cash_amount'), description = L('cash_balance', { amount = formatMoney(cash) }),
		  min = 1, max = max, default = 1, required = true },
	})
	if not values then return end
	local n = math.tointeger(tonumber(values[1]))
	if not n or n < 1 or n > max then return notifyError('error_invalid_amount') end
	send('givecash', { target = target, amount = n })
end

-- The pockets' "Cash" row: nearby players, then the amount.
local function giveCash(parent)
	local list = ask('opx_inventory:nearby')
	if type(list) ~= 'table' or #list == 0 then return notifyError('error_nobody_near') end
	local elements = {}
	for _, entry in ipairs(list) do
		elements[#elements + 1] = {
			label = L('player_entry', { id = entry.id }), value = entry.id, icon = 'person',
			rightLabel = ('%.1f m'):format((tonumber(entry.dm) or 0) / 10),
		}
	end
	Menu.open({
		id = 'opx_inventory_givecash', title = L('give_cash'), subtitle = formatMoney(cashBalance()), parent = parent,
		elements = elements,
		onSelect = function(element, menu)
			menu:close()
			UI.giveCashTo(element.value)
		end,
	})
end

-- Row actions --------------------------------------------------------------------------------

local function openActions(row, parent)
	local def = Catalogue.get(row.item) or {}
	local elements = {}
	if Catalogue.usable(row.item) then elements[#elements + 1] = { label = L('use'), value = 'use', icon = 'hand' } end
	if def.weapon and row.instance then
		if row.info and row.info.equipped then
			elements[#elements + 1] = { label = L('unequip'), value = 'unequip', icon = 'gun' }
		else
			elements[#elements + 1] = { label = L('equip'), value = 'equip', icon = 'gun' }
		end
	end
	elements[#elements + 1] = { label = L('give'), value = 'give', icon = 'group' }
	if def.showable and type(Config.show) == 'table' and Config.show.enabled == true then
		elements[#elements + 1] = { label = L('show'), value = 'show', icon = 'card', description = L('show_help') }
	end
	elements[#elements + 1] = { label = L('inspect'), value = 'inspect', icon = 'search' }
	elements[#elements + 1] = { label = L('drop'), value = 'drop', icon = 'trash', description = L('drop_help') }

	child, childKey = Menu.open({
		id = 'opx_inventory_row', title = rowLabel(row), subtitle = rowRight(row), parent = parent, elements = elements,
		onSelect = function(element, menu)
			local action = element.value
			if action == 'inspect' then return inspect(row, menu) end
			if action == 'give' then return give(row, menu) end
			if action == 'show' then return show(row, menu) end
			if action == 'drop' then
				local n = amount(row, L('drop'))
				if not n then return end
				local yes = Menu.confirm({ title = L('drop'), message = L('drop_confirm', { count = n, item = rowLabel(row) }),
					confirmLabel = L('drop'), cancelLabel = L('cancel') })
				if not yes then return end
				menu:close()
				return send('drop', { item = row.item, count = n, instance = row.instance })
			end
			menu:close()
			if action == 'use' then send('use', { item = row.item, count = 1, instance = row.instance })
			else send(action, { instance = row.instance, item = row.item }) end
		end,
		onClose = function(closed) if child == closed then child, childKey = nil, nil end end,
	}), rowKey(row)
end

-- Pockets ------------------------------------------------------------------------------------

local CASH_ROW = 'cash' -- never a row key (those are instance ids or 'stack:<item>')

local function cashElement()
	return { label = L('cash'), value = CASH_ROW, icon = 'money', rightLabel = formatMoney(cashBalance()),
		description = L('cash_help') }
end

local function mainElements(v)
	mainRows = {}
	local elements = elementsOf(v.rows, nil, mainRows)
	if #elements == 0 then elements[1] = { label = L('empty'), value = 'empty', disabled = true, icon = 'box' } end
	if cashEnabled() then table.insert(elements, 1, cashElement()) end
	return elements
end

-- opx_core synced new balances: the "Cash" row of an open pockets menu follows.
function UI.refreshCash(accounts)
	if not cashEnabled() or not (main and main:isOpen()) then return end
	main:updateElement(CASH_ROW, { rightLabel = formatMoney(cashBalance(accounts)) })
end

-- Shows (open = true) or refreshes the pockets menu with a view from the server.
function UI.showPockets(v, open)
	if type(v) ~= 'table' or type(v.rows) ~= 'table' then return end
	view = v
	if main and main:isOpen() then
		main:setElements(mainElements(v), true)
		main:setTitle(L('title'), subtitle(v))
		-- The row of an open submenu is gone (given, used up): back to the list.
		if child and child:isOpen() then
			local still = false
			for _, row in ipairs(v.rows) do if rowKey(row) == childKey then still = true end end
			if not still then child:close() end
		end
		return
	end
	if not open then return end
	local menu, reason = Menu.open({
		id = 'opx_inventory', title = L('title'), subtitle = subtitle(v), elements = mainElements(v),
		onSelect = function(element, menu)
			if element.value == CASH_ROW then return giveCash(menu) end
			local row = mainRows[element.value]
			if row then openActions(row, menu) end
		end,
		onClose = function(closed)
			if main ~= closed then return end
			main = nil
			TriggerServerEvent('opx_inventory:close')
		end,
	})
	if not menu then print('[opx_inventory] menu not opened: ' .. tostring(reason)) end
	main = menu
end

function UI.toggle()
	if main and main:isOpen() then return main:close() end
	TriggerServerEvent('opx_inventory:open')
end

function UI.pockets()
	return view
end

-- Stash --------------------------------------------------------------------------------------

function UI.showStash(name, label, box, pockets)
	if type(box) ~= 'table' or type(pockets) ~= 'table' then return end
	view = pockets
	stashRows = {}
	local elements = { { type = 'separator', label = L('stash_take') } }
	for _, e in ipairs(elementsOf(box.rows, 's:', stashRows)) do elements[#elements + 1] = e end
	if #box.rows == 0 then elements[#elements + 1] = { label = L('empty'), value = 'empty_s', disabled = true } end
	elements[#elements + 1] = { type = 'separator', label = L('stash_put') }
	for _, e in ipairs(elementsOf(pockets.rows, 'p:', stashRows)) do elements[#elements + 1] = e end
	if #pockets.rows == 0 then elements[#elements + 1] = { label = L('empty'), value = 'empty_p', disabled = true } end

	local title = type(label) == 'string' and label ~= '' and label or L('stash')
	if stashMenu and stashMenu:isOpen() and stashName == name then
		stashMenu:setElements(elements, true)
		stashMenu:setTitle(title, subtitle(box))
		return
	end
	stashName = name
	stashMenu = Menu.open({
		id = 'opx_inventory_stash', title = title, subtitle = subtitle(box), elements = elements,
		onSelect = function(element)
			local row = stashRows[element.value]
			if not row then return end
			local take = element.value:sub(1, 2) == 's:'
			local n = amount(row, L(take and 'stash_take' or 'stash_put'))
			if not n then return end
			send(take and 'take' or 'put', { stash = name, item = row.item, count = n, instance = row.instance })
		end,
		onClose = function(closed)
			if stashMenu ~= closed then return end
			stashMenu, stashName = nil, nil
			TriggerServerEvent('opx_inventory:stashClose')
		end,
	})
end

-- Staff view (read-only) ---------------------------------------------------------------------

function UI.showStaff(target, v)
	if type(v) ~= 'table' or type(v.rows) ~= 'table' then return end
	staffRows = {}
	local elements = elementsOf(v.rows, nil, staffRows)
	if #elements == 0 then elements[1] = { label = L('empty'), value = 'empty', disabled = true } end
	Menu.open({
		id = 'opx_inventory_staff', title = L('staff_title', { id = target }), subtitle = subtitle(v), elements = elements,
		onSelect = function(element, menu)
			local row = staffRows[element.value]
			if row then inspect(row, menu) end
		end,
		onClose = function() TriggerServerEvent('opx_inventory:close') end,
	})
end

function UI.closeAll()
	Menu.closeAll()
	main, child, stashMenu = nil, nil, nil
end

return UI
