---@meta
-- opx_inventory: LuaLS annotations of the public contract (not loaded by the manifest).
-- A replacement inventory implements these server exports with the same names, arguments, answers and
-- synchronous behaviour. Container ids: pockets 'char:<citizenId>', stashes 'stash:<name>'.

---@class OpxInventoryRow
---@field item string       item id (catalogue key)
---@field count integer     1 for an instance
---@field instance? string  instance id of a unique / metadata item ('<item>_<base36>', never reused)
---@field meta? table       a copy of its metadata (instances only)
---@field weightG? integer  weight of ONE, from the catalogue (nil for an item outside the catalogue)

---@class OpxInventoryItem
---@field item string
---@field count integer                 stack + instances
---@field instances table<string, table> instanceId -> copy of its metadata

---@class OpxStashOptions
---@field label? string      menu title (48 bytes)
---@field capacityG? integer default Config.stash.capacityG
---@field slots? integer     default Config.stash.slots (1..200)

-- Reasons: not_loaded, not_ready, invalid_player, unknown_item, invalid_count, invalid_meta, reserved_key,
-- not_found, not_enough, too_many, too_heavy, no_slot, max_stack, target_too_heavy / target_no_slot /
-- target_max_stack, target_not_loaded, invalid_target, invalid_name, invalid_export, export_call_required.
-- RegisterItem / UnregisterItem add: invalid_item, invalid_definition, item_taken, item_limit, not_owner.
-- GiveCash adds: disabled, invalid_amount, same_player, insufficient_funds, unknown_account, core_unavailable.

-- Every export is SYNCHRONOUS: it reads and changes the server's memory and never waits (rows are written
-- to opx_inventories a few seconds later by a timer). Call it with exports.opx_inventory:Name(...) or
-- Open77.exports.callSync('opx_inventory', 'Name', ...), from a thread or not.
-- Open77.exports.call(...):await() keeps working too.

---@class OpxInventoryServerExports
local server = {}

-- Item ids: [a-z0-9_]. Sync results larger than about 48 KiB raise: keep pockets small (slots) and metadata short.
-- Storage: table opx_inventories (id, items JSON { stacks = { [item] = count }, instances = { [id] = { item, meta } } },
-- updated_at). Weapon instance meta: { serial, ammo (rounds in the magazine), equipped (slot or false) }.
-- Weapons are client state: a disconnect between two ammo syncs (Config.weapons.syncSeconds) keeps the last synced ammo.

-- Creates items in the player's pockets. `meta` makes each one an instance (unique items always are);
-- a stack item given with metadata becomes instances.
-- characterMeta items (id_card) are filled from the character when meta is nil.
-- Metadata: plain data, string keys, <= 2048 bytes encoded, depth <= 4.
---@return boolean ok, string? reason
function server.AddItem(source, item, count, meta) end

-- Destroys items. Without instanceId, a stack is taken first, else instances by count (unequipped first).
-- An equipped weapon leaves the hands at once (its magazine keeps the last synced value).
---@return boolean ok, string? reason
function server.RemoveItem(source, item, count, instanceId) end

-- Every row of the pockets.
---@return OpxInventoryRow[]|nil rows, string? reason
function server.GetItems(source) end

---@return OpxInventoryItem|nil item, string? reason
function server.GetItem(source, item) end

-- count defaults to 1.
---@return boolean
function server.HasItem(source, item, count) end

-- Weight, slots and maxStack of the pockets.
---@return boolean ok, string? reason
function server.CanCarry(source, item, count) end

-- Shallow merge into an instance of the player's pockets. The weapon keys equipped, serial and ammo
-- belong to the inventory (reserved_key). The merged metadata must stay within the limits above.
---@return boolean ok, string? reason
function server.SetItemMeta(source, instanceId, metaPatch) end

-- When a player uses `item`, the CALLER's export `exportName(source, item, instanceId, meta)` runs
-- (async call, may yield); returning true consumes one. Owned by the calling resource and its VM
-- generation: dropped when it stops, a hot reload registering again keeps it.
-- A registered handler makes the item usable: the menu shows "Use" even without `usable = true`.
-- The inventory has no built-in effect: an item does something only through its RegisterUsable owner
-- (food / drink: opx_needs, bandage / medkit: opx_medical). Register on the same two moments as RegisterItem.
---@return boolean ok, string? reason
function server.RegisterUsable(item, exportName) end

-- Opens stash:<name> ([a-z0-9_.-], 48 chars) and shows put / take to the player while they stay within
-- Config.stash.maxDistance of where it opened. The caller decides who may open it. true = shown now, or as
-- soon as its row is read when nobody had it open (a failed read is notified to the player).
---@param options? OpxStashOptions
---@return boolean ok, string? reason
function server.OpenStash(source, name, options) end

-- Pockets of `source` -> pockets of `target` in one step. No distance check (the caller's).
---@return boolean ok, string? reason
function server.GiveItemTo(source, target, item, count, instanceId) end

-- Cash (Config.cash.account, 'money' by default) of `source` -> `target`, all or nothing, through opx_core's
-- TransferMoney (reason 'give'). amount: integer 1..Config.cash.max. No distance check (the caller's).
-- Reasons: invalid_player, disabled (Config.cash.enabled = false), invalid_amount, same_player, and opx_core's
-- not_loaded, target_not_loaded, insufficient_funds, unknown_account; core_unavailable when opx_core did not answer.
---@return boolean ok, string? reason
function server.GiveCash(source, target, amount) end

---@class OpxItemDefinition
---@field item string
---@field label string|table       as registered: a string or { en = '...', fr = '...' }
---@field description? string|table
---@field weightG integer           weight of one, in grams
---@field unique boolean            each one is an instance with metadata
---@field usable boolean
---@field maxStack? integer
---@field weapon boolean            the item is a weapon
---@field showable boolean          "Show" lets a nearby player read it (added with RegisterItem)
---@field resource string           the resource that registered it (RegisterItem)

---@class OpxItemRegistration
---@field label string|table          1..64 bytes, or { en = '...', fr = '...' } (2-letter codes, 4 at most)
---@field description? string|table   1..200 bytes per language, same shapes
---@field weightG integer              0..1000000 grams
---@field unique? boolean              each one is an instance with metadata
---@field maxStack? integer
---@field usable? boolean              shows "Use" (the effect comes from your RegisterUsable handler)
---@field showable? boolean
---@field weapon? string              TweakDB record, 1..128 chars [%w_.] (e.g. 'Items.Preset_Lexington_Default'):
---                                   the item is a weapon (Equip / Unequip), always unique, meta { serial, ammo, equipped }
---@field ammo? string                weapons only: item id of the STACK item its rounds come from (may be registered
---                                   later, by you or another resource; a unique ammo item is ignored)
---@field characterMeta? boolean      an instance given without metadata is filled from the receiving character
---                                   (name, citizenId, birthdate), like id_card
-- Any other key (effect...) is refused with invalid_definition.

-- OPTIONAL members of the inventory contract (added later: a replacement inventory may lack them, so callers
-- use pcall and fall back, e.g. to the item id): GetItemDefinition, GetItemNames, RegisterItem, UnregisterItem
-- here, the client exports GetItemLabel / GetItemDescription / GetItemNames / GetItemCount / HasItem / GetItems,
-- the host events opx:inventory:changed / itemRegistered / itemUnregistered and the client net event
-- opx:inventory:counts below. All SYNCHRONOUS.

-- A copy of the catalogue entry, or nil for an unknown item. `usable` is also true when
-- a RegisterUsable handler exists.
---@return OpxItemDefinition|nil
function server.GetItemDefinition(item) end

-- Sorted ids of the whole catalogue. Names only: GetItemDefinition per item.
---@return string[]
function server.GetItemNames() end

-- Adds `item` ([a-z0-9_], 48 max) to the catalogue, owned by the calling resource (GetInvokingResource + its
-- VM generation). The same owner may call again to replace it. 64 items per resource, 500 in all (item_limit).
-- There is NO item config: every item exists only because a resource registered it (opx_inventory registers
-- id_card itself). item_taken: owned by another running resource. When the owner stops, its items STAY
-- in the catalogue (pockets keep their weight and label) and only the claim goes: another resource may then
-- take the id. Register on your own start AND on onResourceStart of the inventory provider (an opx_inventory
-- restart forgets every item). Get the provider with exports.opx_core:GetProvider('inventory') (pcall; do
-- nothing when absent), never a hard-coded name. Clients learn it within about a quarter of a second.
-- A weapon equipped at the last unload whose item is registered after the pockets loaded goes back in the hands
-- at that RegisterItem. Starter items (Config.starterItems) not registered when a kit is given are skipped.
-- Never change `unique` of an item players already hold.
---@param definition OpxItemRegistration
---@return boolean ok, string? reason
function server.RegisterItem(item, definition) end

-- Removes a runtime item the caller owns (not_owner otherwise, unknown_item). Pockets and stashes keep what
-- they hold: it weighs nothing and shows its id until the item is registered again.
---@return boolean ok, string? reason
function server.UnregisterItem(item) end

-- Host events (server), OPTIONAL members of the contract:
--   opx:inventory:itemRegistered (item, resource)   after each RegisterItem that succeeded (new or replaced)
--   opx:inventory:itemUnregistered (item)

-- Host event (server), OPTIONAL member of the contract:
--   opx:inventory:changed (source, item, delta)
-- Raised once per change of a loaded character's pockets, after the change: delta is a positive or negative
-- integer (the count added or taken). Covers AddItem / RemoveItem / GiveItemTo, menu use / give / destroy,
-- stash put / take, the giveitem / giveweapon / removeitem commands and the starter kit. Not raised for stash-only
-- changes, the rounds a weapon burns from its ammo stack, or clearinventory.
-- AddEventHandler('opx:inventory:changed', function(source, item, delta) end)

---@class OpxInventoryClientExports
local client = {}

-- Localised label of an item (the menu's language), nil when the item is not in the catalogue. OPTIONAL member.
---@return string|nil
function client.GetItemLabel(item) end

-- Localised description, nil when none. OPTIONAL member.
---@return string|nil
function client.GetItemDescription(item) end

-- What the player carries, from the last server snapshot (no callback). Display only: the server checks
-- again. 0 / false / {} before the pockets loaded and after opx:playerUnloaded. OPTIONAL members, SYNCHRONOUS.

-- Sorted ids of the catalogue as this client knows it.
---@return string[]
function client.GetItemNames() end

-- Total of `item` in the pockets (stack + instances), 0 when unknown.
---@return integer
function client.GetItemCount(item) end

-- count defaults to 1.
---@return boolean
function client.HasItem(item, count) end

-- Totals per item, sorted by item, no metadata.
---@return { item: string, count: integer }[]
function client.GetItems() end

-- Client net event, OPTIONAL member of the contract (any resource's client may listen):
--   opx:inventory:counts (counts)   counts = { [item] = total }, the WHOLE table of the pockets
-- Sent when the pockets load, on the client's (re)start, and after any change of the pockets (including
-- clearinventory and burnt ammo), at most once per 250 ms per player.
-- RegisterNetEvent('opx:inventory:counts', function(counts) end)
-- Internal (not a contract): opx_inventory:items (list, piece, pieces, rev, usables), opx_inventory:hello.

-- Client: `targetGive(ctx)`, `targetGiveCash(ctx)` and `targetShow(ctx)` are the callbacks opx_target calls for
-- the player options (not a contract).
