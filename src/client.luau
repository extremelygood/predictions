--!strict

--[[
	The client: actions change the stores at once, and the server's messages correct them.

	WHAT IS SHOWN. The stores show the server's entries with the client's unconfirmed actions on top. An entry no
	pending action wrote is the server's entry itself. An entry a pending action wrote shows that action's result.

	WHAT IS KEPT. For every entry the stores show a prediction of, the server's own version of it is kept aside: the
	entry as the server last told it, or "absent" when the server has no such entry. The kept entries and the pending
	actions, each with the keys it read and wrote, are all the overlay holds. Nothing walks a whole table except an
	action without a scope, which sees every table whole.

	DISPATCH. The action is validated and worked out on what the stores show. For each key it changes, the server's
	entry is kept aside unless one is kept already. Then the result is written, the envelope sent and the effects
	delivered, and the action is pending until the server acknowledges its sequence.

	A MESSAGE, in one Charm.batch so readers wake once, after it:
	(a) Every change in it is applied to the server's side: to the kept entry for a key kept aside, straight into the
	    store for any other key.
	(b) The pending actions the acknowledgement covers are dropped.
	(c) When some are still pending and either the acknowledgement advanced or the message touched a key a pending
	    action read or wrote, the pending actions are worked out again, in order, on the server's side with each
	    other's results: a key reads an earlier replay's result, else its kept entry, else the store. A key a replay
	    writes that is not kept yet is kept aside from the store first. Replays deliver no effects; a rejected one
	    changes nothing and stays pending until acknowledged.
	(d) Each kept key is shown again: the replays' result when one wrote it, else the server's entry, written only when
	    it differs (deep) from what the store shows. Keys no replay wrote are forgotten. With nothing pending, that
	    puts every kept entry back.
	When actions are still pending and the message touched nothing they read or wrote, (c) and (d) are skipped: what
	the stores show of their keys is still right.
]]

local Charm = require(script.Parent.Parent.Charm)
local EffectScope = require(script.Parent["_effect-scope"])
local ActionState = require(script.Parent._state)
local Types = require(script.Parent._types)
local Wire = require(script.Parent._wire)

-- Keys by table name.
type Keys = { [string]: { [string]: true } }

-- The server's version of an entry, kept aside. `entry` nil: the server has no such entry.
type Held = { entry: any }

-- What an action read and wrote when it was last worked out: keys by table name, and whether it saw every table whole
-- (an action without a scope), when any key counts.
type Touched = { keys: Keys, whole: boolean }

type Pending = {
	definition: Types.ActionDefinition<any, any, any>,
	actor: any,
	payload: any,
	sequence: number,
	actionTime: number,
	touched: Touched,
}

-- Entries by table name and key: an entry, or false for a removal.
type Changes = ActionState.Changes

local function traceback(message: any): string
	return debug.traceback(tostring(message), 2)
end

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function mark(keys: Keys, name: string, key: string)
	local set = keys[name]
	if set == nil then
		set = {}
		keys[name] = set
	end
	(set :: { [string]: true })[key] = true
end

local function validatePayload(definition: Types.ActionDefinition<any, any, any>, payload: any): boolean
	local succeeded, result = xpcall(definition.validate, traceback, payload)
	if not succeeded then
		warn(`[Predictions] Validator for action "{definition.id}" failed:\n{result}`)
		return false
	end
	return result == true
end

local function createClient<State, Actor>(config: Types.ClientConfig<State, Actor>): Types.ClientRuntime<State, Actor>
	assert(type(config) == "table", "[Predictions] Client config must be a table")
	assert(type(config.tables) == "table", "[Predictions] Client config must define tables")
	assert(type(config.send) == "function", "[Predictions] Client config must define send")
	assert(type(config.now) == "function", "[Predictions] Client config must define now")
	assert(
		config.scope == nil or type(config.scope) == "function",
		"[Predictions] Client config scope must be a function"
	)

	local tables = config.tables
	local send = config.send
	local now = config.now
	local defaultScope = config.scope :: any

	-- The keyed store of every table; a value table's is the one underneath, its entry under VALUE_KEY.
	local stores: { [string]: Types.KeyedStore<string, any> } = {}
	-- The server's entries kept aside, by table name and key.
	local kept: { [string]: { [string]: Held } } = {}
	for name, given in tables do
		local store: any = (given :: any)._keyed or given
		assert(
			type(store) == "table" and type(store._write) == "function",
			`[Predictions] Table "{name}" must be a store made by Predictions.keyed or Predictions.value`
		)
		store._seal()
		stores[name] = store
		kept[name] = {}
	end
	local names = Wire.tableNames(tables)

	local pending: { Pending } = {}
	local nextSequence = 1
	local acknowledged = 0

	local run = ActionState.runner(tables, defaultScope)
	-- The keys the action being worked out reads, noted by `markSeen`.
	local seenKeys: Keys = {}

	local function markSeen(name: string, key: string)
		mark(seenKeys, name, key)
	end

	local function readStore(name: string, key: string): any
		return stores[name].get(key)
	end

	local function storeKeys(name: string): { [string]: any }
		return stores[name].all()
	end

	-- Works an action out on what `read` and `keysOf` give, noting what it read and wrote.
	local function work(
		definition: Types.ActionDefinition<any, any, any>,
		actor: any,
		payload: any,
		actionTime: number,
		read: ActionState.Read,
		keysOf: (name: string) -> { [string]: any }
	): (Changes?, Types.EffectCollector, Touched)
		local touched: Touched = { keys = {}, whole = (definition.scope or defaultScope) == nil }
		-- Put back after, for an action worked out from inside another's scope.
		local outerKeys = seenKeys
		seenKeys = touched.keys
		local changes, effects = run(definition, actor, payload, actionTime, read, keysOf, markSeen)
		seenKeys = outerKeys
		if changes ~= nil then
			for name, entries in changes do
				for key in entries do
					mark(touched.keys, name, key)
				end
			end
		end
		return changes, effects, touched
	end

	local function dispatchAction(definition: Types.ActionDefinition<any, any, any>, actor: any, payload: any): boolean
		if not validatePayload(definition, payload) then
			return false
		end

		local actionTime = now()
		-- Not assert: its message would be built on every call.
		if not isFiniteNumber(actionTime) then
			error(`[Predictions] Clock returned an invalid timestamp for action "{definition.id}"`, 0)
		end

		local changes, effects, touched = work(definition, actor, payload, actionTime, readStore, storeKeys)
		if changes == nil then
			return false
		end

		for name, entries in changes do
			local keptTable = kept[name]
			for key in entries do
				if keptTable[key] == nil then
					keptTable[key] = { entry = readStore(name, key) }
				end
			end
		end
		if next(changes) ~= nil then
			ActionState.write(stores, changes)
		end

		local sequence = nextSequence
		nextSequence += 1
		table.insert(pending, {
			definition = definition,
			actor = actor,
			payload = payload,
			sequence = sequence,
			actionTime = actionTime,
			touched = touched,
		})
		send({
			actionId = definition.id,
			actor = actor,
			payload = payload,
			sequence = sequence,
			actionTime = actionTime,
		})
		EffectScope.deliver(effects)
		return true
	end

	local function dispatch<Payload>(
		definition: Types.ActionDefinition<State, Payload, Actor>,
		actor: Actor,
		payload: Payload
	): boolean
		-- Untracked, so a dispatch from inside an effect subscribes it to nothing.
		return Charm.untracked(dispatchAction, definition :: any, actor :: any, payload :: any)
	end

	-- (a) Applies the message's changes to the server's side. Returns the keys it touched.
	local function applyToAuthority(message: Wire.Message): Keys
		local incoming: Keys = {}
		for index, part in message.tables do
			local name = names[index]
			if name == nil then
				warn(`[Predictions] Ignored the changes to table {index}: this client has no table at that position`)
				continue
			end
			local store = stores[name]
			local keptTable = kept[name]
			-- What goes straight into the store: an entry, or false for a removal.
			local direct: { [string]: any } = {}

			local function current(key: string): any
				local held = keptTable[key]
				if held ~= nil then
					return held.entry
				end
				local written = direct[key]
				if written ~= nil then
					return if written == false then nil else written
				end
				return store.get(key)
			end

			local function take(key: string, entry: any)
				mark(incoming, name, key)
				local held = keptTable[key]
				if held ~= nil then
					held.entry = entry
				else
					direct[key] = if entry == nil then false else entry
				end
			end

			if part.whole ~= nil then
				for key, entry in part.whole do
					take(key, entry)
				end
			end
			if part.diffs ~= nil then
				for key, change in part.diffs do
					take(key, Wire.apply(current(key), change))
				end
			end
			if part.gone ~= nil then
				for _, key in part.gone do
					take(key, nil)
				end
			end
			if next(direct) ~= nil then
				store._write(direct)
			end
		end
		return incoming
	end

	-- (b) Drops the pending actions the acknowledgement covers.
	local function dropAcknowledged(ack: number)
		local remaining: { Pending } = {}
		for _, action in pending do
			if action.sequence > ack then
				table.insert(remaining, action)
			end
		end
		pending = remaining
	end

	local function touchesPending(incoming: Keys): boolean
		for _, action in pending do
			if action.touched.whole and next(incoming) ~= nil then
				return true
			end
			for name, keys in incoming do
				local touched = action.touched.keys[name]
				if touched ~= nil then
					for key in keys do
						if touched[key] then
							return true
						end
					end
				end
			end
		end
		return false
	end

	-- (c) Works the pending actions out again on the server's side. Returns the entries they wrote: an entry, or false
	-- for a removal.
	local function replay(): Changes
		local results: Changes = {}

		local function readAuthority(name: string, key: string): any
			local tableResults = results[name]
			local result = if tableResults ~= nil then tableResults[key] else nil
			if result ~= nil then
				return if result == false then nil else result
			end
			local held = kept[name][key]
			if held ~= nil then
				return held.entry
			end
			return stores[name].get(key)
		end

		-- The keys on the server's side: the store's and the kept ones. Only an action seeing every table whole asks.
		local function authorityKeys(name: string): { [string]: any }
			local keptTable = kept[name]
			if next(keptTable) == nil then
				return stores[name].all()
			end
			local keys: { [string]: any } = {}
			for key in stores[name].all() do
				keys[key] = true
			end
			for key in keptTable do
				keys[key] = true
			end
			return keys
		end

		for _, action in pending do
			local changes, _, touched =
				work(action.definition, action.actor, action.payload, action.actionTime, readAuthority, authorityKeys)
			if changes ~= nil then
				for name, entries in changes do
					local keptTable = kept[name]
					local tableResults = results[name]
					if tableResults == nil then
						tableResults = {}
						results[name] = tableResults
					end
					for key, entry in entries do
						if keptTable[key] == nil then
							keptTable[key] = { entry = stores[name].get(key) }
						end
						(tableResults :: { [string]: any })[key] = entry
					end
				end
			end
			action.touched = touched
		end
		return results
	end

	-- (d) Shows each kept key's replayed result, else its server entry, and forgets the keys no replay wrote.
	local function show(results: Changes)
		for name, keptTable in kept do
			local store = stores[name]
			local tableResults = results[name]
			local writes: { [string]: any } = {}
			for key, held in keptTable do
				local result = if tableResults ~= nil then tableResults[key] else nil
				local shown = if result == nil then held.entry elseif result == false then nil else result
				if not Wire.equal(shown, store.get(key)) then
					writes[key] = if shown == nil then false else shown
				end
				if result == nil then
					keptTable[key] = nil
				end
			end
			if next(writes) ~= nil then
				store._write(writes)
			end
		end
	end

	local function receiveMessage(message: Wire.Message, ack: number)
		local advanced = ack > acknowledged
		acknowledged = ack

		local incoming = applyToAuthority(message)
		dropAcknowledged(ack)
		if pending[1] == nil then
			show({})
		elseif advanced or touchesPending(incoming) then
			show(replay())
		end
	end

	local function receive(raw: unknown)
		local message = Wire.read(raw)
		if message == nil then
			warn("[Predictions] Ignored a message that does not have the layout the server sends")
			return
		end

		local ack = if message.ack ~= nil then message.ack else acknowledged
		assert(
			isFiniteNumber(ack) and ack >= 0 and ack % 1 == 0,
			"[Predictions] Acknowledged sequence must be a non-negative integer"
		)
		assert(ack >= acknowledged, "[Predictions] Acknowledged sequence must not move backwards")
		if ack >= nextSequence then
			error(`[Predictions] Acknowledged sequence {ack} exceeds highest dispatched sequence {nextSequence - 1}`, 0)
		end

		Charm.untracked(Charm.batch, receiveMessage, message, ack)
	end

	return {
		receive = receive,
		dispatch = dispatch,
	}
end

return createClient
