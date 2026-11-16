--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage.Packages.Charm)
local Action = require(ReplicatedStorage.Packages.Predictions.action)
local Client = require(ReplicatedStorage.Packages.Predictions.client)
local Effect = require(ReplicatedStorage.Packages.Predictions.effect)
local Store = require(ReplicatedStorage.Packages.Predictions.store)
local Types = require(ReplicatedStorage.Packages.Predictions._types)
local Wire = require(ReplicatedStorage.Packages.Predictions._wire)
local TestRunner = require(script.Parent.TestRunner)

local ACTOR = "actor"
local VALUE_KEY = Store.VALUE_KEY

type Counter = { n: number }
type Target = { key: string }
type Phase = { name: string }
type State = { [string]: any }

-- One table's part of a message the test sends as the server.
type Part = { whole: { [string]: any }?, diffs: { [string]: any }?, gone: { string }? }

type Harness = {
	counters: Types.Keyed<string, Counter>,
	targets: Types.Keyed<string, Target>,
	phase: Types.Value<Phase?>,
	client: Types.ClientRuntime<State, string>,
	sent: { Types.ActionEnvelope },
	-- How often a reducer ran, on dispatch and on replay.
	reduced: () -> number,
	-- Plays the server: a message with the acknowledgement (nil: none) and each named table's part.
	server: (ack: number?, parts: { [string]: Part }) -> (),
	add: Types.ActionDefinition<State, { key: string, amount: number }, string>,
	create: Types.ActionDefinition<State, { key: string, amount: number }, string>,
	bumpTarget: Types.ActionDefinition<State, { key: string }, string>,
	setPhase: Types.ActionDefinition<State, { name: string }, string>,
	zeroAll: Types.ActionDefinition<State, {}, string>,
	added: Types.Effect<string>,
}

local function isKeyAmount(payload: unknown): boolean
	return type(payload) == "table"
		and type((payload :: any).key) == "string"
		and type((payload :: any).amount) == "number"
end

local function harness(): Harness
	local counters = Store.keyed() :: Types.Keyed<string, Counter>
	local targets = Store.keyed() :: Types.Keyed<string, Target>
	local phase = Store.value(nil :: Phase?)
	local tables: Types.Tables = { counters = counters, targets = targets, phase = phase } :: any
	local names = Wire.tableNames(tables)

	local sent: { Types.ActionEnvelope } = {}
	local time = 0
	local client = Client({
		tables = tables,
		send = function(envelope: Types.ActionEnvelope)
			table.insert(sent, envelope)
		end,
		now = function(): number
			time += 1
			return time
		end,
	} :: Types.ClientConfig<State, string>)

	local reduceCount = 0
	local added = Effect.define({ name = "added" }) :: Types.Effect<string>

	-- Adds to a counter; rejected when there is none.
	local add = Action.define({
		id = "add",
		validate = isKeyAmount,
		scope = function(world: State, _actor: string, payload: { key: string, amount: number }): State
			return { counters = { [payload.key] = world.counters[payload.key] } }
		end,
		reduce = function(state: State, payload: { key: string, amount: number }): State?
			reduceCount += 1
			local counter = state.counters[payload.key]
			if counter == nil then
				return nil
			end
			added.emit(payload.key)
			return { counters = { [payload.key] = { n = counter.n + payload.amount } } }
		end,
	})

	-- Makes a counter; rejected when it exists.
	local create = Action.define({
		id = "create",
		validate = isKeyAmount,
		scope = function(world: State, _actor: string, payload: { key: string, amount: number }): State
			return { counters = { [payload.key] = world.counters[payload.key] } }
		end,
		reduce = function(state: State, payload: { key: string, amount: number }): State?
			reduceCount += 1
			if state.counters[payload.key] ~= nil then
				return nil
			end
			return { counters = { [payload.key] = { n = payload.amount } } }
		end,
	})

	-- Adds one to the counter a target names, so which key it writes depends on the target.
	local bumpTarget = Action.define({
		id = "bumpTarget",
		validate = function(payload: unknown): boolean
			return type(payload) == "table" and type((payload :: any).key) == "string"
		end,
		scope = function(world: State, _actor: string, payload: { key: string }): State
			local target = world.targets[payload.key]
			return {
				targets = { [payload.key] = target },
				counters = if target ~= nil then { [target.key] = world.counters[target.key] } else {},
			}
		end,
		reduce = function(state: State, payload: { key: string }): State?
			reduceCount += 1
			local target = state.targets[payload.key]
			local counter = if target ~= nil then state.counters[target.key] else nil
			if counter == nil then
				return nil
			end
			return { counters = { [target.key] = { n = counter.n + 1 } } }
		end,
	})

	local setPhase = Action.define({
		id = "setPhase",
		validate = function(payload: unknown): boolean
			return type(payload) == "table" and type((payload :: any).name) == "string"
		end,
		scope = function(world: State): State
			return { phase = world.phase }
		end,
		reduce = function(_state: State, payload: { name: string }): State?
			reduceCount += 1
			return { phase = { name = payload.name } }
		end,
	})

	-- No scope: it sees every table whole and sets every counter to zero.
	local zeroAll = Action.define({
		id = "zeroAll",
		validate = function(payload: unknown): boolean
			return type(payload) == "table"
		end,
		reduce = function(state: State): State?
			reduceCount += 1
			local zeroed: { [string]: Counter } = {}
			for key in state.counters do
				zeroed[key] = { n = 0 }
			end
			return { counters = zeroed }
		end,
	})

	local function server(ack: number?, parts: { [string]: Part })
		local built: { [number]: any } = {}
		for name, part in parts do
			built[table.find(names, name) :: number] = Wire.tablePart(part.whole, part.diffs, part.gone)
		end
		client.receive(Wire.message(ack, built))
	end

	return {
		counters = counters,
		targets = targets,
		phase = phase,
		client = client,
		sent = sent,
		reduced = function(): number
			return reduceCount
		end,
		server = server,
		add = add,
		create = create,
		bumpTarget = bumpTarget,
		setPhase = setPhase,
		zeroAll = zeroAll,
		added = added,
	}
end

-- Runs `read` in an effect and counts its runs; returns the count reader and the effect's cleanup.
local function countRuns(read: () -> ()): (() -> number, () -> ())
	local runs = 0
	local stop = Charm.effect(function()
		read()
		runs += 1
	end)
	return function()
		return runs
	end, stop
end

local function counter(n: number): Counter
	return { n = n }
end

local cases: { TestRunner.TestCase } = {
	{
		name = "client confirm equal to the prediction wakes nobody",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1) } } })
			local runs, stop = countRuns(function()
				h.counters.get("a")
			end)

			TestRunner.expectEqual(h.client.dispatch(h.add, ACTOR, { key = "a", amount = 1 }), true)
			local predicted = h.counters.get("a")
			TestRunner.expectDeepEqual(predicted, counter(2))
			TestRunner.expectEqual(runs(), 2)
			TestRunner.expectDeepEqual(h.sent, {
				{ actionId = "add", actor = ACTOR, payload = { key = "a", amount = 1 }, sequence = 1, actionTime = 1 },
			})

			h.server(1, { counters = { diffs = { a = Wire.diff(counter(1), counter(2)) } } })
			TestRunner.expectEqual(h.counters.get("a"), predicted)
			TestRunner.expectEqual(runs(), 2)
			stop()
		end,
	},
	{
		name = "client rejection rolls the prediction back",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1) } } })
			local runs, stop = countRuns(function()
				h.counters.get("a")
			end)

			h.client.dispatch(h.add, ACTOR, { key = "a", amount = 1 })
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(2))

			h.server(1, {})
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(1))
			TestRunner.expectEqual(runs(), 3)
			stop()
		end,
	},
	{
		name = "client two pending actions on one entry are acknowledged one at a time",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1) } } })
			local runs, stop = countRuns(function()
				h.counters.get("a")
			end)

			h.client.dispatch(h.add, ACTOR, { key = "a", amount = 1 })
			h.client.dispatch(h.add, ACTOR, { key = "a", amount = 10 })
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(12))
			TestRunner.expectEqual(runs(), 3)
			TestRunner.expectEqual(h.sent[2].sequence, 2)

			-- The first is confirmed: the second is replayed on the server's entry and comes out as shown.
			h.server(1, { counters = { diffs = { a = Wire.diff(counter(1), counter(2)) } } })
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(12))
			TestRunner.expectEqual(runs(), 3)
			TestRunner.expectEqual(h.reduced(), 3)

			h.server(2, { counters = { diffs = { a = Wire.diff(counter(2), counter(12)) } } })
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(12))
			TestRunner.expectEqual(runs(), 3)
			TestRunner.expectEqual(h.reduced(), 3)

			-- Nothing is kept aside any more: the server's next change goes straight into the store.
			h.server(nil, { counters = { diffs = { a = Wire.diff(counter(12), counter(13)) } } })
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(13))
			TestRunner.expectEqual(runs(), 4)
			stop()
		end,
	},
	{
		name = "client server change to an overlaid entry is replayed over, not lost",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1) } } })
			local runs, stop = countRuns(function()
				h.counters.get("a")
			end)

			h.client.dispatch(h.add, ACTOR, { key = "a", amount = 1 })
			TestRunner.expectEqual(runs(), 2)

			-- Someone else set it to 5 on the server before the action arrived there.
			h.server(nil, { counters = { diffs = { a = Wire.diff(counter(1), counter(5)) } } })
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(6))
			TestRunner.expectEqual(runs(), 3)

			h.server(1, { counters = { diffs = { a = Wire.diff(counter(5), counter(6)) } } })
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(6))
			TestRunner.expectEqual(runs(), 3)
			stop()
		end,
	},
	{
		name = "client entry removed by the server while overlaid is removed at once",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1) } } })
			local runs, stop = countRuns(function()
				h.counters.get("a")
			end)

			h.client.dispatch(h.add, ACTOR, { key = "a", amount = 1 })
			TestRunner.expectEqual(runs(), 2)

			-- The replay finds no counter and is rejected, so the server's absence shows.
			h.server(nil, { counters = { gone = { "a" } } })
			TestRunner.expectEqual(h.counters.get("a"), nil)
			TestRunner.expectEqual(runs(), 3)

			h.server(1, {})
			TestRunner.expectEqual(h.counters.get("a"), nil)
			TestRunner.expectEqual(runs(), 3)
			stop()
		end,
	},
	{
		name = "client entry leaving the view while overlaid goes, and comes back as the server holds it",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1) } } })
			local runs, stop = countRuns(function()
				h.counters.get("a")
			end)

			h.client.dispatch(h.add, ACTOR, { key = "a", amount = 1 })
			TestRunner.expectEqual(runs(), 2)

			-- The server applied the action, but the entry left this client's view in the same tick.
			h.server(1, { counters = { gone = { "a" } } })
			TestRunner.expectEqual(h.counters.get("a"), nil)
			TestRunner.expectEqual(runs(), 3)

			h.server(nil, { counters = { whole = { a = counter(2) } } })
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(2))
			TestRunner.expectEqual(runs(), 4)
			stop()
		end,
	},
	{
		name = "client replay that writes another key, then is rejected, leaves both keys at the server's values",
		run = function()
			local h = harness()
			h.server(nil, {
				counters = { whole = { a = counter(1), b = counter(5) } },
				targets = { whole = { t = { key = "a" } } },
			})

			h.client.dispatch(h.bumpTarget, ACTOR, { key = "t" })
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(2))

			-- The target changes on the server: the replay now writes b, and a shows the server's entry again.
			h.server(nil, { targets = { diffs = { t = Wire.diff({ key = "a" }, { key = "b" }) } } })
			TestRunner.expectDeepEqual(h.targets.get("t"), { key = "b" })
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(1))
			TestRunner.expectDeepEqual(h.counters.get("b"), counter(6))

			h.server(1, {})
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(1))
			TestRunner.expectDeepEqual(h.counters.get("b"), counter(5))

			-- Neither is kept aside any more.
			h.server(nil, {
				counters = {
					diffs = { a = Wire.diff(counter(1), counter(7)), b = Wire.diff(counter(5), counter(8)) },
				},
			})
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(7))
			TestRunner.expectDeepEqual(h.counters.get("b"), counter(8))
		end,
	},
	{
		name = "client action that adds a key shows it until the server's version arrives",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1) } } })
			local runs, stop = countRuns(function()
				h.counters.get("c")
			end)

			TestRunner.expectEqual(h.client.dispatch(h.create, ACTOR, { key = "c", amount = 3 }), true)
			TestRunner.expectDeepEqual(h.counters.get("c"), counter(3))
			TestRunner.expectEqual(runs(), 2)

			h.server(1, { counters = { whole = { c = counter(3) } } })
			TestRunner.expectDeepEqual(h.counters.get("c"), counter(3))
			TestRunner.expectEqual(runs(), 2)
			stop()

			-- The server's version differs from the prediction: it is what shows.
			h.client.dispatch(h.create, ACTOR, { key = "d", amount = 3 })
			h.server(2, { counters = { whole = { d = counter(4) } } })
			TestRunner.expectDeepEqual(h.counters.get("d"), counter(4))

			-- Rejected on the client: nothing is written or sent.
			TestRunner.expectEqual(h.client.dispatch(h.create, ACTOR, { key = "a", amount = 3 }), false)
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(1))
			TestRunner.expectEqual(#h.sent, 2)
		end,
	},
	{
		name = "client value table is predicted, confirmed and rolled back",
		run = function()
			local h = harness()
			h.server(nil, { phase = { whole = { [VALUE_KEY] = { name = "waiting" } } } })
			TestRunner.expectDeepEqual(h.phase.get(), { name = "waiting" })
			local runs, stop = countRuns(function()
				h.phase.get()
			end)

			h.client.dispatch(h.setPhase, ACTOR, { name = "playing" })
			TestRunner.expectDeepEqual(h.phase.get(), { name = "playing" })
			TestRunner.expectEqual(runs(), 2)

			h.server(1, { phase = { diffs = { [VALUE_KEY] = Wire.diff({ name = "waiting" }, { name = "playing" }) } } })
			TestRunner.expectDeepEqual(h.phase.get(), { name = "playing" })
			TestRunner.expectEqual(runs(), 2)

			h.client.dispatch(h.setPhase, ACTOR, { name = "ended" })
			TestRunner.expectEqual(runs(), 3)
			h.server(2, {})
			TestRunner.expectDeepEqual(h.phase.get(), { name = "playing" })
			TestRunner.expectEqual(runs(), 4)
			stop()
		end,
	},
	{
		name = "client action without a scope sees every table whole, and replays over a key the server adds",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1), b = counter(2) } } })
			local runs, stop = countRuns(function()
				h.counters.get("a")
			end)

			h.client.dispatch(h.zeroAll, ACTOR, {})
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(0))
			TestRunner.expectDeepEqual(h.counters.get("b"), counter(0))
			TestRunner.expectEqual(runs(), 2)

			-- A key the action never saw arrives: the action saw the table whole, so it is replayed over it.
			h.server(nil, { counters = { whole = { c = counter(5) } } })
			TestRunner.expectDeepEqual(h.counters.get("c"), counter(0))
			TestRunner.expectEqual(runs(), 2)

			h.server(1, {
				counters = {
					diffs = {
						a = Wire.diff(counter(1), counter(0)),
						b = Wire.diff(counter(2), counter(0)),
						c = Wire.diff(counter(5), counter(0)),
					},
				},
			})
			TestRunner.expectDeepEqual(h.counters.all(), { a = counter(0), b = counter(0), c = counter(0) })
			TestRunner.expectEqual(runs(), 2)
			stop()
		end,
	},
	{
		name = "client tables are sealed against the public writes",
		run = function()
			local h = harness()
			TestRunner.expectError(function()
				h.counters.set("a", counter(1))
			end, "only the library writes it")
			TestRunner.expectError(function()
				h.counters.patch({ a = counter(1) })
			end, "only the library writes it")
			TestRunner.expectError(function()
				h.phase.set({ name = "playing" })
			end, "only the library writes it")
			TestRunner.expectEqual(h.counters.get("a"), nil)
		end,
	},
	{
		name = "client message for a key no pending action read or wrote replays nothing",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1), b = counter(1) } } })

			h.client.dispatch(h.add, ACTOR, { key = "a", amount = 1 })
			TestRunner.expectEqual(h.reduced(), 1)

			h.server(nil, { counters = { diffs = { b = Wire.diff(counter(1), counter(2)) } } })
			TestRunner.expectEqual(h.reduced(), 1)
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(2))
			TestRunner.expectDeepEqual(h.counters.get("b"), counter(2))

			h.server(nil, { counters = { diffs = { a = Wire.diff(counter(1), counter(3)) } } })
			TestRunner.expectEqual(h.reduced(), 2)
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(4))
		end,
	},
	{
		name = "client effects are delivered once on dispatch and never on replay",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1) } } })
			local delivered: { string } = {}
			local connection = h.added.connect(function(key: string)
				table.insert(delivered, key)
			end)

			h.client.dispatch(h.add, ACTOR, { key = "a", amount = 1 })
			task.wait()
			TestRunner.expectDeepEqual(delivered, { "a" })

			h.server(nil, { counters = { diffs = { a = Wire.diff(counter(1), counter(5)) } } })
			h.server(1, { counters = { diffs = { a = Wire.diff(counter(5), counter(6)) } } })
			task.wait()
			TestRunner.expectEqual(h.reduced(), 2)
			TestRunner.expectDeepEqual(delivered, { "a" })
			connection.disconnect()
		end,
	},
	{
		name = "client dispatch from inside an effect subscribes it to nothing",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1) } } })
			local runs = 0
			local stop = Charm.effect(function()
				runs += 1
				if runs == 1 then
					h.client.dispatch(h.add, ACTOR, { key = "a", amount = 1 })
				end
			end)
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(2))

			h.server(nil, { counters = { diffs = { a = Wire.diff(counter(1), counter(5)) } } })
			TestRunner.expectDeepEqual(h.counters.get("a"), counter(6))
			TestRunner.expectEqual(runs, 1)
			stop()
		end,
	},
	{
		name = "client sends nothing for a payload that fails validation",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1) } } })
			TestRunner.expectEqual(h.client.dispatch(h.add, ACTOR, { key = "a" } :: any), false)
			TestRunner.expectEqual(#h.sent, 0)
			TestRunner.expectEqual(h.reduced(), 0)
		end,
	},
	{
		name = "client acknowledgement may not move backwards or pass the highest sequence sent",
		run = function()
			local h = harness()
			h.server(nil, { counters = { whole = { a = counter(1) } } })
			TestRunner.expectError(function()
				h.server(1, {})
			end, "exceeds highest dispatched sequence")

			h.client.dispatch(h.add, ACTOR, { key = "a", amount = 1 })
			h.server(1, { counters = { diffs = { a = Wire.diff(counter(1), counter(2)) } } })
			TestRunner.expectError(function()
				h.server(0, {})
			end, "must not move backwards")
		end,
	},
	{
		name = "client ignores the changes to a table it does not know, and a message of the wrong layout",
		run = function()
			local h = harness()
			TestRunner.expectWarning(function()
				h.client.receive({ ["9"] = { a = 1 } })
			end, "no table at that position")
			TestRunner.expectWarning(function()
				h.client.receive("not a message")
			end, "does not have the layout")
		end,
	},
}

return cases
