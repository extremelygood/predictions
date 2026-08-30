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
	local runtime = Prediction.server({
		getState = function(): State
			return state
		end,
		publish = function(nextState: State)
			state = nextState
		end,
		now = function(): number
			return 200
		end,
		replication = {
			_commit = function(_actor: string, _sequence: number, apply: () -> ())
				apply()
			end,
		},
	})

	runtime.register(defineCounterAction())

	return {
		runtime = runtime,
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
