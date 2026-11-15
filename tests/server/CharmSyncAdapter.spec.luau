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

type ServerOptions = {
	subscribedActors: { string },
	-- acceptClient refuses this amount.
	rejectAmount: number?,
	-- publish throws for an action of this amount.
	failPublishAmount: number?,
}

local ACTOR_A = "actor-a"
local ACTOR_B = "actor-b"

-- The reducer throws for this amount.
local FAILING_AMOUNT = 13

local function defineCounterAction()
	return Prediction.defineAction({
		id = "AdjustCounter",
		validate = function(payload: any): boolean
			return type(payload) == "table" and type(payload.amount) == "number"
		end,
		reduce = function(state: State, payload: Payload): State
			if payload.amount == FAILING_AMOUNT then
				error("reducer failed on purpose")
			end

			return {
				counter = state.counter + payload.amount,
			}
		end,
	})
end

local function envelope(sequence: number, amount: number): any
	return {
		actionId = "AdjustCounter",
		payload = { amount = amount },
		sequence = sequence,
		actionTime = 100,
	}
end

local function acknowledgementOnly(sequence: number): any
	return {
		charmUpdates = {},
		processedSequence = sequence,
	}
end

local function createClientEndpoint(action: any, predictedSignals: { [string]: string }?): ClientEndpoint
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
		send = function(sent: any)
			table.insert(envelopes, sent)
		end,
		now = function(): number
			return 100
		end,
	})
	local sync = Prediction.adapters.charmSync.client({
		runtime = runtime,
		charmSync = charm.library,
		predictedSignals = predictedSignals or { counter = "counter" },
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

local function createServerEndpoint(action: any, options: ServerOptions)
	local charm = FakeCharmSync.new()
	local outgoing: { { actor: string, payload: any } } = {}
	local state: State = {
		counter = 0,
	}
	local sync = Prediction.adapters.charmSync.server({
		charmSync = charm.library :: any,
		send = function(actor: string, payload: any)
			table.insert(outgoing, {
				actor = actor,
				payload = payload,
			})
		end,
	})

	sync.start()

	local runtime = Prediction.server({
		getState = function(_payload: unknown): State
			return state
		end,
		publish = function(before: State, after: State)
			assert(before == state, "publish was not given the table getState returned")
			if options.failPublishAmount ~= nil and after.counter - before.counter == options.failPublishAmount then
				error("publish failed on purpose")
			end

			state = after
			for _, actor in options.subscribedActors do
				charm.queueDelivery(actor, {
					{
						type = "patch",
						data = {
							counter = after.counter,
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
			return options.rejectAmount == nil or payload.amount ~= options.rejectAmount
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
		name = "start connects and stops Charm Sync's interval; destroy stops the adapter and start restarts it",
		run = function()
			local server = createServerEndpoint(defineCounterAction(), { subscribedActors = { ACTOR_A } })

			TestRunner.expectEqual(server.charm.getConnectCount(), 1)
			TestRunner.expectEqual(server.charm.getDisconnectCount(), 1)
			TestRunner.expectEqual(server.charm.isIntervalRunning(), false)

			server.sync.start()
			TestRunner.expectEqual(server.charm.getConnectCount(), 1)

			server.runtime.receive(ACTOR_A, envelope(1, 1))
			server.sync.destroy()
			server.sync.destroy()
			server.sync.flush()
			TestRunner.expectEqual(server.charm.getFlushCount(), 0)
			TestRunner.expectEqual(#server.outgoing, 0)

			server.sync.start()
			TestRunner.expectEqual(server.charm.getConnectCount(), 2)
			TestRunner.expectEqual(server.charm.isIntervalRunning(), false)
			server.sync.flush()
			-- The acknowledgement waiting at destroy was dropped; the patch still queued in Charm Sync goes.
			TestRunner.expectEqual(#server.outgoing, 1)
			TestRunner.expectEqual(server.outgoing[1].payload.processedSequence, nil)
			server.sync.destroy()
		end,
	},
	{
		name = "an acknowledgement is sent only by flush and rides the payload that holds the action",
		run = function()
			local action = defineCounterAction()
			local client = createClientEndpoint(action)
			local server = createServerEndpoint(action, { subscribedActors = { ACTOR_A } })

			TestRunner.expectEqual(client.action.dispatch({ amount = 1 }), true)
			TestRunner.expectEqual(client.action.dispatch({ amount = 1 }), true)
			TestRunner.expectEqual(client.runtime.getPendingCount(), 2)

			server.runtime.receive(ACTOR_A, client.envelopes[1])
			TestRunner.expectEqual(#server.outgoing, 0)
			TestRunner.expectEqual(server.charm.getFlushCount(), 0)

			server.sync.flush()
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

			-- Nothing is left to send on the next tick.
			server.sync.flush()
			TestRunner.expectEqual(#server.outgoing, 1)
			server.sync.destroy()
		end,
	},
	{
		name = "a rejected action is acknowledged alone and rolls the prediction back",
		run = function()
			local action = defineCounterAction()
			local client = createClientEndpoint(action)
			local server = createServerEndpoint(action, { subscribedActors = { ACTOR_A }, rejectAmount = 100 })

			TestRunner.expectEqual(client.action.dispatch({ amount = 100 }), true)
			TestRunner.expectEqual(client.runtime.getPredictedState().counter, 100)
			server.runtime.receive(ACTOR_A, client.envelopes[1])
			TestRunner.expectEqual(#server.outgoing, 0)

			server.sync.flush()
			TestRunner.expectEqual(#server.outgoing, 1)
			TestRunner.expectDeepEqual(server.outgoing[1].payload, acknowledgementOnly(1))
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
		name = "two actions in one tick give one acknowledgement with the higher sequence",
		run = function()
			local action = defineCounterAction()
			local client = createClientEndpoint(action)
			local server = createServerEndpoint(action, { subscribedActors = { ACTOR_A } })

			client.action.dispatch({ amount = 1 })
			client.action.dispatch({ amount = 2 })
			server.runtime.receive(ACTOR_A, client.envelopes[1])
			server.runtime.receive(ACTOR_A, client.envelopes[2])
			server.sync.flush()

			TestRunner.expectEqual(#server.outgoing, 1)
			TestRunner.expectDeepEqual(server.outgoing[1].payload, {
				charmUpdates = {
					{ type = "patch", data = { counter = 1 } },
					{ type = "patch", data = { counter = 3 } },
				},
				processedSequence = 2,
			})

			client.sync.apply(server.outgoing[1].payload)
			TestRunner.expectEqual(client.runtime.getPendingCount(), 0)
			TestRunner.expectEqual(client.runtime.getPredictedState().counter, 3)
			server.sync.destroy()
		end,
	},
	{
		name = "an action whose reducer throws is still acknowledged",
		run = function()
			local server = createServerEndpoint(defineCounterAction(), { subscribedActors = { ACTOR_A } })

			TestRunner.expectWarning(function()
				server.runtime.receive(ACTOR_A, envelope(1, FAILING_AMOUNT))
			end, 'Reducer for action "AdjustCounter" failed')
			server.sync.flush()

			TestRunner.expectEqual(#server.outgoing, 1)
			TestRunner.expectDeepEqual(server.outgoing[1].payload, acknowledgementOnly(1))
			TestRunner.expectEqual(server.getState().counter, 0)
			server.sync.destroy()
		end,
	},
	{
		name = "an action whose publish throws is still acknowledged and the next sequence is expected",
		run = function()
			local server = createServerEndpoint(defineCounterAction(), {
				subscribedActors = { ACTOR_A },
				failPublishAmount = 5,
			})

			TestRunner.expectError(function()
				server.runtime.receive(ACTOR_A, envelope(1, 5))
			end, "publish failed on purpose")
			server.sync.flush()
			TestRunner.expectEqual(#server.outgoing, 1)
			TestRunner.expectDeepEqual(server.outgoing[1].payload, acknowledgementOnly(1))

			server.runtime.receive(ACTOR_A, envelope(2, 1))
			server.sync.flush()
			TestRunner.expectEqual(#server.outgoing, 2)
			TestRunner.expectEqual(server.outgoing[2].payload.processedSequence, 2)
			TestRunner.expectEqual(server.getState().counter, 1)
			server.sync.destroy()
		end,
	},
	{
		name = "removeActor drops a waiting acknowledgement and the actor's sequence",
		run = function()
			local server = createServerEndpoint(defineCounterAction(), { subscribedActors = {} })

			server.runtime.receive(ACTOR_A, envelope(1, 1))
			server.runtime.removeActor(ACTOR_A)
			server.sync.flush()
			TestRunner.expectEqual(#server.outgoing, 0)

			-- An actor under the same key starts again at sequence 1.
			server.runtime.receive(ACTOR_A, envelope(1, 1))
			server.sync.flush()
			TestRunner.expectEqual(#server.outgoing, 1)
			TestRunner.expectDeepEqual(server.outgoing[1].payload, acknowledgementOnly(1))
			TestRunner.expectEqual(server.getState().counter, 2)
			server.sync.destroy()
		end,
	},
	{
		name = "watermarks remain isolated when one patch is fanned out to two actors",
		run = function()
			local action = defineCounterAction()
			local clientA = createClientEndpoint(action)
			local clientB = createClientEndpoint(action)
			local server = createServerEndpoint(action, { subscribedActors = { ACTOR_A, ACTOR_B } })

			clientA.action.dispatch({ amount = 1 })
			clientB.action.dispatch({ amount = 1 })
			server.runtime.receive(ACTOR_A, clientA.envelopes[1])
			server.sync.flush()
			TestRunner.expectEqual(#server.outgoing, 2)
			TestRunner.expectEqual(server.outgoing[1].actor, ACTOR_A)
			TestRunner.expectEqual(server.outgoing[1].payload.processedSequence, 1)
			TestRunner.expectEqual(server.outgoing[2].actor, ACTOR_B)
			TestRunner.expectEqual(server.outgoing[2].payload.processedSequence, nil)

			table.clear(server.outgoing)
			server.runtime.receive(ACTOR_B, clientB.envelopes[1])
			server.sync.flush()
			TestRunner.expectEqual(#server.outgoing, 2)
			TestRunner.expectEqual(server.outgoing[1].actor, ACTOR_A)
			TestRunner.expectEqual(server.outgoing[1].payload.processedSequence, nil)
			TestRunner.expectEqual(server.outgoing[2].actor, ACTOR_B)
			TestRunner.expectEqual(server.outgoing[2].payload.processedSequence, 1)
			TestRunner.expectEqual(server.getState().counter, 2)
			server.sync.destroy()
		end,
	},
	{
		name = "mixed history reconciles predicted keys and preserves regular update order",
		run = function()
			local client = createClientEndpoint(defineCounterAction())
			local payload: any = {
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
		name = "a predicted signal synced under another key writes its state key",
		run = function()
			local client = createClientEndpoint(defineCounterAction(), { counter = "syncedCounter" })
			TestRunner.expectEqual(client.action.dispatch({ amount = 1 }), true)
			TestRunner.expectEqual(client.action.dispatch({ amount = 1 }), true)

			-- Only the sync key is predicted: a regular signal synced as "counter" passes through untouched.
			local regularUpdates = client.sync.apply({
				charmUpdates = {
					{ type = "patch", data = { syncedCounter = 1, counter = "regular" } },
				},
				processedSequence = 1,
			} :: any)
			TestRunner.expectDeepEqual(regularUpdates, {
				{ type = "patch", data = { counter = "regular" } },
			})
			TestRunner.expectDeepEqual(client.charm.getPatchCalls(), {
				{
					{ type = "patch", data = { syncedCounter = 1 } },
				},
			})
			TestRunner.expectEqual(client.runtime.getAuthoritativeState().counter, 1)
			TestRunner.expectEqual(client.runtime.getAuthoritativeState().syncedCounter, nil)
			TestRunner.expectEqual(client.runtime.getPredictedState().counter, 2)
			TestRunner.expectEqual(client.runtime.getPendingCount(), 1)
		end,
	},
	{
		name = "client adapter refuses a predicted map it cannot honour",
		run = function()
			local action = defineCounterAction()
			TestRunner.expectError(function()
				createClientEndpoint(action, {})
			end, "predictedSignals must not be empty")
			TestRunner.expectError(function()
				createClientEndpoint(action, { missing = "missing" })
			end, 'Predicted state "missing" is missing from prediction state')
			TestRunner.expectError(function()
				createClientEndpoint(action, { counter = "" })
			end, "must be a non-empty string")
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
}

return cases
