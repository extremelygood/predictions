--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Action = require(ReplicatedStorage.Packages.Predictions.action)
local Effect = require(ReplicatedStorage.Packages.Predictions.effect)
local State = require(ReplicatedStorage.Packages.Predictions._state)
local Store = require(ReplicatedStorage.Packages.Predictions.store)
local Types = require(ReplicatedStorage.Packages.Predictions._types)
local TestRunner = require(script.Parent.TestRunner)

local VALUE_KEY = Store.VALUE_KEY

type Fixture = {
	tables: Types.Tables,
	-- Typed loosely so tests can read an entry's fields straight off get().
	items: any,
	round: Types.Value<any>,
	read: State.Read,
	keysOf: (name: string) -> { [string]: any },
}

local function keyedOf(store: any): Types.KeyedStore<string, any>
	return if store._keyed ~= nil then store._keyed else store
end

local function fixture(): Fixture
	local items = Store.keyed() :: Types.Keyed<string, any>
	local round = Store.value({ phase = "warmup" })
	items.patch({ a = { n = 1 }, b = { n = 2 } })
	local tables: Types.Tables = { items = items, round = round }
	return {
		tables = tables,
		items = items,
		round = round,
		read = function(name: string, key: string): any
			return keyedOf(tables[name]).get(key)
		end,
		keysOf = function(name: string): { [string]: any }
			return keyedOf(tables[name]).all()
		end,
	}
end

local function defineAction(scope: any, reduce: any): Types.ActionDefinition<any, any, any>
	return Action.define({
		id = "Test",
		validate = function(_payload: unknown): boolean
			return true
		end,
		scope = scope,
		reduce = reduce,
	})
end

local function runAction(
	state: Fixture,
	definition: Types.ActionDefinition<any, any, any>,
	defaultScope: any?,
	seen: State.Seen?
): (State.Changes?, Types.EffectCollector)
	local run = State.runner(state.tables, defaultScope)
	return run(definition, "actor", { key = "a" }, 5, state.read, state.keysOf, seen)
end

local cases: { TestRunner.TestCase } = {
	{
		name = "state world reads by key and tells each read",
		run = function()
			local state = fixture()
			local reads: { string } = {}
			local world = State.world(state.tables, {
				read = state.read,
				seen = function(name: string, key: string)
					table.insert(reads, `{name}.{key}`)
				end,
			})
			TestRunner.expectEqual(world.items.a, state.items.get("a"))
			TestRunner.expectEqual(world.items.missing, nil)
			TestRunner.expectEqual(world.round, state.round.get())
			TestRunner.expectDeepEqual(reads, { "items.a", "items.missing", `round.{VALUE_KEY}` })
		end,
	},
	{
		name = "state world cannot be iterated, written or asked for a table that does not exist",
		run = function()
			local state = fixture()
			local world = State.world(state.tables, { read = state.read })
			TestRunner.expectError(function()
				for _ in world do
				end
			end, "read by key only")
			TestRunner.expectError(function()
				for _ in world.items do
				end
			end, "read by key only")
			TestRunner.expectError(function()
				world.items.a = { n = 9 }
			end, "read-only")
			TestRunner.expectError(function()
				local _ = world.missing
			end, 'no table named "missing"')
		end,
	},
	{
		name = "state changes leave unchanged tables out and mark removals",
		run = function()
			local state = fixture()
			local a, b = { n = 1 }, { n = 2 }
			local round = { phase = "warmup" }
			local before = { items = { a = a, b = b }, round = round }

			TestRunner.expectEqual(State.changes(state.tables, before, { items = { a = a, b = b }, round = round }), nil)
			-- A table missing from the result is unchanged.
			TestRunner.expectEqual(State.changes(state.tables, before, {}), nil)

			local c = { n = 3 }
			local changed = State.changes(state.tables, before, { items = { a = a, c = c } })
			TestRunner.expectDeepEqual(changed, { items = { b = false, c = c } })

			-- Entries are compared by identity.
			local copy = { n = 1 }
			local replaced = State.changes(state.tables, before, { items = { a = copy, b = b } }) :: any
			TestRunner.expectEqual(replaced.items.a, copy)
		end,
	},
	{
		name = "state changes give a value table's change under its one key",
		run = function()
			local state = fixture()
			local round = { phase = "warmup" }
			local nextRound = { phase = "live" }
			local changed = State.changes(state.tables, { round = round }, { round = nextRound }) :: any
			TestRunner.expectDeepEqual(changed, { round = { [VALUE_KEY] = nextRound } })
			TestRunner.expectEqual(changed.round[VALUE_KEY], nextRound)
			TestRunner.expectEqual(State.changes(state.tables, { round = round }, { round = round }), nil)
		end,
	},
	{
		name = "state run works an action out on its own scope",
		run = function()
			local state = fixture()
			local given: any = nil
			local context: any = nil
			local definition = defineAction(function(world: any, actor: any, payload: any): any
				TestRunner.expectEqual(actor, "actor")
				return { items = { [payload.key] = world.items[payload.key] } }
			end, function(scope: any, _payload: any, actionContext: any): any
				given = scope
				context = actionContext
				return { items = { a = { n = 10 } } }
			end)
			local changed = runAction(state, definition) :: any
			TestRunner.expectDeepEqual(given, { items = { a = { n = 1 } } })
			TestRunner.expectDeepEqual(context, { actionTime = 5, actor = "actor" })
			TestRunner.expectDeepEqual(changed, { items = { a = { n = 10 } } })
			-- run writes nothing itself.
			TestRunner.expectEqual(state.items.get("a").n, 1)
		end,
	},
	{
		name = "state run takes the default scope for an action that names none",
		run = function()
			local state = fixture()
			local given: any = nil
			local definition = defineAction(nil, function(scope: any): any
				given = scope
				return { items = { b = scope.items.b } }
			end)
			local changed = runAction(state, definition, function(world: any): any
				return { items = { b = world.items.b } }
			end)
			TestRunner.expectDeepEqual(given, { items = { b = { n = 2 } } })
			-- Accepted, changing nothing.
			TestRunner.expectDeepEqual(changed, {})
		end,
	},
	{
		name = "state run with no scope gives every table whole and follows in-place changes",
		run = function()
			local state = fixture()
			local reads: { [string]: true } = {}
			local definition = defineAction(nil, function(scope: any): any
				TestRunner.expectDeepEqual(scope, { items = { a = { n = 1 }, b = { n = 2 } }, round = { phase = "warmup" } })
				scope.items.a = nil
				scope.items.c = { n = 3 }
				return scope
			end)
			local changed = runAction(state, definition, nil, function(name: string, key: string)
				reads[`{name}.{key}`] = true
			end)
			TestRunner.expectDeepEqual(changed, { items = { a = false, c = { n = 3 } } })
			TestRunner.expectDeepEqual(reads, { ["items.a"] = true, ["items.b"] = true, [`round.{VALUE_KEY}`] = true })
			-- The store's own table was copied, not handed over.
			TestRunner.expectEqual(state.items.get("a").n, 1)
		end,
	},
	{
		name = "state run returns nothing for a rejected or throwing reducer",
		run = function()
			local state = fixture()
			local rejected = defineAction(nil, function(): any
				return nil
			end)
			TestRunner.expectEqual(runAction(state, rejected), nil)

			local throwing = defineAction(nil, function(): any
				error("reducer broke")
			end)
			TestRunner.expectWarning(function()
				TestRunner.expectEqual(runAction(state, throwing), nil)
			end, 'Reducer for action "Test" failed')
		end,
	},
	{
		name = "state run rejects writing an existing entry its state did not hold, and lets it add one",
		run = function()
			local state = fixture()
			local intruding = defineAction(function(): any
				return { items = {} }
			end, function(): any
				return { items = { b = { n = 9 } } }
			end)
			TestRunner.expectWarning(function()
				TestRunner.expectEqual(runAction(state, intruding), nil)
			end, 'entry "b", which exists but was not in its state')

			local adding = defineAction(function(): any
				return { items = {} }
			end, function(): any
				return { items = { new = { n = 1 } } }
			end)
			TestRunner.expectDeepEqual(runAction(state, adding), { items = { new = { n = 1 } } })

			-- A value table counts as held only when the scope holds it.
			local roundIntruding = defineAction(function(): any
				return {}
			end, function(): any
				return { round = { phase = "live" } }
			end)
			TestRunner.expectWarning(function()
				TestRunner.expectEqual(runAction(state, roundIntruding), nil)
			end, 'wrote "round"')
		end,
	},
	{
		name = "state run works an action out inside another's scope and reducer, each on its own reads and state",
		run = function()
			local state = fixture()
			local run = State.runner(state.tables, nil)
			local outerReads: { string } = {}
			local innerReads: { string } = {}
			local function reading(log: { string }): State.Read
				return function(name: string, key: string): any
					table.insert(log, `{name}.{key}`)
					return state.read(name, key)
				end
			end

			local inner = defineAction(function(world: any): any
				return { items = { b = world.items.b } }
			end, function(scope: any): any
				scope.items.b = { n = 20 }
				return scope
			end)
			local function runInner()
				local changed = run(inner, "actor", nil, 5, reading(innerReads), state.keysOf)
				TestRunner.expectDeepEqual(changed, { items = { b = { n = 20 } } })
			end

			local keptWorld: any = nil
			local outer = defineAction(function(world: any): any
				local a = world.items.a
				runInner()
				keptWorld = world
				return { items = { a = a, c = world.items.c } }
			end, function(scope: any): any
				-- Changed in place, with another action worked out in between.
				scope.items.a = { n = 10 }
				runInner()
				return scope
			end)

			local changed = run(outer, "actor", nil, 5, reading(outerReads), state.keysOf)
			TestRunner.expectDeepEqual(changed, { items = { a = { n = 10 } } })
			TestRunner.expectDeepEqual(outerReads, { "items.a", "items.c" })
			TestRunner.expectDeepEqual(innerReads, { "items.b", "items.b" })
			TestRunner.expectError(function()
				local _ = keptWorld.items.a
			end, "only while")
		end,
	},
	{
		name = "state run collects the reducer's effects, and none when it rejects",
		run = function()
			local state = fixture()
			local fired = Effect.define({ name = "Fired" })
			local emitting = defineAction(nil, function(scope: any): any
				fired.emit(7)
				return scope
			end)
			local changed, effects = runAction(state, emitting)
			TestRunner.expectDeepEqual(changed, {})
			TestRunner.expectEqual(#effects, 1)
			TestRunner.expectEqual(effects[1].payload, 7)

			local rejecting = defineAction(nil, function(): any
				fired.emit(8)
				return nil
			end)
			local _, none = runAction(state, rejecting)
			TestRunner.expectEqual(#none, 0)
		end,
	},
}

return cases
