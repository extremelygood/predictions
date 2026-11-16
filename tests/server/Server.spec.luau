--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Action = require(ReplicatedStorage.Packages.Predictions.action)
local Charm = require(ReplicatedStorage.Packages.Charm)
local Effect = require(ReplicatedStorage.Packages.Predictions.effect)
local Server = require(ReplicatedStorage.Packages.Predictions.server)
local Store = require(ReplicatedStorage.Packages.Predictions.store)
local Types = require(ReplicatedStorage.Packages.Predictions._types)
local Wire = require(ReplicatedStorage.Packages.Predictions._wire)
local TestRunner = require(script.Parent.TestRunner)

local VALUE_KEY = Store.VALUE_KEY

-- What a client's message holds, by table name.
type Decoded = { [string]: any }

type Fixture = {
	server: Types.ServerRuntime<any, any, string>,
	-- Typed loosely so tests can read an entry's fields straight off get().
	items: any,
	notes: Types.Keyed<string, any>,
	round: Types.Value<any>,
	-- Not replicated: per client, the notes open to him (and switches that break his view or its rule).
	access: Types.Keyed<string, any>,
	setTime: (time: number) -> (),
	-- Each client's message from one flush, read back.
	flush: () -> { [string]: Decoded },
	sequence: (client: string) -> number,
}

type Options = {
	isActor: ((client: string, actor: unknown) -> boolean)?,
	scope: ((world: any, actor: any, payload: any) -> any)?,
	actionTime: { maxAge: number, maxLead: number }?,
}

local function fixture(options: Options?): Fixture
	local items = Store.keyed() :: Types.Keyed<string, any>
	local notes = Store.keyed() :: Types.Keyed<string, any>
	local round = Store.value({ phase = "warmup" })
	local access = Store.keyed() :: Types.Keyed<string, any>
	local tables: Types.Tables = { items = items, notes = notes, round = round }
	local names = Wire.tableNames(tables)
	local time = 100

	local server = Server({
		tables = tables,
		views = {
			items = true,
			round = true,
			notes = function(client: string)
				local open = access.get(client)
				if open ~= nil and open.viewBroken then
					error("view broke")
				end
				return function(key: string, entry: any): boolean
					if open ~= nil and open.ruleBroken then
						error("rule broke")
					end
					return entry.owner == client or (open ~= nil and open[key] == true)
				end
			end,
		},
		now = function(): number
			return time
		end,
		isActor = if options then options.isActor else nil,
		scope = if options then options.scope else nil,
		actionTime = if options then options.actionTime else nil,
	} :: Types.ServerConfig<any, any, string>)

	local sequences: { [string]: number } = {}

	return {
		server = server,
		items = items,
		notes = notes,
		round = round,
		access = access,
		setTime = function(newTime: number)
			time = newTime
		end,
		flush = function(): { [string]: Decoded }
			local decoded: { [string]: Decoded } = {}
			for client, message in server.flush() do
				local read = Wire.read(message)
				assert(read ~= nil, "flush made a message the wire cannot read")
				local result: Decoded = { ack = read.ack }
				for index, changes in read.tables do
					result[names[index]] = changes
				end
				decoded[client] = result
			end
			return decoded
		end,
		sequence = function(client: string): number
			local sequence = (sequences[client] or 0) + 1
			sequences[client] = sequence
			return sequence
		end,
	}
end

local setItem = Action.define({
	id = "SetItem",
	validate = function(payload: unknown): boolean
		return type(payload) == "table" and type((payload :: any).key) == "string" and type((payload :: any).n) == "number"
	end,
	reduce = function(state: any, payload: { key: string, n: number }, context: Types.ActionContext<any>): any
		state.items[payload.key] = { n = payload.n, actor = context.actor, time = context.actionTime }
		return state
	end,
})

local reject = Action.define({
	id = "Reject",
	validate = function(_payload: unknown): boolean
		return true
	end,
	reduce = function(_state: any, _payload: any, _context: Types.ActionContext<any>): any
		return nil
	end,
})

local nothing = Action.define({
	id = "Nothing",
	validate = function(_payload: unknown): boolean
		return true
	end,
	reduce = function(state: any, _payload: any, _context: Types.ActionContext<any>): any
		return state
	end,
})

-- A client sends `setItem` as himself.
local function send(state: Fixture, client: string, key: string, n: any, actionTime: number?)
	state.server.receive(client, {
		actionId = "SetItem",
		actor = client,
		payload = { key = key, n = n },
		sequence = state.sequence(client),
		actionTime = actionTime or 100,
	})
end

-- Adds the clients and takes their join messages, so the next flush holds only what changes after this.
local function joined(state: Fixture, clients: { string })
	for _, client in clients do
		state.server.addClient(client)
	end
	state.flush()
end

local cases: { TestRunner.TestCase } = {
	{
		name = "server acknowledges a client's action first, whatever then happens to it",
		run = function()
			local state = fixture()
			state.server.allow(setItem, function(_client: string, _actor: any, payload: { key: string, n: number }): boolean
				return payload.n >= 0
			end)
			joined(state, { "A" })

			send(state, "A", "a", 1)
			TestRunner.expectEqual(state.flush().A.ack, 1)
			TestRunner.expectEqual(state.items.get("a").n, 1)

			-- Fails validate.
			send(state, "A", "a", "many")
			TestRunner.expectEqual(state.flush().A.ack, 2)
			-- Fails accept.
			send(state, "A", "a", -1)
			TestRunner.expectEqual(state.flush().A.ack, 3)
			-- Acts as someone else.
			state.server.receive("A", {
				actionId = "SetItem",
				actor = "B",
				payload = { key = "a", n = 5 },
				sequence = state.sequence("A"),
				actionTime = 100,
			})
			-- A broken envelope past the sequence.
			state.server.receive("A", { sequence = state.sequence("A") })
			local decoded = state.flush().A
			TestRunner.expectEqual(decoded.ack, 5)
			TestRunner.expectEqual(decoded.items, nil)
			TestRunner.expectEqual(state.items.get("a").n, 1)

			-- Nothing to tell: no message.
			TestRunner.expectEqual(state.flush().A, nil)
		end,
	},
	{
		name = "server warns of stale and out-of-order sequences and ignores them",
		run = function()
			local state = fixture()
			state.server.allow(setItem)
			joined(state, { "A" })
			local function envelope(sequence: number): any
				return { actionId = "SetItem", actor = "A", payload = { key = "a", n = sequence }, sequence = sequence, actionTime = 100 }
			end

			TestRunner.expectWarning(function()
				state.server.receive("A", envelope(2))
			end, "out-of-order action sequence 2")
			TestRunner.expectEqual(state.items.get("a"), nil)
			TestRunner.expectEqual(state.flush().A, nil)

			state.server.receive("A", envelope(1))
			TestRunner.expectWarning(function()
				state.server.receive("A", envelope(1))
			end, "stale or duplicate action sequence 1")
			TestRunner.expectEqual(state.flush().A.ack, 1)
			TestRunner.expectEqual(state.items.get("a").n, 1)
		end,
	},
	{
		name = "server acknowledges an action clients are not allowed to send",
		run = function()
			local state = fixture()
			state.server.allow(setItem)
			joined(state, { "A" })
			TestRunner.expectWarning(function()
				state.server.receive("A", {
					actionId = "Reject",
					actor = "A",
					payload = {},
					sequence = state.sequence("A"),
					actionTime = 100,
				})
			end, 'action "Reject" from A at sequence 1, which clients are not allowed to send')
			send(state, "A", "a", 1)
			TestRunner.expectEqual(state.flush().A.ack, 2)
			TestRunner.expectEqual(state.items.get("a").n, 1)
		end,
	},
	{
		name = "server lets a client act as an actor only through isActor",
		run = function()
			local state = fixture({
				isActor = function(client: string, actor: unknown): boolean
					return actor == `{client}-character`
				end,
			})
			state.server.allow(setItem)
			send(state, "A", "a", 1)
			TestRunner.expectEqual(state.items.get("a"), nil)

			state.server.receive("A", {
				actionId = "SetItem",
				actor = "A-character",
				payload = { key = "a", n = 2 },
				sequence = state.sequence("A"),
				actionTime = 100,
			})
			TestRunner.expectDeepEqual(state.items.get("a"), { n = 2, actor = "A-character", time = 100 })
		end,
	},
	{
		name = "server clamps a client's action time",
		run = function()
			local state = fixture({ actionTime = { maxAge = 0.5, maxLead = 0.25 } })
			state.server.allow(setItem)
			send(state, "A", "old", 1, 10)
			send(state, "A", "ahead", 1, 200)
			send(state, "A", "within", 1, 99.75)
			TestRunner.expectEqual(state.items.get("old").time, 99.5)
			TestRunner.expectEqual(state.items.get("ahead").time, 100.25)
			TestRunner.expectEqual(state.items.get("within").time, 99.75)

			-- Without actionTime in the config the server's own time is taken.
			local plain = fixture()
			plain.server.allow(setItem)
			send(plain, "A", "a", 1, 50)
			TestRunner.expectEqual(plain.items.get("a").time, 100)
		end,
	},
	{
		name = "server dispatch needs no allow and returns whether the action was accepted",
		run = function()
			local state = fixture()
			joined(state, { "A" })
			state.setTime(120)
			TestRunner.expectEqual(state.server.dispatch(setItem, "server", { key = "a", n = 1 }), true)
			TestRunner.expectDeepEqual(state.items.get("a"), { n = 1, actor = "server", time = 120 })
			TestRunner.expectEqual(state.server.dispatch(reject, "server", {}), false)
			state.flush()

			-- Accepted but changing nothing: true, and nothing to send.
			TestRunner.expectEqual(state.server.dispatch(nothing, "server", {}), true)
			TestRunner.expectEqual(state.flush().A, nil)
		end,
	},
	{
		name = "server rejects an action writing an existing entry outside its scope",
		run = function()
			local state = fixture({
				scope = function(world: any, _actor: any, payload: any): any
					return { items = { [payload.key] = world.items[payload.key] } }
				end,
			})
			state.items.set("other", { n = 0 })
			local intruding = Action.define({
				id = "Intruding",
				validate = function(_payload: unknown): boolean
					return true
				end,
				reduce = function(state: any, _payload: any, _context: Types.ActionContext<any>): any
					state.items.other = { n = 9 }
					return state
				end,
			})
			TestRunner.expectWarning(function()
				TestRunner.expectEqual(state.server.dispatch(intruding, "server", { key = "a" }), false)
			end, 'entry "other", which exists but was not in its state')
			TestRunner.expectEqual(state.items.get("other").n, 0)

			-- The default scope gives the payload's key, which the action may add.
			TestRunner.expectEqual(state.server.dispatch(setItem, "server", { key = "a", n = 1 }), true)
			TestRunner.expectEqual(state.items.get("a").n, 1)
		end,
	},
	{
		name = "server works each change out once and shares it between clients",
		run = function()
			local state = fixture()
			state.items.set("a", { n = 1, keep = { x = 1 } })
			joined(state, { "A", "B" })

			state.items.set("a", { n = 2, keep = { x = 1 } })
			state.items.set("a", { n = 3, keep = { x = 1 } })
			state.round.set({ phase = "live" })
			local decoded = state.flush()
			TestRunner.expectDeepEqual(decoded.A.items.diffs, { a = { n = 3 } })
			TestRunner.expectEqual(decoded.A.items.diffs, decoded.B.items.diffs)
			TestRunner.expectDeepEqual(decoded.A.round.diffs, { [VALUE_KEY] = { phase = "live" } })
		end,
	},
	{
		name = "server sends a new entry whole and a removed one as gone",
		run = function()
			local state = fixture()
			state.items.set("a", { n = 1 })
			joined(state, { "A" })

			state.items.patch({ a = false, b = { n = 2 } })
			local decoded = state.flush().A
			TestRunner.expectDeepEqual(decoded.items.whole, { b = { n = 2 } })
			TestRunner.expectDeepEqual(decoded.items.gone, { "a" })
		end,
	},
	{
		name = "server sends nothing of a change undone or an entry created and removed before the flush",
		run = function()
			local state = fixture()
			state.items.set("a", { n = 1 })
			joined(state, { "A" })

			state.items.set("a", { n = 5 })
			state.items.set("a", { n = 1 })
			state.items.set("brief", { n = 1 })
			state.items.set("brief", nil)
			TestRunner.expectEqual(state.flush().A, nil)

			-- A client joining after it was created and removed never hears of it either.
			state.items.set("brief", { n = 1 })
			state.items.set("brief", nil)
			state.server.addClient("B")
			TestRunner.expectDeepEqual(state.flush().B.items.whole, { a = { n = 1 } })
		end,
	},
	{
		name = "server sends a joining client everything he may see, whole",
		run = function()
			local state = fixture()
			state.items.patch({ a = { n = 1 }, b = { n = 2 } })
			state.notes.patch({ mine = { owner = "A" }, theirs = { owner = "B" } })
			joined(state, { "B" })

			state.items.set("a", { n = 3 })
			state.server.addClient("A")
			local decoded = state.flush()
			TestRunner.expectDeepEqual(decoded.A.items, { whole = { a = { n = 3 }, b = { n = 2 } } })
			TestRunner.expectDeepEqual(decoded.A.notes, { whole = { mine = { owner = "A" } } })
			TestRunner.expectDeepEqual(decoded.A.round, { whole = { [VALUE_KEY] = { phase = "warmup" } } })
			-- B, who holds everything already, gets the diff.
			TestRunner.expectDeepEqual(decoded.B.items, { diffs = { a = { n = 3 } } })
			TestRunner.expectEqual(decoded.B.notes, nil)
		end,
	},
	{
		name = "server tells a client of an entry entering and leaving his view, and of nothing he was not sent",
		run = function()
			local state = fixture()
			state.notes.set("note", { owner = "B", text = "hi" })
			joined(state, { "A", "B" })

			state.notes.set("note", { owner = "A", text = "hi" })
			local decoded = state.flush()
			TestRunner.expectDeepEqual(decoded.A.notes, { whole = { note = { owner = "A", text = "hi" } } })
			TestRunner.expectDeepEqual(decoded.B.notes, { gone = { "note" } })

			state.notes.set("note", { owner = "A", text = "bye" })
			decoded = state.flush()
			TestRunner.expectDeepEqual(decoded.A.notes, { diffs = { note = { text = "bye" } } })
			TestRunner.expectEqual(decoded.B, nil)

			-- B was never sent it again: neither its change nor its removal reaches him.
			state.notes.set("note", { owner = "A", text = "again" })
			state.notes.set("note", nil)
			decoded = state.flush()
			TestRunner.expectDeepEqual(decoded.A.notes, { gone = { "note" } })
			TestRunner.expectEqual(decoded.B, nil)
		end,
	},
	{
		name = "server checks a table again for a client whose view ran again",
		run = function()
			local state = fixture()
			state.notes.patch({ open = { owner = "B" }, shut = { owner = "B" } })
			joined(state, { "A" })

			state.access.set("A", { open = true })
			TestRunner.expectDeepEqual(state.flush().A.notes, { whole = { open = { owner = "B" } } })

			state.access.set("A", { open = true, shut = true })
			TestRunner.expectDeepEqual(state.flush().A.notes, { whole = { shut = { owner = "B" } } })

			state.access.set("A", nil)
			local gone = state.flush().A.notes.gone
			table.sort(gone)
			TestRunner.expectDeepEqual(gone, { "open", "shut" })
		end,
	},
	{
		name = "server closes a table to a client whose view or rule throws",
		run = function()
			local state = fixture()
			state.notes.set("mine", { owner = "A" })
			joined(state, { "A" })

			TestRunner.expectWarning(function()
				state.access.set("A", { viewBroken = true })
			end, 'The view of "notes" failed for A')
			TestRunner.expectDeepEqual(state.flush().A.notes, { gone = { "mine" } })
			state.notes.set("mine", { owner = "A", n = 1 })
			TestRunner.expectEqual(state.flush().A, nil)

			state.access.set("A", {})
			TestRunner.expectDeepEqual(state.flush().A.notes, { whole = { mine = { owner = "A", n = 1 } } })

			state.access.set("A", { ruleBroken = true })
			local decoded: any = nil
			TestRunner.expectWarning(function()
				decoded = state.flush()
			end, 'The view rule of "notes" failed for A')
			TestRunner.expectDeepEqual(decoded.A.notes, { gone = { "mine" } })
		end,
	},
	{
		name = "server keeps the acknowledgement of a client not yet added for his first message",
		run = function()
			local state = fixture()
			state.server.allow(setItem)
			send(state, "A", "a", 1)
			TestRunner.expectEqual(state.flush().A, nil)

			state.server.addClient("A")
			local decoded = state.flush().A
			TestRunner.expectEqual(decoded.ack, 1)
			TestRunner.expectDeepEqual(decoded.items.whole, { a = { n = 1, actor = "A", time = 100 } })
		end,
	},
	{
		name = "server forgets a removed client's views, sequence and acknowledgement",
		run = function()
			local state = fixture()
			state.server.allow(setItem)
			joined(state, { "A" })
			send(state, "A", "a", 1)
			state.server.removeClient("A")
			state.items.set("b", { n = 2 })
			state.access.set("A", { viewBroken = true })
			TestRunner.expectEqual(state.flush().A, nil)

			-- His sequence starts again.
			state.server.receive("A", { actionId = "SetItem", actor = "A", payload = { key = "c", n = 3 }, sequence = 1, actionTime = 100 })
			TestRunner.expectEqual(state.items.get("c").n, 3)

			state.access.set("A", nil)
			state.server.addClient("A")
			local decoded = state.flush().A
			TestRunner.expectEqual(decoded.ack, 1)
			TestRunner.expectEqual(decoded.items.whole.b.n, 2)
		end,
	},
	{
		name = "server flush errors inside a Charm.batch",
		run = function()
			local state = fixture()
			TestRunner.expectError(function()
				Charm.batch(function()
					state.server.flush()
				end)
			end, "outside any Charm.batch")
		end,
	},
	{
		name = "server delivers an accepted action's effects once and a rejected one's never",
		run = function()
			local state = fixture()
			local fired = Effect.define({ name = "ServerFired" })
			local received: { any } = {}
			local connection = fired.connect(function(payload: any)
				table.insert(received, payload)
			end)
			local emitting = Action.define({
				id = "Emitting",
				validate = function(_payload: unknown): boolean
					return true
				end,
				reduce = function(state: any, payload: any, _context: Types.ActionContext<any>): any
					fired.emit(payload.n)
					return if payload.accept then state else nil
				end,
			})
			state.server.dispatch(emitting, "server", { n = 1, accept = true })
			state.server.dispatch(emitting, "server", { n = 2, accept = false })
			task.wait()
			TestRunner.expectDeepEqual(received, { 1 })
			connection.disconnect()
		end,
	},
}

return cases
