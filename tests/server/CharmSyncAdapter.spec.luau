--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Prediction = require(ReplicatedStorage.Packages.Predictions)
local FakeCharmSync = require(script.Parent.FakeCharmSync)
local TestRunner = require(script.Parent.TestRunner)

type State = {
	counter: number,
}

type Payload = {
	amount: number,
}

type ClientEndpoint = {
	runtime: any,
	sync: any,
	charm: any,
	action: any,
	envelopes: { any },
	publications: { number },
}

local ACTOR_A = "actor-a"
local ACTOR_B = "actor-b"

local function defineCounterAction()
	return Prediction.defineAction({
		id = "AdjustCounter",
		validate = function(payload: any): boolean
			return type(payload) == "table" and type(payload.amount) == "number"
		end,
		reduce = function(state: State, payload: Payload): State
			return {
				counter = state.counter + payload.amount,
			}
		end,
	})
end

local function createClientEndpoint(action: any): ClientEndpoint
	local publications: { number } = {}
	local envelopes: { any } = {}
	local charm = FakeCharmSync.new()
	local runtime = Prediction.client({
		initialState = {
			counter = 0,
		},
		publish = function(state: State)
			table.insert(publications, state.counter)
		end,
		send = function(envelope: any)
			table.insert(envelopes, envelope)
		end,
		now = function(): number
			return 100
		end,
	})
	local sync = Prediction.adapters.charmSync.client({
		runtime = runtime,
		charmSync = charm.library,
		predictedSignals = { "counter" },
	})

	local boundAction = runtime.register(action)

	return {
		runtime = runtime,
		sync = sync,
		charm = charm,
		action = boundAction,
		envelopes = envelopes,
		publications = publications,
	}
end

local function createServerEndpoint(action: any, subscribedActors: { string }, rejectAmount: number?)
	local charm = FakeCharmSync.new()
	local outgoing: { { actor: string, payload: any } } = {}
	local state: State = {
		counter = 0,
	}
	local sync = Prediction.adapters.charmSync.server({
		charmSync = charm.library,
		send = function(actor: string, payload: any)
			table.insert(outgoing, {
				actor = actor,
				payload = payload,
			})
		end,
	})

	sync.start()

	local runtime = Prediction.server({
		getState = function(): State
			return state
		end,
		publish = function(nextState: State)
			state = nextState
			for _, actor in subscribedActors do
				charm.queueDelivery(actor, {
					{
						type = "patch",
						data = {
							counter = nextState.counter,
						},
					},
				})
			end
		end,
		now = function(): number
			return 200
		end,
		replication = sync,
	})

	runtime.register(action, {
		acceptClient = function(_actor: string, payload: Payload): boolean
			return rejectAmount == nil or payload.amount ~= rejectAmount
		end,
	})

	return {
		runtime = runtime,
		sync = sync,
		charm = charm,
		outgoing = outgoing,
		getState = function(): State
			return state
		end,
	}
end

local cases: { TestRunner.TestCase } = {
	{
		name = "accepted patch and watermark reconcile remaining predictions atomically",
		run = function()
			local action = defineCounterAction()
			local client = createClientEndpoint(action)
			local server = createServerEndpoint(action, { ACTOR_A })

			TestRunner.expectEqual(client.action.dispatch({ amount = 1 }), true)
			TestRunner.expectEqual(client.action.dispatch({ amount = 1 }), true)
			TestRunner.expectEqual(client.runtime.getPendingCount(), 2)

			server.runtime.receive(ACTOR_A, client.envelopes[1])
			TestRunner.expectEqual(#server.outgoing, 1)
			TestRunner.expectEqual(server.outgoing[1].actor, ACTOR_A)
			TestRunner.expectDeepEqual(server.outgoing[1].payload, {
				charmUpdates = {
					{
						type = "patch",
						data = { counter = 1 },
					},
				},
				processedSequence = 1,
			})

			table.clear(client.publications)
			local regularUpdates = client.sync.apply(server.outgoing[1].payload)
			TestRunner.expectDeepEqual(regularUpdates, {})
			TestRunner.expectEqual(client.runtime.getAuthoritativeState().counter, 1)
			TestRunner.expectEqual(client.runtime.getPredictedState().counter, 2)
			TestRunner.expectEqual(client.runtime.getPendingCount(), 1)
			TestRunner.expectDeepEqual(client.publications, { 2 })
			TestRunner.expectEqual(server.charm.getFlushCount(), 1)
			server.sync.destroy()
		end,
	},
	{
		name = "server rejection sends acknowledgement-only rollback",
		run = function()
			local action = defineCounterAction()
			local client = createClientEndpoint(action)
			local server = createServerEndpoint(action, { ACTOR_A }, 100)

			TestRunner.expectEqual(client.action.dispatch({ amount = 100 }), true)
			TestRunner.expectEqual(client.runtime.getPredictedState().counter, 100)
			server.runtime.receive(ACTOR_A, client.envelopes[1])

			TestRunner.expectEqual(#server.outgoing, 1)
			TestRunner.expectDeepEqual(server.outgoing[1].payload, {
				charmUpdates = {},
				processedSequence = 1,
			})
			TestRunner.expectEqual(server.getState().counter, 0)

			table.clear(client.publications)
			client.sync.apply(server.outgoing[1].payload)
			TestRunner.expectEqual(client.runtime.getAuthoritativeState().counter, 0)
			TestRunner.expectEqual(client.runtime.getPredictedState().counter, 0)
			TestRunner.expectEqual(client.runtime.getPendingCount(), 0)
			TestRunner.expectDeepEqual(client.publications, { 0 })
			server.sync.destroy()
		end,
	},
	{
		name = "mixed history reconciles predicted keys and preserves regular update order",
		run = function()
			local client = createClientEndpoint(defineCounterAction())
			local payload = {
				charmUpdates = {
					{ type = "init", data = { counter = 4, status = "boot" } },
					{ type = "patch", data = { counter = 5, status = "warm" } },
					{ type = "patch", data = { status = "steady" } },
					{ type = "patch", data = { counter = 7 } },
				},
				processedSequence = 0,
			}
			local snapshot = TestRunner.cloneDeep(payload)

			local regularUpdates = client.sync.apply(payload)
			TestRunner.expectDeepEqual(regularUpdates, {
				{ type = "init", data = { status = "boot" } },
				{ type = "patch", data = { status = "warm" } },
				{ type = "patch", data = { status = "steady" } },
			})
			TestRunner.expectDeepEqual(client.charm.getPatchCalls(), {
				{
					{ type = "init", data = { counter = 4 } },
					{ type = "patch", data = { counter = 5 } },
					{ type = "patch", data = { counter = 7 } },
				},
			})
			TestRunner.expectDeepEqual(payload, snapshot)
			TestRunner.expectEqual(client.runtime.getAuthoritativeState().counter, 7)
			TestRunner.expectEqual(client.runtime.getPredictedState().counter, 7)
			TestRunner.expectDeepEqual(client.publications, { 7 })
		end,
	},
	{
		name = "regressing and malformed payloads fail before changing state",
		run = function()
			local client = createClientEndpoint(defineCounterAction())
			TestRunner.expectEqual(client.action.dispatch({ amount = 1 }), true)
			TestRunner.expectEqual(client.action.dispatch({ amount = 1 }), true)
			client.sync.apply({
				charmUpdates = {
					{ type = "patch", data = { counter = 3 } },
				},
				processedSequence = 2,
			})

			local patchCount = #client.charm.getPatchCalls()
			local publicationCount = #client.publications
			TestRunner.expectError(function()
				client.sync.apply({
					charmUpdates = {
						{ type = "patch", data = { counter = 99 } },
					},
					processedSequence = 1,
				})
			end, "processedSequence must not move backwards")
			TestRunner.expectError(function()
				client.sync.apply({
					charmUpdates = {
						{ type = "patch", data = { counter = 99 } },
						{ type = "replace", data = { counter = 100 } },
					},
					processedSequence = 2,
				} :: any)
			end, 'must be "init" or "patch"')

			TestRunner.expectEqual(#client.charm.getPatchCalls(), patchCount)
			TestRunner.expectEqual(#client.publications, publicationCount)
			TestRunner.expectEqual(client.runtime.getAuthoritativeState().counter, 3)
			TestRunner.expectEqual(client.runtime.getPredictedState().counter, 3)
		end,
	},
	{
		name = "watermarks remain isolated when one patch is fanned out to two actors",
		run = function()
			local action = defineCounterAction()
			local clientA = createClientEndpoint(action)
			local clientB = createClientEndpoint(action)
			local server = createServerEndpoint(action, { ACTOR_A, ACTOR_B })

			clientA.action.dispatch({ amount = 1 })
			clientB.action.dispatch({ amount = 1 })
			server.runtime.receive(ACTOR_A, clientA.envelopes[1])
			TestRunner.expectEqual(#server.outgoing, 2)
			TestRunner.expectEqual(server.outgoing[1].actor, ACTOR_A)
			TestRunner.expectEqual(server.outgoing[1].payload.processedSequence, 1)
			TestRunner.expectEqual(server.outgoing[2].actor, ACTOR_B)
			TestRunner.expectEqual(server.outgoing[2].payload.processedSequence, nil)

			table.clear(server.outgoing)
			server.runtime.receive(ACTOR_B, clientB.envelopes[1])
			TestRunner.expectEqual(#server.outgoing, 2)
			TestRunner.expectEqual(server.outgoing[1].actor, ACTOR_A)
			TestRunner.expectEqual(server.outgoing[1].payload.processedSequence, nil)
			TestRunner.expectEqual(server.outgoing[2].actor, ACTOR_B)
			TestRunner.expectEqual(server.outgoing[2].payload.processedSequence, 1)
			TestRunner.expectEqual(server.getState().counter, 2)
			server.sync.destroy()
		end,
	},
}

return cases
