--!strict

--[[
	How an action is worked out, the same on the server and the client: the state it is given, the reducer run on it,
	and what the result changes. The runtimes say how an entry is read (the server reads its stores, the client reads
	them under its predictions) and write the changes themselves.

	STATE. `{ [tableName]: { [key]: entry } }`, a value table appearing as its value. An action's state is what its
	scope returns (the definition's, else the runtime's default); with neither it is every table whole, copied. The
	reducer may change the tables of its state in place or return new ones: what it returns is compared against the
	entries its state held before it ran, noted aside first. The entries themselves are never changed in place.

	WORLD. What a scope reads from: `world[name][key]` is one entry, `world[name]` of a value table its value. It is
	read by key only: iterating it, or a table of it, errors, and so does writing it or naming a table that does not
	exist. A runtime has one world, read through the action whose scope is running; read at any other time it errors.

	THE WRITE GUARD. A reducer may change only the entries it was given, and add entries that do not exist. Writing a
	key that exists but was not in its state rejects the action with a warning.
]]

local Charm = require(script.Parent.Parent.Charm)
local EffectScope = require(script.Parent["_effect-scope"])
local Store = require(script.Parent.store)
local Types = require(script.Parent._types)

local VALUE_KEY = Store.VALUE_KEY

-- An entry of a table as the action should see it; nil when absent. For a value table the key is VALUE_KEY.
export type Read = (name: string, key: string) -> any

-- Called with every (name, key) an action's state was read from.
export type Seen = (name: string, key: string) -> ()

-- What an action changes, per table: `{ [name] = { [key] = entry | false } }`, false for a removal.
export type Changes = { [string]: { [string]: any } }

-- What a world reads through.
export type Reader = { read: Read, seen: Seen? }

-- Works an action out, under Charm.untracked: builds its state, runs `reduce` collecting effects, and returns the
-- changes, an empty table when the action is accepted and changes nothing. Returns nil changes when the reducer
-- rejects, when the scope or the reducer throws, or when the write guard stops it; the effects are then empty.
-- `validate` is not called. `keysOf` gives the keys a table has now, for an action that sees every table whole.
export type Run = (
	definition: Types.ActionDefinition<any, any, any>,
	actor: any,
	payload: any,
	actionTime: number,
	read: Read,
	keysOf: (name: string) -> { [string]: any },
	seen: Seen?
) -> (Changes?, Types.EffectCollector)

local NO_CHANGES: Changes = table.freeze({}) :: any

local function isValueTable(store: any): boolean
	return store._keyed ~= nil
end

local function traceback(message: any): string
	return debug.traceback(tostring(message), 2)
end

local function iterateError(): any
	error("[Predictions] The world is read by key only: build the scope from the keys you need", 2)
end

local function writeError(): ()
	error("[Predictions] The world is read-only: return the entries from the scope and change them in reduce", 2)
end

local function readOutsideScope(): any
	error("[Predictions] The world can be read only while the scope it was given to runs", 3)
end

-- A read-only state: world[name][key] is reader.read(name, key), told to reader.seen; a value table's world[name] is
-- its value. The reader is looked up at every read, so one world serves every action of a runtime.
local function world(tables: Types.Tables, reader: Reader): any
	local views: { [string]: any } = {}
	local valueTables: { [string]: true } = {}
	for name, store in tables do
		if isValueTable(store) then
			valueTables[name] = true
			continue
		end
		views[name] = setmetatable({}, {
			__index = function(_, key: string): any
				local seen = reader.seen
				if seen ~= nil then
					seen(name, key)
				end
				return reader.read(name, key)
			end,
			__newindex = writeError,
			__iter = iterateError,
		})
	end

	return setmetatable({}, {
		__index = function(_, name: string): any
			local view = views[name]
			if view ~= nil then
				return view
			end
			if valueTables[name] == nil then
				error(`[Predictions] There is no table named "{name}"`, 2)
			end
			local seen = reader.seen
			if seen ~= nil then
				seen(name, VALUE_KEY)
			end
			return reader.read(name, VALUE_KEY)
		end,
		__newindex = writeError,
		__iter = iterateError,
	})
end

-- What `after` changes against `before`, per table, a value table's under VALUE_KEY; nil when nothing changes. A
-- table missing from `after` is unchanged; a key missing from a table that `before` had is removed (false). Entries
-- are compared by identity.
local function changes(tables: Types.Tables, before: any, after: any): Changes?
	local result: Changes? = nil
	for name, part in after do
		local previous = before[name]
		if isValueTable(tables[name]) then
			if part ~= previous then
				result = result or {}
				(result :: Changes)[name] = { [VALUE_KEY] = part }
			end
			continue
		end
		local changed: { [string]: any }? = nil
		for key, entry in part do
			if previous == nil or previous[key] ~= entry then
				changed = changed or {}
				(changed :: { [string]: any })[key] = entry
			end
		end
		if previous ~= nil then
			for key in previous do
				if part[key] == nil then
					changed = changed or {}
					(changed :: { [string]: any })[key] = false
				end
			end
		end
		if changed ~= nil then
			result = result or {}
			(result :: Changes)[name] = changed
		end
	end
	return result
end

-- Every table whole, each a copy read through `read`.
local function wholeState(
	tables: Types.Tables,
	read: Read,
	keysOf: (name: string) -> { [string]: any },
	seen: Seen?
): any
	local state = {}
	for name, store in tables do
		if isValueTable(store) then
			if seen ~= nil then
				seen(name, VALUE_KEY)
			end
			state[name] = read(name, VALUE_KEY)
			continue
		end
		local part = {}
		for key in keysOf(name) do
			if seen ~= nil then
				seen(name, key)
			end
			part[key] = read(name, key)
		end
		state[name] = part
	end
	return state
end

--[[
	What a state held before its reducer ran, so a reducer changing its tables in place is still compared against what
	it was given. Notes are reused from one action to the next: once warm, taking one copies the entries into tables
	that already exist instead of making a copy of every table. An action worked out while another is (from inside a
	scope or a reducer) takes a note of its own.
]]
type Note = {
	-- The state as given: per table its noted copy, per value table its value.
	given: { [string]: any },
	-- Per table name, the copy reused for it; empty while not in use.
	copies: { [string]: { [string]: any } },
}

local spareNotes: { Note } = {}

local function takeNote(valueTables: { [string]: boolean }, state: any): Note
	local note: Note = table.remove(spareNotes) or { given = {}, copies = {} }
	for name, part in state do
		if valueTables[name] then
			note.given[name] = part
			continue
		end
		local copy = note.copies[name]
		if copy == nil then
			copy = {}
			note.copies[name] = copy
		end
		for key, entry in part do
			(copy :: { [string]: any })[key] = entry
		end
		note.given[name] = copy
	end
	return note
end

local function putBack(note: Note)
	for name in note.given do
		local copy = note.copies[name]
		if copy ~= nil then
			table.clear(copy)
		end
	end
	table.clear(note.given)
	table.insert(spareNotes, note)
end

-- The run for a runtime's tables and default scope. Everything an action needs that does not depend on the action
-- (the world, which tables hold one value) is made here, once.
local function runner(tables: Types.Tables, defaultScope: ((world: any, actor: any, payload: any) -> any)?): Run
	-- Per table name, whether it is a value table; nil for a name that is no table.
	local valueTables: { [string]: boolean } = {}
	for name, store in tables do
		valueTables[name] = isValueTable(store)
	end
	local reader: Reader = { read = readOutsideScope, seen = nil }
	local view = world(tables, reader)

	-- The write guard: a warning when `changed` writes an entry that exists but was not in `given`. An entry the state
	-- held needs no read.
	local function guard(definition: Types.ActionDefinition<any, any, any>, given: any, changed: Changes, read: Read): string?
		for name, entries in changed do
			local givenPart = given[name]
			local valueTable = valueTables[name]
			for key in entries do
				local inState = givenPart ~= nil and (valueTable or givenPart[key] ~= nil)
				if not inState and read(name, key) ~= nil then
					return `[Predictions] Action "{definition.id}" wrote "{name}" entry "{key}", which exists but was not in its state. The action was rejected.`
				end
			end
		end
		return nil
	end

	-- What the reducer's outcome changes against the state it was `given`: nil when it rejected, threw or was stopped,
	-- with the warning to give for the last two.
	local function settle(
		definition: Types.ActionDefinition<any, any, any>,
		succeeded: boolean,
		after: any,
		given: any,
		read: Read
	): (Changes?, string?)
		if not succeeded then
			return nil, `[Predictions] Reducer for action "{definition.id}" failed:\n{after}`
		end
		if after == nil then
			return nil, nil
		end
		for name in after do
			if valueTables[name] == nil then
				return nil, `[Predictions] Action "{definition.id}" returned "{name}", which is no table. The action was rejected.`
			end
		end
		local changed = changes(tables, given, after) or NO_CHANGES
		local rejection = guard(definition, given, changed, read)
		if rejection ~= nil then
			return nil, rejection
		end
		return changed, nil
	end

	local function work(
		definition: Types.ActionDefinition<any, any, any>,
		actor: any,
		payload: any,
		actionTime: number,
		read: Read,
		keysOf: (name: string) -> { [string]: any },
		seen: Seen?
	): (Changes?, Types.EffectCollector)
		local scope = definition.scope or defaultScope

		local state: any
		if scope ~= nil then
			-- The reader the world had is put back after, for an action worked out from inside another's scope.
			local outerRead, outerSeen = reader.read, reader.seen
			reader.read, reader.seen = read, seen
			local succeeded, result = xpcall(scope, traceback, view, actor, payload)
			reader.read, reader.seen = outerRead, outerSeen
			if not succeeded then
				warn(`[Predictions] Scope of action "{definition.id}" failed:\n{result}`)
				return nil, EffectScope.NO_EFFECTS
			end
			state = result
		else
			state = wholeState(tables, read, keysOf, seen)
		end
		for name in state do
			if valueTables[name] == nil then
				warn(`[Predictions] Scope of action "{definition.id}" holds "{name}", which is no table. The action was rejected.`)
				return nil, EffectScope.NO_EFFECTS
			end
		end

		local note = takeNote(valueTables, state)
		local context: Types.ActionContext<any> = { actionTime = actionTime, actor = actor }
		local succeeded, after, effects = EffectScope.collect(definition.reduce, state, payload, context)
		local changed, rejection = settle(definition, succeeded, after, note.given, read)
		putBack(note)

		if rejection ~= nil then
			warn(rejection)
		end
		if changed == nil then
			return nil, EffectScope.NO_EFFECTS
		end
		return changed, effects
	end

	return function(
		definition: Types.ActionDefinition<any, any, any>,
		actor: any,
		payload: any,
		actionTime: number,
		read: Read,
		keysOf: (name: string) -> { [string]: any },
		seen: Seen?
	): (Changes?, Types.EffectCollector)
		debug.profilebegin("Predictions.action")
		-- Charm.untracked by hand: when something reactive is running, Charm's packs a table of results and, in Studio,
		-- runs the function in a coroutine.
		local changed, effects
		local outerSub = Charm.setActiveSub(nil)
		if outerSub == nil then
			changed, effects = work(definition, actor, payload, actionTime, read, keysOf, seen)
		else
			local succeeded, result, collected =
				pcall(work, definition, actor, payload, actionTime, read, keysOf, seen)
			Charm.setActiveSub(outerSub)
			if not succeeded then
				debug.profileend()
				error(result, 0)
			end
			changed, effects = result, collected
		end
		debug.profileend()
		return changed, effects
	end
end

local function writeEach(stores: { [string]: Types.KeyedStore<string, any> }, changed: Changes)
	for name, entries in changed do
		stores[name]._write(entries)
	end
end

-- Writes `changed` to the stores, each table's under its name, in one Charm.batch so readers wake once, after it.
-- The batch is opened by hand: Charm.batch packs a table of results and, in Studio, runs the function in a coroutine.
local function write(stores: { [string]: Types.KeyedStore<string, any> }, changed: Changes)
	Charm.startBatch()
	local succeeded, failure: any = pcall(writeEach, stores, changed)
	Charm.endBatch()
	if not succeeded then
		error(failure, 0)
	end
end

return {
	world = world,
	changes = changes,
	runner = runner,
	write = write,
}
