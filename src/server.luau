--!strict

--[[
	The server runtime: it works actions out on the stores and, once a frame, tells each client what changed in what
	he may see.

	ACTIONS. `receive` takes a client's envelope. Its sequence must be the next one from that client: a stale or an
	early one is warned about and ignored. The expected one is acknowledged first, whatever then happens to the action;
	the acknowledgement goes out with the client's next message, his first one when he is not added yet. Then the
	action must be allowed, pass `validate`, the client must be allowed to act as the envelope's actor (`isActor`) and
	the game's `accept` must agree. Its time is clamped to `now() - maxAge .. now() + maxLead` (without `actionTime`
	in the config it is the server's `now()`). The action is then worked out (_state.luau) and its changes written in
	one Charm.batch, after which its effects are delivered. `dispatch` is the server's own action: no `allow`, no
	`validate`, the time is `now()`; it returns whether the action was accepted, true also when it changes nothing.

	MARKS. Every write to a table is recorded as it happens: per key, the entry it held before its first write since
	the last flush. `flush` works each marked key's change out once (gone, whole when it is new, else the diff;
	nothing when it ends deep-equal to where it began, or when it was created and removed again) and shares it between
	the clients.

	VIEWS. Decided at flush, never at a write. In a `true` table every added client holds every entry. For a rule
	table each client has the set of keys he was sent; a marked key is visible and sent: its diff; visible and not
	sent: whole, now sent; sent and not visible: gone, no longer sent; neither: nothing, so a client never hears of a
	key he was not sent. The view function runs per client inside an effect; when it has run again since the last
	flush, every key of that table is checked for him the same way. When the view or the rule it returned throws
	(warned), the client sees nothing of that table until his view runs again. A value table has one key, VALUE_KEY
	("v" in store.luau): a rule is called with it and the value.

	JOIN. A client added is sent, at the next flush, every entry he may see, whole.

	FLUSH. One message per client that has something to be told, built before it returns. It must be called outside
	any Charm.batch, so the view effects have run: inside one it errors. Only a join and a view that ran again for a
	client cost the entries of a table; the rest costs what changed.
]]

local Action = require(script.Parent.action)
local Charm = require(script.Parent.Parent.Charm)
local EffectScope = require(script.Parent["_effect-scope"])
local State = require(script.Parent._state)
local Types = require(script.Parent._types)
local Wire = require(script.Parent._wire)

type Rule = (key: string, entry: any) -> boolean

type Table = {
	name: string,
	-- The table's position in the sorted list of names the messages number tables by.
	index: number,
	store: Types.KeyedStore<string, any>,
	view: Types.View<any>,
	-- Per key written since the last flush, the entry it held before its first write; ABSENT when it had none.
	marks: { [string]: any },
	-- At flush: the diff of each marked key that was there before and is there still.
	diffs: { [string]: any },
	-- At flush, for a `true` table: the part every client already holding the table is sent.
	shared: any,
}

type Member = {
	-- Sent everything he may see at the next flush.
	joining: boolean,
	-- Per rule table, the keys he holds.
	sent: { [string]: { [string]: true } },
	-- Per rule table, what his view returned; false when it failed and he sees nothing of the table.
	rules: { [string]: Rule | false },
	-- The rule tables whose view ran since the last flush.
	stale: { [string]: true },
	stops: { () -> () },
}

type Allowed = {
	definition: Types.ActionDefinition<any, any, any>,
	accept: ((client: any, actor: any, payload: any) -> boolean)?,
}

local ABSENT = table.freeze({})

local function traceback(message: any): string
	return debug.traceback(tostring(message), 2)
end

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

-- Whether `check` returns true; false, warned, when it throws.
local function passes(what: string, actionId: string, check: (...any) -> boolean, ...: any): boolean
	local succeeded, result = xpcall(check, traceback, ...)
	if not succeeded then
		warn(`[Predictions] {what} for action "{actionId}" failed:\n{result}`)
		return false
	end
	return result == true
end

-- An effect on a signal written at every flush: it runs at once outside a batch and only at the batch's end inside one.
local probeVersion = 0
local probeRuns = 0
local getProbe, setProbe = Charm.signal(0)
Charm.untracked(Charm.effect, function()
	getProbe()
	probeRuns += 1
end)

local function assertOutsideBatch()
	local runs = probeRuns
	probeVersion += 1
	setProbe(probeVersion)
	if probeRuns == runs then
		error("[Predictions] flush must be called outside any Charm.batch, once the views have followed the writes", 3)
	end
end

local function createServer<State, Actor, Client>(
	config: Types.ServerConfig<State, Actor, Client>
): Types.ServerRuntime<State, Actor, Client>
	assert(type(config) == "table", "[Predictions] Server config must be a table")
	assert(type(config.tables) == "table", "[Predictions] Server config must define tables")
	assert(type(config.views) == "table", "[Predictions] Server config must define views")
	assert(type(config.now) == "function", "[Predictions] Server config must define now")
	assert(
		config.isActor == nil or type(config.isActor) == "function",
		"[Predictions] Server config isActor must be a function"
	)
	assert(config.scope == nil or type(config.scope) == "function", "[Predictions] Server config scope must be a function")
	local actionTime = config.actionTime
	assert(
		actionTime == nil
			or (
				type(actionTime) == "table"
				and isFiniteNumber(actionTime.maxAge)
				and actionTime.maxAge >= 0
				and isFiniteNumber(actionTime.maxLead)
				and actionTime.maxLead >= 0
			),
		"[Predictions] Server config actionTime must hold a maxAge and a maxLead of at least 0"
	)
	for name in config.views do
		assert(config.tables[name] ~= nil, `[Predictions] Server config has a view for "{name}", which is no table`)
	end

	local tables = config.tables
	local now = config.now
	local isActor = config.isActor
	local maxAge = if actionTime == nil then 0 else actionTime.maxAge
	local maxLead = if actionTime == nil then 0 else actionTime.maxLead

	local stores: { [string]: Types.KeyedStore<string, any> } = {}
	local tableList: { Table } = {}
	local tablesByName: { [string]: Table } = {}
	local markedTables: { [Table]: true } = {}

	for index, name in Wire.tableNames(tables) do
		local given: any = tables[name]
		local store: Types.KeyedStore<string, any> = if given._keyed ~= nil then given._keyed else given
		assert(type(store._onWrite) == "function", `[Predictions] Table "{name}" must be a store from keyed or value`)
		local view = config.views[name]
		assert(
			view == true or type(view) == "function",
			`[Predictions] Server config must give table "{name}" a view: true or a function`
		)

		local record: Table = {
			name = name,
			index = index,
			store = store,
			view = view,
			marks = {},
			diffs = {},
			shared = nil,
		}
		store._onWrite(function(key: string, _value: any, previous: any)
			local marks = record.marks
			if marks[key] == nil then
				marks[key] = if previous == nil then ABSENT else previous
				markedTables[record] = true
			end
		end)
		stores[name] = store
		table.insert(tableList, record)
		tablesByName[name] = record
	end

	local allowed: { [string]: Allowed } = {}
	local members: { [Client]: Member } = {}
	-- The last sequence handled per client, added or not.
	local sequences: { [Client]: number } = {}
	-- The acknowledgement waiting for each client's next message.
	local acks: { [Client]: number } = {}

	local run = State.runner(tables, config.scope :: any)

	local function read(name: string, key: string): any
		return stores[name].get(key)
	end

	local function keysOf(name: string): { [string]: any }
		return stores[name].all()
	end

	local function apply(definition: Types.ActionDefinition<any, any, any>, actor: any, payload: any, time: number): boolean
		local changed, effects = run(definition, actor, payload, time, read, keysOf, nil)
		if changed == nil then
			return false
		end
		if next(changed) ~= nil then
			State.write(stores, changed)
		end
		EffectScope.deliver(effects)
		return true
	end

	local function allow<Payload>(
		definition: Types.ActionDefinition<State, Payload, Actor>,
		accept: ((client: Client, actor: Actor, payload: Payload) -> boolean)?
	)
		Action.assertDefinition(definition)
		assert(allowed[definition.id] == nil, `[Predictions] Action "{definition.id}" is already allowed`)
		assert(
			accept == nil or type(accept) == "function",
			`[Predictions] accept for action "{definition.id}" must be a function`
		)
		allowed[definition.id] = { definition = definition :: any, accept = accept :: any }
	end

	local function dispatch<Payload>(
		definition: Types.ActionDefinition<State, Payload, Actor>,
		actor: Actor,
		payload: Payload
	): boolean
		local time = now()
		-- Not assert: its message would be built on every call.
		if not isFiniteNumber(time) then
			error(`[Predictions] now() returned an invalid time for action "{definition.id}"`, 0)
		end
		return apply(definition :: any, actor, payload, time)
	end

	local function receive(client: Client, envelope: unknown)
		if type(envelope) ~= "table" then
			return
		end
		local raw = envelope :: { [any]: any }
		local sequence = raw.sequence
		if not isFiniteNumber(sequence) or sequence < 1 or sequence % 1 ~= 0 then
			return
		end

		local expected = (sequences[client] or 0) + 1
		if sequence < expected then
			warn(
				`[Predictions] Received stale or duplicate action sequence {sequence} from {tostring(client)}; expected {expected}. The action was ignored.`
			)
			return
		elseif sequence > expected then
			warn(
				`[Predictions] Received out-of-order action sequence {sequence} from {tostring(client)}; expected {expected}. The action was ignored. Client action transport must be reliable and ordered.`
			)
			return
		end

		-- Handled from here on, whatever happens to the action.
		sequences[client] = sequence
		acks[client] = sequence

		local actionId = raw.actionId
		local clientTime = raw.actionTime
		if type(actionId) ~= "string" or not isFiniteNumber(clientTime) then
			return
		end
		local entry = allowed[actionId]
		if entry == nil then
			warn(
				`[Predictions] Received action "{actionId}" from {tostring(client)} at sequence {sequence}, which clients are not allowed to send. The action was rejected.`
			)
			return
		end

		local definition = entry.definition
		local actor = raw.actor
		local payload = raw.payload
		if not passes("Validator", actionId, definition.validate, payload) then
			return
		end
		if isActor == nil then
			if actor ~= client then
				return
			end
		elseif not passes("isActor", actionId, isActor, client, actor) then
			return
		end
		if entry.accept ~= nil and not passes("accept", actionId, entry.accept, client, actor, payload) then
			return
		end

		local current = now()
		if not isFiniteNumber(current) then
			error(`[Predictions] now() returned an invalid time for action "{actionId}"`, 0)
		end
		apply(definition, actor, payload, math.clamp(clientTime, current - maxAge, current + maxLead))
	end

	local function addClient(client: Client)
		assert(members[client] == nil, `[Predictions] Client {tostring(client)} was already added`)
		local member: Member = { joining = true, sent = {}, rules = {}, stale = {}, stops = {} }
		members[client] = member

		for _, record in tableList do
			local view = record.view
			if view == true then
				continue
			end
			local name = record.name
			member.sent[name] = {}
			local stop = Charm.untracked(Charm.effect, function()
				local succeeded, rule = xpcall(view :: any, traceback, client)
				if not succeeded then
					warn(`[Predictions] The view of "{name}" failed for {tostring(client)}; he sees none of it:\n{rule}`)
					rule = false
				elseif type(rule) ~= "function" then
					warn(`[Predictions] The view of "{name}" returned no rule for {tostring(client)}; he sees none of it`)
					rule = false
				end
				member.rules[name] = rule
				member.stale[name] = true
			end)
			table.insert(member.stops, stop)
		end
	end

	local function removeClient(client: Client)
		local member = members[client]
		if member ~= nil then
			members[client] = nil
			for _, stop in member.stops do
				stop()
			end
		end
		sequences[client] = nil
		acks[client] = nil
	end

	-- Whether the client's rule lets him see the entry; nil when it throws, which closes the table to him.
	local function sees(client: Client, member: Member, record: Table, key: string, entry: any): boolean?
		local rule = member.rules[record.name]
		if rule == false then
			return false
		end
		local succeeded, result = xpcall(rule :: Rule, traceback, key, entry)
		if not succeeded then
			warn(`[Predictions] The view rule of "{record.name}" failed for {tostring(client)}; he sees none of it:\n{result}`)
			member.rules[record.name] = false
			return nil
		end
		return result == true
	end

	-- Every key he holds is gone.
	local function closed(member: Member, record: Table): any
		local sent = member.sent[record.name]
		local gone: { string } = {}
		for key in sent do
			table.insert(gone, key)
		end
		table.clear(sent)
		return Wire.tablePart(nil, nil, gone)
	end

	-- His part of a rule table for the keys of `keys` and, when `holdings` is set, for the keys he holds that the table
	-- no longer has. His set of keys changes only at the end, so a rule failing on the way closes the table from what
	-- he holds.
	local function rulePart(client: Client, member: Member, record: Table, keys: { [string]: any }, holdings: boolean): any
		if member.rules[record.name] == false then
			return closed(member, record)
		end
		local sent = member.sent[record.name]
		local values = record.store.all()
		local diffs = record.diffs
		local wholePart: { [string]: any } = {}
		local diffPart: { [string]: any } = {}
		local gone: { string } = {}
		for key in keys do
			local current = values[key]
			local visible = false
			if current ~= nil then
				local seen = sees(client, member, record, key, current)
				if seen == nil then
					return closed(member, record)
				end
				visible = seen
			end
			if visible then
				if sent[key] then
					diffPart[key] = diffs[key]
				else
					wholePart[key] = current
				end
			elseif sent[key] then
				table.insert(gone, key)
			end
		end
		if holdings then
			for key in sent do
				if values[key] == nil then
					table.insert(gone, key)
				end
			end
		end
		for key in wholePart do
			sent[key] = true
		end
		for _, key in gone do
			sent[key] = nil
		end
		return Wire.tablePart(wholePart, diffPart, gone)
	end

	local function buildMessages(): { [Client]: any }
		-- Each marked key's change, once for every client.
		for record in markedTables do
			local values = record.store.all()
			local wholePart: { [string]: any } = {}
			local gone: { string } = {}
			for key, previous in record.marks do
				local current = values[key]
				if previous == ABSENT then
					if current ~= nil then
						wholePart[key] = current
					end
				elseif current == nil then
					table.insert(gone, key)
				else
					record.diffs[key] = Wire.diff(previous, current)
				end
			end
			if record.view == true then
				record.shared = Wire.tablePart(wholePart, record.diffs, gone)
			end
		end

		-- A `true` table whole, made once for everyone joining.
		local joinParts: { [Table]: any } = {}
		local messages: { [Client]: any } = {}
		for client, member in members do
			local parts: { [number]: any } = {}
			if member.joining then
				for _, record in tableList do
					if record.view == true then
						local part = joinParts[record]
						if part == nil then
							part = Wire.tablePart(table.clone(record.store.all()), nil, nil) or false
							joinParts[record] = part
						end
						parts[record.index] = part or nil
					else
						parts[record.index] = rulePart(client, member, record, record.store.all(), false)
					end
				end
				member.joining = false
			else
				for record in markedTables do
					if record.view == true then
						parts[record.index] = record.shared
					elseif not member.stale[record.name] then
						parts[record.index] = rulePart(client, member, record, record.marks, false)
					end
				end
				for name in member.stale do
					local record = tablesByName[name]
					parts[record.index] = rulePart(client, member, record, record.store.all(), true)
				end
			end
			table.clear(member.stale)

			local message = Wire.message(acks[client], parts)
			acks[client] = nil
			if message ~= nil then
				messages[client] = message
			end
		end

		for record in markedTables do
			record.marks = {}
			record.diffs = {}
			record.shared = nil
		end
		table.clear(markedTables)
		return messages
	end

	local function flush(): { [Client]: any }
		assertOutsideBatch()
		debug.profilebegin("Predictions.flush")
		local messages = Charm.untracked(buildMessages)
		debug.profileend()
		return messages
	end

	return {
		addClient = addClient,
		removeClient = removeClient,
		allow = allow,
		dispatch = dispatch,
		receive = receive,
		flush = flush,
	}
end

return createServer
