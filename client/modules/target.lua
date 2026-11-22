-- Optional: "Give item", "Give cash" and "Show ID" options on players in opx_target's eye, through its client exports
-- (no manifest dependency). When opx_target does not run, nothing happens; they register again when
-- opx_target starts.

local Menu = assert(require('@opx_menu'))
local Locale = assert(require('client.modules.locale'))

local Target = {}

-- Called by opx_target (export name below): pick an item of the pockets, then give it to that player.
function Target.onGive(ctx)
	local target = type(ctx) == 'table' and type(ctx.target) == 'table' and math.tointeger(tonumber(ctx.target.playerId))
	if not target or target < 1 then return end
	local UI = Target.ui
	local before = UI.pockets()
	TriggerServerEvent('opx_inventory:refresh') -- fresh rows, without opening the pockets menu
	local deadline = GetGameTimer() + 3000
	while UI.pockets() == before and GetGameTimer() < deadline do Wait(50) end
	local view = UI.pockets()
	if type(view) ~= 'table' or #view.rows == 0 then return end
	local rows, elements = {}, {}
	for i, row in ipairs(view.rows) do
		rows[i] = row
		local label = Locale.itemLabel(row.item)
		if row.info and row.info.serial then label = ('%s #%s'):format(label, row.info.serial) end
		elements[i] = { label = label, value = i, rightLabel = row.count > 1 and ('x%d'):format(row.count) or nil, icon = 'box' }
	end
	Menu.open({
		id = 'opx_inventory_target', title = Locale.t('give'), subtitle = Locale.t('player_entry', { id = target }),
		elements = elements,
		onSelect = function(element, menu)
			local row = rows[element.value]
			menu:close()
			if row then UI.giveTo(row, target) end
		end,
	})
end

-- Called by opx_target (export targetGiveCash): ask the amount, then give it to that player.
function Target.onGiveCash(ctx)
	local target = type(ctx) == 'table' and type(ctx.target) == 'table' and math.tointeger(tonumber(ctx.target.playerId))
	if not target or target < 1 then return end
	Target.ui.giveCashTo(target)
end

-- Called by opx_target (export targetShow): the server shows that player the first showable item of the pockets.
function Target.onShow(ctx)
	local target = type(ctx) == 'table' and type(ctx.target) == 'table' and math.tointeger(tonumber(ctx.target.playerId))
	if not target or target < 1 then return end
	Target.ui.showTo(target)
end

function Target.register()
	if not Config.target then return end
	local distance = tonumber(Config.giveDistance) or 3.0
	local options = {
		{ name = 'opx_inventory_give', label = Locale.t('give'), icon = 'box', distance = distance, onSelect = 'targetGive' },
	}
	if type(Config.cash) == 'table' and Config.cash.enabled == true then
		options[#options + 1] = { name = 'opx_inventory_givecash', label = Locale.t('give_cash'), icon = 'money',
			distance = distance, onSelect = 'targetGiveCash' }
	end
	if type(Config.show) == 'table' and Config.show.enabled == true then
		options[#options + 1] = { name = 'opx_inventory_show', label = Locale.t('show_id'), icon = 'card',
			distance = distance, onSelect = 'targetShow' }
	end
	local pending = Open77.exports.call('opx_target', 'addPlayer', options)
	if not pending then return end -- opx_target is not running
	local id, reason = pending:await()
	if not id then print('[opx_inventory] opx_target refused the give options: ' .. tostring(reason)) end
end

return Target
