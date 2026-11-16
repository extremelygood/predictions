--!strict

-- One server and two clients wired together in memory, each side with its own stores under the same table names. The
-- test carries every message and envelope itself, so it decides when each one arrives; everything carried is copied
-- the way a RemoteEvent copies it, so nothing gets across by sharing a table.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage.Packages.Charm)
local Predictions = require(ReplicatedStorage.Packages.Predictions)
local Wire = require(ReplicatedStorage.Packages.Predictions._wire)
local TestRunner = require(script.Parent.TestRunner)

type Counter = { n: number }
type Note = { owner: string, text: string }
type Round = { phase: string }
type State = { [string]: any }

type AddPayload = { key: string, amount: number }
type NotePayload = { key: string, text: string }
type RoundPayload = { phase: string }

-- The actors each client may act as.
local UNITS: { [string]: string } = { a1 = "A", b1 = "B", c1 = "C" }
-- The actor of the server's own actions.
local SERVER_ACTOR = "server"

-- What a RemoteEvent delivers of `value`: new tables all the way down, no metatables. A table must be a dictionary of
-- string keys or an array without holes, and functions do not travel; either is an error here, since the library
-- promises never to send one.
local function remoteCopy(value: any): any
	local kind = type(value)
	if kind == "function" or kind == "thread" then
		error(`A RemoteEvent cannot carry a {kind}`, 2)
	end
	if kind ~= "table" then
		return value
	end
	local count = 0
	local strings = 0
	for key in value do
		count += 1
		if type(key) == "string" then
			strings += 1
		end
	end
	if strings ~= count then
		for index = 1, count do
			if value[index] == nil then
				error("A RemoteEvent cannot carry a table that is neither a dictionary of string keys nor an array without holes", 2)
			end
		end
	end
	local copy = {}
	for key, child in value do
		copy[key] = remoteCopy(child)
	end
	return copy
end

-- Actions -------------------------------------------------------------------------------------------------------

-- Adds to a counter; rejected when there is none.
local add = Predictions.defineAction({
	id = "add",
	validate = function(payload: unknown): boolean
		return type(payload) == "table"
			and type((payload :: any).key) == "string"
			and type((payload :: any).amount) == "number"
	end,
	scope = function(world: State, _actor: string, payload: AddPayload): State
		return { counters = { [payload.key] = world.counters[payload.key] } }
	end,
	reduce = function(state: State, payload: AddPayload, _context: Predictions.ActionContext<string>): State?
		local counter: Counter? = state.counters[payload.key]
		if counter == nil then
			return nil
		end
		return { counters = { [payload.key] = { n = counter.n + payload.amount } } }
	end,
})

-- Rewrites a note's text; rejected when there is none.
local writeNote = Predictions.defineAction({
	id = "writeNote",
	validate = function(payload: unknown): boolean
		return type(payload) == "table"
			and type((payload :: any).key) == "string"
			and type((payload :: any).text) == "string"
	end,
	scope = function(world: State, _actor: string, payload: NotePayload): State
		return { notes = { [payload.key] = world.notes[payload.key] } }
	end,
	reduce = function(state: State, payload: NotePayload, _context: Predictions.ActionContext<string>): State?
		local note: Note? = state.notes[payload.key]
		if note == nil then
			return nil
		end
		return { notes = { [payload.key] = { owner = note.owner, text = payload.text } } }
	end,
})

local setRound = Predictions.defineAction({
	id = "setRound",
	validate = function(payload: unknown): boolean
		return type(payload) == "table" and type((payload :: any).phase) == "string"
	end,
	scope = function(world: State): State
		return { round = world.round }
	end,
	reduce = function(_state: State, payload: RoundPayload, _context: Predictions.ActionContext<string>): State?
		return { round = { phase = payload.phase } }
	end,
})

-- The network ------------------------------------------------------------------------------------------------------

type Side = {
	counters: Predictions.Keyed<string, Counter>,
	notes: Predictions.Keyed<string, Note>,
	round: Predictions.Value<Round>,
}

-- A message a client was sent, read back: the acknowledgement and each table's changes by table name.
type Received = { ack: number?, tables: { [string]: Wire.TableChanges } }

type Peer = {
	name: string,
	stores: Side,
	runtime: Predictions.ClientRuntime<State, string>,
	-- The server's messages to him, copied, waiting to be delivered.
	inbox: { any },
	-- His envelopes, copied, waiting to be delivered to the server.
	outbox: { any },
	-- Every message he was sent, read back, in order.
	received: { Received },
}

type Net = {
	server: Predictions.ServerRuntime<State, string, string>,
	stores: Side,
	-- Not replicated: per client, the notes open to him besides his own.
	access: Predictions.Keyed<string, { [string]: true }>,
	peers: { [string]: Peer },
	-- The clients in the order they joined.
	order: { Peer },
	join: (name: string) -> Peer,
	-- Hands the server the envelopes `name` sent, in order.
	send: (name: string) -> (),
	-- The server's tick: each message flush returns is queued for its client.
	tick: () -> (),
	-- Hands `name` the messages queued for him, in order.
	deliver: (name: string) -> (),
	-- Every client's envelopes to the server, one tick, and every message delivered.
	sync: () -> (),
}

local function side(): Side
	return {
		counters = Predictions.keyed() :: Predictions.Keyed<string, Counter>,
		notes = Predictions.keyed() :: Predictions.Keyed<string, Note>,
		round = Predictions.value({ phase = "warmup" }) :: Predictions.Value<Round>,
	}
end

local function tablesOf(stores: Side): Predictions.Tables
	return { counters = stores.counters, notes = stores.notes, round = stores.round } :: any
end

-- A server and clients A and B, both holding what they may see: counter c at 1, each his own note. Note n belongs to
-- nobody.
local function network(): Net
	local stores = side()
	local access = Predictions.keyed() :: Predictions.Keyed<string, { [string]: true }>
	local names = Wire.tableNames(tablesOf(stores))

	local server = Predictions.server({
		tables = tablesOf(stores),
		views = {
			counters = true,
			round = true,
			notes = function(client: string)
				local open = access.get(client)
				return function(key: string, note: Note): boolean
					return note.owner == client or (open ~= nil and open[key] == true)
				end
			end,
		},
		now = os.clock,
		isActor = function(client: string, actor: unknown): boolean
			return type(actor) == "string" and UNITS[actor] == client
		end,
	} :: Predictions.ServerConfig<State, string, string>)
	server.allow(add, function(_client: string, _actor: string, payload: AddPayload): boolean
		return payload.amount <= 10
	end)
	server.allow(writeNote)
	server.allow(setRound)

	local peers: { [string]: Peer } = {}
	local order: { Peer } = {}

	local function join(name: string): Peer
		local peerStores = side()
		local outbox: { any } = {}
		local peer: Peer = {
			name = name,
			stores = peerStores,
			runtime = Predictions.client({
				tables = tablesOf(peerStores),
				send = function(envelope: Predictions.ActionEnvelope)
					table.insert(outbox, remoteCopy(envelope))
				end,
				now = os.clock,
			} :: Predictions.ClientConfig<State, string>),
			inbox = {},
			outbox = outbox,
			received = {},
		}
		peers[name] = peer
		table.insert(order, peer)
		server.addClient(name)
		return peer
	end

	local function send(name: string)
		-- The runtime's send appends to this very list, so it is emptied in place.
		local outbox = peers[name].outbox
		local envelopes = table.clone(outbox)
		table.clear(outbox)
		for _, envelope in envelopes do
			server.receive(name, envelope)
		end
	end

	local function tick()
		for client, message in server.flush() do
			local peer = peers[client]
			table.insert(peer.inbox, remoteCopy(message))
			local read = Wire.read(remoteCopy(message))
			assert(read ~= nil, "flush made a message the wire cannot read")
			local received: Received = { ack = read.ack, tables = {} }
			for index, changes in read.tables do
				received.tables[names[index]] = changes
			end
			table.insert(peer.received, received)
		end
	end

	local function deliver(name: string)
		local peer = peers[name]
		local messages = peer.inbox
		peer.inbox = {}
		for _, message in messages do
			peer.runtime.receive(message)
		end
	end

	local function sync()
		for _, peer in order do
			send(peer.name)
		end
		tick()
		for _, peer in order do
			deliver(peer.name)
		end
	end

	stores.counters.set("c", { n = 1 })
	stores.notes.patch({
		a = { owner = "A", text = "mine" },
		b = { owner = "B", text = "mine" },
		n = { owner = SERVER_ACTOR, text = "x" },
	})

	local net: Net = {
		server = server,
		stores = stores,
		access = access,
		peers = peers,
		order = order,
		join = join,
		send = send,
		tick = tick,
		deliver = deliver,
		sync = sync,
	}
	join("A")
	join("B")
	sync()
	return net
end

-- Assertions -----------------------------------------------------------------------------------------------------

local function expectSide(sideName: string, actual: any, expected: any)
	local succeeded, failure = pcall(function()
		TestRunner.expectDeepEqual(actual, expected)
	end)
	if not succeeded then
		error(`{sideName}: {failure}`, 2)
	end
end

-- What `read` gives on each side, by side name: "server" and each client's name.
local function expectSides(net: Net, read: (stores: Side) -> any, expected: { [string]: any })
	expectSide("server", read(net.stores), expected.server)
	for _, peer in net.order do
		expectSide(peer.name, read(peer.stores), expected[peer.name])
	end
end

-- What `read` gives on every side.
local function expectEverywhere(net: Net, read: (stores: Side) -> any, expected: any)
	expectSide("server", read(net.stores), expected)
	for _, peer in net.order do
		expectSide(peer.name, read(peer.stores), expected)
	end
end

local function counters(stores: Side): any
	return stores.counters.all()
end

local function notes(stores: Side): any
	return stores.notes.all()
end

local function round(stores: Side): any
	return stores.round.get()
end

-- Every key of a table a client was ever told of, whole, as a diff or gone.
local function keysSent(peer: Peer, name: string): { [string]: true }
	local keys: { [string]: true } = {}
	for _, received in peer.received do
		local changes = received.tables[name]
		if changes ~= nil then
			local whole: { [string]: any } = changes.whole or {}
			local diffs: { [string]: any } = changes.diffs or {}
			local gone: { string } = changes.gone or {}
			for key in whole do
				keys[key] = true
			end
			for key in diffs do
				keys[key] = true
			end
			for _, key in gone do
				keys[key] = true
			end
		end
	end
	return keys
end

local function lastReceived(peer: Peer): Received
	return peer.received[#peer.received]
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

-- The small game ---------------------------------------------------------------------------------------------------

-- In-memory stand-ins for what the small game's scripts use.
type FakeSignal = {
	Connect: (self: FakeSignal, listener: (...any) -> ()) -> (),
	fire: (...any) -> (),
}

local function fakeSignal(): FakeSignal
	local listeners: { (...any) -> () } = {}
	return {
		Connect = function(_self: FakeSignal, listener: (...any) -> ())
			table.insert(listeners, listener)
		end,
		fire = function(...: any)
			for _, listener in listeners do
				listener(...)
			end
		end,
	}
end

-- A RemoteEvent: what is fired is copied and held until the test delivers it.
type FakeRemote = {
	-- The end the server's script holds.
	server: any,
	-- The end a client's script holds.
	client: (player: string) -> any,
	-- Delivers what the clients fired, in order.
	toServer: () -> (),
	-- Delivers what the server fired to `player`, in order.
	toClient: (player: string) -> (),
	-- Messages fired to `player` and not delivered yet.
	waiting: (player: string) -> number,
}

local function fakeRemote(): FakeRemote
	local onServerEvent = fakeSignal()
	local onClientEvent: { [string]: FakeSignal } = {}
	local toServer: { { player: string, envelope: any } } = {}
	local toClients: { [string]: { any } } = {}

	local function client(player: string): any
		onClientEvent[player] = fakeSignal()
		toClients[player] = {}
		return {
			OnClientEvent = onClientEvent[player],
			FireServer = function(_self: any, envelope: any)
				table.insert(toServer, { player = player, envelope = remoteCopy(envelope) })
			end,
		}
	end

	return {
		server = {
			OnServerEvent = onServerEvent,
			FireClient = function(_self: any, player: string, message: any)
				table.insert(toClients[player], remoteCopy(message))
			end,
		},
		client = client,
		toServer = function()
			local fired = toServer
			toServer = {}
			for _, item in fired do
				onServerEvent.fire(item.player, item.envelope)
			end
		end,
		toClient = function(player: string)
			local fired = toClients[player]
			toClients[player] = {}
			for _, message in fired do
				onClientEvent[player].fire(message)
			end
		end,
		waiting = function(player: string): number
			return #toClients[player]
		end,
	}
end

-- The README's small game. The scripts' bodies are the README's, line for line; each script is a function here so
-- each side gets its own module state, and what a script finds in the place (the remote, Players, RunService, the
-- button) is handed to it.

-- ReplicatedStorage.Score
local function scoreModule()
	type State = { score: number }

	local score = Predictions.value(0)
	local tables: Predictions.Tables = { score = score }

	local addPoints = Predictions.defineAction({
		id = "addPoints",
		validate = function(points: unknown): boolean
			return points == 1 or points == 2 or points == 3
		end,
		reduce = function(state: State, points: number): State?
			return { score = state.score + points }
		end,
	})

	return { score = score, tables = tables, addPoints = addPoints }
end

type Score = typeof(scoreModule())

-- ServerScriptService.Server
local function serverScript(Score: Score, remote: any, Players: any, RunService: any)
	local server = Predictions.server({ tables = Score.tables, views = { score = true }, now = os.clock })
	server.allow(Score.addPoints)
	Players.PlayerAdded:Connect(server.addClient)
	Players.PlayerRemoving:Connect(server.removeClient)
	remote.OnServerEvent:Connect(server.receive)
	RunService.Heartbeat:Connect(function()
		for player, message in server.flush() do
			remote:FireClient(player, message)
		end
	end)
end

-- StarterPlayerScripts.Client
local function clientScript(Score: Score, remote: any, Players: any, button: any)
	local client = Predictions.client({
		tables = Score.tables,
		send = function(envelope)
			remote:FireServer(envelope)
		end,
		now = os.clock,
	})
	remote.OnClientEvent:Connect(client.receive)

	button.Activated:Connect(function()
		client.dispatch(Score.addPoints, Players.LocalPlayer, 1)
	end)
end

-- Cases ------------------------------------------------------------------------------------------------------------

local cases: { TestRunner.TestCase } = {
	{
		name = "end to end: a predicted action is confirmed without a second wake, and the other client sees it after the tick",
		run = function()
			local net = network()
			local a, b = net.peers.A, net.peers.B
			local runsA, stopA = countRuns(function()
				a.stores.counters.get("c")
			end)
			local runsB, stopB = countRuns(function()
				b.stores.counters.get("c")
			end)

			TestRunner.expectEqual(a.runtime.dispatch(add, "a1", { key = "c", amount = 2 }), true)
			TestRunner.expectDeepEqual(a.stores.counters.get("c"), { n = 3 })
			TestRunner.expectEqual(runsA(), 2)

			net.send("A")
			expectSides(net, counters, { server = { c = { n = 3 } }, A = { c = { n = 3 } }, B = { c = { n = 1 } } })

			net.tick()
			TestRunner.expectEqual(lastReceived(a).ack, 1)
			net.deliver("A")
			net.deliver("B")
			expectEverywhere(net, counters, { c = { n = 3 } })
			TestRunner.expectEqual(runsA(), 2)
			TestRunner.expectEqual(runsB(), 2)
			stopA()
			stopB()
		end,
	},
	{
		name = "end to end: an action the server's accept rejects rolls back, and nobody else ever sees it",
		run = function()
			local net = network()
			local a, b = net.peers.A, net.peers.B
			local runsA, stopA = countRuns(function()
				a.stores.counters.get("c")
			end)
			local runsB, stopB = countRuns(function()
				b.stores.counters.get("c")
			end)
			local receivedB = #b.received

			-- accept takes at most 10.
			TestRunner.expectEqual(a.runtime.dispatch(add, "a1", { key = "c", amount = 50 }), true)
			TestRunner.expectDeepEqual(a.stores.counters.get("c"), { n = 51 })

			net.sync()
			expectEverywhere(net, counters, { c = { n = 1 } })
			TestRunner.expectDeepEqual(lastReceived(a), { ack = 1, tables = {} })
			TestRunner.expectEqual(#b.received, receivedB)
			TestRunner.expectEqual(runsA(), 3)
			TestRunner.expectEqual(runsB(), 1)
			stopA()
			stopB()
		end,
	},
	{
		name = "end to end: two actions from one client in one tick are confirmed together",
		run = function()
			local net = network()
			local a = net.peers.A
			local runsA, stopA = countRuns(function()
				a.stores.counters.get("c")
			end)

			a.runtime.dispatch(add, "a1", { key = "c", amount = 1 })
			a.runtime.dispatch(add, "a1", { key = "c", amount = 2 })
			TestRunner.expectDeepEqual(a.stores.counters.get("c"), { n = 4 })
			TestRunner.expectEqual(runsA(), 3)

			net.sync()
			TestRunner.expectEqual(lastReceived(a).ack, 2)
			expectEverywhere(net, counters, { c = { n = 4 } })
			TestRunner.expectEqual(runsA(), 3)
			stopA()
		end,
	},
	{
		name = "end to end: an action from each client on one entry in one tick ends at the server's result on both",
		run = function()
			local net = network()
			local a, b = net.peers.A, net.peers.B

			a.runtime.dispatch(add, "a1", { key = "c", amount = 1 })
			b.runtime.dispatch(add, "b1", { key = "c", amount = 10 })
			expectSides(net, counters, { server = { c = { n = 1 } }, A = { c = { n = 2 } }, B = { c = { n = 11 } } })

			-- A's arrives first: the server works out 1 + 1, then + 10.
			net.sync()
			TestRunner.expectEqual(lastReceived(a).ack, 1)
			TestRunner.expectEqual(lastReceived(b).ack, 1)
			expectEverywhere(net, counters, { c = { n = 12 } })
		end,
	},
	{
		name = "end to end: the server's own dispatch on an entry under prediction is replayed over, then confirmed",
		run = function()
			local net = network()
			local a = net.peers.A
			local runsA, stopA = countRuns(function()
				a.stores.counters.get("c")
			end)

			a.runtime.dispatch(add, "a1", { key = "c", amount = 1 })
			TestRunner.expectEqual(runsA(), 2)

			-- The server changes the entry before A's action reaches it.
			TestRunner.expectEqual(net.server.dispatch(add, SERVER_ACTOR, { key = "c", amount = 100 }), true)
			net.tick()
			TestRunner.expectEqual(lastReceived(a).ack, nil)
			net.deliver("A")
			net.deliver("B")
			expectSides(net, counters, { server = { c = { n = 101 } }, A = { c = { n = 102 } }, B = { c = { n = 101 } } })
			TestRunner.expectEqual(runsA(), 3)

			net.sync()
			TestRunner.expectEqual(lastReceived(a).ack, 1)
			expectEverywhere(net, counters, { c = { n = 102 } })
			TestRunner.expectEqual(runsA(), 3)
			stopA()
		end,
	},
	{
		name = "end to end: a rule view sends each client his own entries, and one entering, changing and leaving his view",
		run = function()
			local net = network()
			local a, b = net.peers.A, net.peers.B
			local mineA = { owner = "A", text = "mine" }
			local mineB = { owner = "B", text = "mine" }
			expectSides(net, notes, {
				server = { a = mineA, b = mineB, n = { owner = SERVER_ACTOR, text = "x" } },
				A = { a = mineA },
				B = { b = mineB },
			})

			-- n enters B's view: sent whole.
			net.access.set("B", { n = true })
			net.sync()
			TestRunner.expectDeepEqual(
				lastReceived(b).tables.notes,
				{ whole = { n = { owner = SERVER_ACTOR, text = "x" } }, diffs = nil, gone = nil }
			)
			TestRunner.expectDeepEqual(b.stores.notes.get("n"), { owner = SERVER_ACTOR, text = "x" })

			-- It changes: sent as the field that differs.
			TestRunner.expectEqual(net.server.dispatch(writeNote, SERVER_ACTOR, { key = "n", text = "y" }), true)
			net.sync()
			TestRunner.expectDeepEqual(lastReceived(b).tables.notes, { diffs = { n = { text = "y" } } })
			TestRunner.expectDeepEqual(b.stores.notes.get("n"), { owner = SERVER_ACTOR, text = "y" })

			-- It leaves: gone.
			net.access.set("B", nil)
			net.sync()
			TestRunner.expectDeepEqual(lastReceived(b).tables.notes, { gone = { "n" } })
			TestRunner.expectEqual(b.stores.notes.get("n"), nil)

			-- Out of his view it changes again: he is told nothing.
			local receivedB = #b.received
			net.server.dispatch(writeNote, SERVER_ACTOR, { key = "n", text = "z" })
			net.sync()
			TestRunner.expectEqual(#b.received, receivedB)

			expectSides(net, notes, {
				server = { a = mineA, b = mineB, n = { owner = SERVER_ACTOR, text = "z" } },
				A = { a = mineA },
				B = { b = mineB },
			})
			TestRunner.expectDeepEqual(keysSent(a, "notes"), { a = true })
			TestRunner.expectDeepEqual(keysSent(b, "notes"), { b = true, n = true })
		end,
	},
	{
		name = "end to end: a client added late gets exactly what he may see, confirmed actions included",
		run = function()
			local net = network()
			local a = net.peers.A

			a.runtime.dispatch(add, "a1", { key = "c", amount = 2 })
			a.runtime.dispatch(setRound, "a1", { phase = "playing" })
			net.stores.notes.set("c", { owner = "C", text = "waiting" })
			net.sync()
			TestRunner.expectEqual(lastReceived(a).ack, 2)

			local c = net.join("C")
			TestRunner.expectEqual(#c.received, 0)
			net.sync()
			TestRunner.expectEqual(#c.received, 1)
			local first = lastReceived(c)
			TestRunner.expectEqual(first.ack, nil)
			TestRunner.expectDeepEqual(keysSent(c, "notes"), { c = true })
			TestRunner.expectDeepEqual(keysSent(c, "counters"), { c = true })

			expectEverywhere(net, counters, { c = { n = 3 } })
			expectEverywhere(net, round, { phase = "playing" })
			expectSide("C", notes(c.stores), { c = { owner = "C", text = "waiting" } })
			TestRunner.expectDeepEqual(keysSent(a, "notes"), { a = true })
		end,
	},
	{
		name = "end to end: an action sent as an actor only another client may use is rejected and rolled back",
		run = function()
			local net = network()
			local a, b = net.peers.A, net.peers.B
			local runsA, stopA = countRuns(function()
				a.stores.counters.get("c")
			end)
			local receivedB = #b.received

			-- The client does not check the actor: it predicts.
			TestRunner.expectEqual(a.runtime.dispatch(add, "b1", { key = "c", amount = 1 }), true)
			TestRunner.expectDeepEqual(a.stores.counters.get("c"), { n = 2 })

			net.sync()
			TestRunner.expectDeepEqual(lastReceived(a), { ack = 1, tables = {} })
			TestRunner.expectEqual(#b.received, receivedB)
			expectEverywhere(net, counters, { c = { n = 1 } })
			TestRunner.expectEqual(runsA(), 3)
			stopA()
		end,
	},
	{
		name = "end to end: a value table is predicted and confirmed",
		run = function()
			local net = network()
			local a, b = net.peers.A, net.peers.B
			local runsA, stopA = countRuns(function()
				a.stores.round.get()
			end)

			TestRunner.expectEqual(a.runtime.dispatch(setRound, "a1", { phase = "playing" }), true)
			expectSides(net, round, { server = { phase = "warmup" }, A = { phase = "playing" }, B = { phase = "warmup" } })
			TestRunner.expectEqual(runsA(), 2)

			net.sync()
			TestRunner.expectDeepEqual(lastReceived(b).tables.round, { diffs = { v = { phase = "playing" } } })
			expectEverywhere(net, round, { phase = "playing" })
			TestRunner.expectEqual(runsA(), 2)
			stopA()
		end,
	},
	{
		name = "end to end: the README's small game, the whole state with no scope and the client as the actor",
		run = function()
			local remote = fakeRemote()
			local players = { PlayerAdded = fakeSignal(), PlayerRemoving = fakeSignal() }
			local runService = { Heartbeat = fakeSignal() }
			local serverScore = scoreModule()
			serverScript(serverScore, remote.server, players, runService)

			players.PlayerAdded.fire("A")
			players.PlayerAdded.fire("B")
			local scoreA, scoreB = scoreModule(), scoreModule()
			local buttonA = { Activated = fakeSignal() }
			clientScript(scoreA, remote.client("A"), { LocalPlayer = "A" }, buttonA)
			clientScript(scoreB, remote.client("B"), { LocalPlayer = "B" }, { Activated = fakeSignal() })
			runService.Heartbeat.fire()
			remote.toClient("A")
			remote.toClient("B")

			local runsA, stopA = countRuns(function()
				scoreA.score.get()
			end)
			local runsB, stopB = countRuns(function()
				scoreB.score.get()
			end)

			buttonA.Activated.fire()
			TestRunner.expectEqual(scoreA.score.get(), 1)
			TestRunner.expectEqual(scoreB.score.get(), 0)
			TestRunner.expectEqual(serverScore.score.get(), 0)

			remote.toServer()
			TestRunner.expectEqual(serverScore.score.get(), 1)
			runService.Heartbeat.fire()
			TestRunner.expectEqual(remote.waiting("A"), 1)
			TestRunner.expectEqual(remote.waiting("B"), 1)
			remote.toClient("A")
			remote.toClient("B")
			TestRunner.expectEqual(scoreA.score.get(), 1)
			TestRunner.expectEqual(scoreB.score.get(), 1)
			TestRunner.expectEqual(runsA(), 2)
			TestRunner.expectEqual(runsB(), 2)

			-- A player who left is sent nothing.
			players.PlayerRemoving.fire("B")
			buttonA.Activated.fire()
			remote.toServer()
			runService.Heartbeat.fire()
			TestRunner.expectEqual(remote.waiting("B"), 0)
			remote.toClient("A")
			TestRunner.expectEqual(serverScore.score.get(), 2)
			TestRunner.expectEqual(scoreA.score.get(), 2)
			stopA()
			stopB()
		end,
	},
}

return cases
