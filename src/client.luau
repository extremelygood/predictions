--!strict

local Action = require(script.Parent.action)
local EffectScope = require(script.Parent["_effect-scope"])
local Types = require(script.Parent._types)

local function traceback(message: any): string
	return debug.traceback(tostring(message), 2)
end

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function validatePayload<Payload>(definition: Types.ActionDefinition<any, Payload>, payload: Payload): boolean
	local accepted = false
	local succeeded, failure = (xpcall :: any)(function()
		accepted = definition.validate(payload) == true
	end, traceback)

	if not succeeded then
		warn(`[Predictions] Validator for action "{definition.id}" failed:\n{failure}`)
		return false
	end

	return accepted
end

local function runReducer<State, Payload>(
	definition: Types.ActionDefinition<State, Payload>,
	state: State,
	payload: Payload,
	context: Types.ActionContext
): (boolean, State?, Types.EffectCollector)
	local succeeded, nextState, effects, failure = EffectScope.collect(function()
		return definition.reduce(state, payload, context)
	end)

	if not succeeded then
		warn(`[Predictions] Reducer for action "{definition.id}" failed:\n{failure}`)
		return false, nil, effects
	end

	return nextState ~= nil, nextState, effects
end

local function createClient<State>(config: Types.ClientConfig<State>): Types.ClientRuntime<State>
	assert(type(config) == "table", "[Predictions] Client config must be a table")
	assert(type(config.publish) == "function", "[Predictions] Client config must define publish")
	assert(type(config.send) == "function", "[Predictions] Client config must define send")
	assert(type(config.now) == "function", "[Predictions] Client config must define now")

	local publish = config.publish
	local send = config.send
	local now = config.now
	local authoritativeState = config.initialState
	local predictedState = config.initialState
	local nextSequence: Types.Sequence = 1
	local pendingActions: { Types.PendingAction<State> } = {}
	local registry: Types.ClientActionRegistry<State> = {}

	local function register<Payload>(definition: Types.ActionDefinition<State, Payload>): Types.BoundAction<Payload>
		Action.assertDefinition(definition)
		assert(registry[definition.id] == nil, `[Predictions] Action id "{definition.id}" is already registered`)
		registry[definition.id] = definition :: Types.ActionDefinition<State, any>

		local function dispatch(payload: Payload): boolean
			if not validatePayload(definition, payload) then
				return false
			end

			local actionTime = now()
			assert(
				isFiniteNumber(actionTime),
				`[Predictions] Clock returned an invalid timestamp for action "{definition.id}"`
			)

			local envelope: Types.ActionEnvelope<Payload> = {
				actionId = definition.id,
				payload = payload,
				sequence = nextSequence,
				actionTime = actionTime,
			}
			local accepted, nextState, effects = runReducer(definition, predictedState, payload, {
				actionTime = actionTime,
			})

			if not accepted then
				return false
			end

			nextSequence += 1
			table.insert(pendingActions, {
				definition = definition :: Types.ActionDefinition<State, any>,
				envelope = envelope,
			})
			predictedState = nextState :: State
			publish(predictedState)
			EffectScope.deliver(effects)
			send(envelope)

			return true
		end

		return {
			dispatch = dispatch,
		}
	end

	local function reconcile(nextAuthoritativeState: State, processedSequence: Types.Sequence)
		assert(
			isFiniteNumber(processedSequence) and processedSequence >= 0 and processedSequence % 1 == 0,
			"[Predictions] Processed sequence must be a non-negative integer"
		)

		authoritativeState = nextAuthoritativeState

		local remaining: { Types.PendingAction<State> } = {}
		for _, pending in pendingActions do
			if pending.envelope.sequence > processedSequence then
				table.insert(remaining, pending)
			end
		end
		pendingActions = remaining

		local replayedState = authoritativeState
		for _, pending in pendingActions do
			local accepted, nextState = runReducer(pending.definition, replayedState, pending.envelope.payload, {
				actionTime = pending.envelope.actionTime,
			})
			if accepted then
				replayedState = nextState :: State
			end
		end

		predictedState = replayedState
		publish(predictedState)
	end

	local function getAuthoritativeState(): State
		return authoritativeState
	end

	local function getPredictedState(): State
		return predictedState
	end

	local function getPendingCount(): number
		return #pendingActions
	end

	return {
		register = register,
		reconcile = reconcile,
		getAuthoritativeState = getAuthoritativeState,
		getPredictedState = getPredictedState,
		getPendingCount = getPendingCount,
	}
end

return createClient
