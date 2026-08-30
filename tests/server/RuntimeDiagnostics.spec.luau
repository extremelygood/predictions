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
}

return cases
