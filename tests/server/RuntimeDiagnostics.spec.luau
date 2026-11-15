--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Prediction = require(ReplicatedStorage.Packages.Predictions)
local TestRunner = require(script.Parent.TestRunner)

type State = {
	counter: number,
}

type Payload = {
	amount: number,
}

type Client = {
	runtime: any,
	action: any,
	envelopes: { any },
}

local ACTOR = "actor"

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

local function createServer()
	local state: State = {
		counter = 0,
	}
	local acknowledgements: { number } = {}
	local statePayloads: { any } = {}
	local runtime = Prediction.server({
		getState = function(payload: unknown): State
			table.insert(statePayloads, payload)
			return state
		end,
		publish = function(before: State, after: State)
			assert(before == state, "publish was not given the table getState returned")
			state = after
		end,
		now = function(): number
			return 200
		end,
		replication = {
			_acknowledge = function(_actor: string, sequence: number)
				table.insert(acknowledgements, sequence)
			end,
			_forget = function(_actor: string) end,
		},
	})

	local action = runtime.register(defineCounterAction())

	return {
		runtime = runtime,
		action = action,
		acknowledgements = acknowledgements,
		statePayloads = statePayloads,
		getState = function(): State
			return state
		end,
	}
end

local function createClientRuntime(): Client
	local envelopes: { any } = {}
	local runtime = Prediction.client({
		initialState = {
			counter = 0,
		},
		publish = function(_state: State)
		end,
		send = function(envelope: any)
			table.insert(envelopes, envelope)
		end,
		now = function(): number
			return 100
		end,
	})

	return {
		runtime = runtime,
		action = runtime.register(defineCounterAction()),
		envelopes = envelopes,
	}
end

local cases: { TestRunner.TestCase } = {
	{
		name = "server warns for future and stale client sequences",
		run = function()
			local server = createServer()

			TestRunner.expectWarning(function()
				server.runtime.receive(ACTOR, {
					actionId = "AdjustCounter",
					payload = { amount = 1 },
					sequence = 2,
					actionTime = 100,
				})
			end, "out-of-order action sequence 2")
			TestRunner.expectEqual(server.getState().counter, 0)

			server.runtime.receive(ACTOR, {
				actionId = "AdjustCounter",
				payload = { amount = 1 },
				sequence = 1,
				actionTime = 100,
			})
			TestRunner.expectEqual(server.getState().counter, 1)

			TestRunner.expectWarning(function()
				server.runtime.receive(ACTOR, {
					actionId = "AdjustCounter",
					payload = { amount = 1 },
					sequence = 1,
					actionTime = 100,
				})
			end, "stale or duplicate action sequence 1")
			TestRunner.expectDeepEqual(server.acknowledgements, { 1 })
		end,
	},
	{
		name = "server warns for unregistered actions while advancing the sequence",
		run = function()
			local server = createServer()

			TestRunner.expectWarning(function()
				server.runtime.receive(ACTOR, {
					actionId = "MissingAction",
					payload = {},
					sequence = 1,
					actionTime = 100,
				})
			end, 'unregistered action "MissingAction"')

			server.runtime.receive(ACTOR, {
				actionId = "AdjustCounter",
				payload = { amount = 1 },
				sequence = 2,
				actionTime = 100,
			})
			TestRunner.expectEqual(server.getState().counter, 1)
			TestRunner.expectDeepEqual(server.acknowledgements, { 1, 2 })
		end,
	},
	{
		name = "server works an action out on the state getState gives for its payload",
		run = function()
			local server = createServer()
			local payload = { amount = 2 }

			server.runtime.receive(ACTOR, {
				actionId = "AdjustCounter",
				payload = payload,
				sequence = 1,
				actionTime = 100,
			})
			TestRunner.expectEqual(server.statePayloads[1], payload)
			TestRunner.expectEqual(server.getState().counter, 2)

			-- A direct dispatch goes the same way and acknowledges nothing.
			TestRunner.expectEqual(server.action.dispatch({ amount = 3 }), true)
			TestRunner.expectEqual(#server.statePayloads, 2)
			TestRunner.expectEqual(server.getState().counter, 5)
			TestRunner.expectDeepEqual(server.acknowledgements, { 1 })

			-- A payload that fails validate never reaches getState, and its sequence is still acknowledged.
			server.runtime.receive(ACTOR, {
				actionId = "AdjustCounter",
				payload = { amount = "many" },
				sequence = 2,
				actionTime = 100,
			} :: any)
			TestRunner.expectEqual(#server.statePayloads, 2)
			TestRunner.expectDeepEqual(server.acknowledgements, { 1, 2 })
		end,
	},
	{
		name = "client rejects a processed sequence above locally dispatched actions",
		run = function()
			local client = createClientRuntime()
			TestRunner.expectEqual(client.action.dispatch({ amount = 1 }), true)

			TestRunner.expectError(function()
				client.runtime.reconcile({ counter = 99 }, 2)
			end, "exceeds highest dispatched sequence 1")

			TestRunner.expectEqual(client.runtime.getAuthoritativeState().counter, 0)
			TestRunner.expectEqual(client.runtime.getPredictedState().counter, 1)
			TestRunner.expectEqual(client.runtime.getPendingCount(), 1)
		end,
	},
	{
		name = "client rejects a regressing processed sequence",
		run = function()
			local client = createClientRuntime()
			TestRunner.expectEqual(client.action.dispatch({ amount = 1 }), true)
			client.runtime.reconcile({ counter = 1 }, 1)

			TestRunner.expectError(function()
				client.runtime.reconcile({ counter = 99 }, 0)
			end, "must not move backwards")

			TestRunner.expectEqual(client.runtime.getAuthoritativeState().counter, 1)
			TestRunner.expectEqual(client.runtime.getPredictedState().counter, 1)
			TestRunner.expectEqual(client.runtime.getPendingCount(), 0)
		end,
	},
}

return cases
