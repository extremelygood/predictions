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

local function authorize<Actor>(
	actionId: string,
	callback: (actor: Actor, payload: any) -> boolean,
	actor: Actor,
	payload: any
): boolean
	local accepted = false
	local succeeded, failure = (xpcall :: any)(function()
		accepted = callback(actor, payload) == true
	end, traceback)

	if not succeeded then
		warn(`[Predictions] Authorization for action "{actionId}" failed:\n{failure}`)
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

local function createServer<State, Actor>(config: Types.ServerConfig<State, Actor>): Types.ServerRuntime<State, Actor>
	assert(type(config) == "table", "[Predictions] Server config must be a table")
	assert(type(config.getState) == "function", "[Predictions] Server config must define getState")
	assert(type(config.publish) == "function", "[Predictions] Server config must define publish")
	assert(type(config.now) == "function", "[Predictions] Server config must define now")
	assert(type(config.replication) == "table", "[Predictions] Server config must define replication")
	assert(
		type(config.replication._acknowledge) == "function",
		"[Predictions] Server replication must define _acknowledge"
	)
	assert(type(config.replication._forget) == "function", "[Predictions] Server replication must define _forget")

	local getState = config.getState
	local publish = config.publish
	local now = config.now
	local acknowledge = config.replication._acknowledge
	local forget = config.replication._forget
	local registry: Types.ServerActionRegistry<State, Actor> = {}
	local processedSequences: { [any]: Types.Sequence } = {}

	-- Works `payload` out on the state `getState` gives for it and publishes the result.
	-- `payload` has passed the action's `validate`.
	local function reduceAndPublish(
		definition: Types.ActionDefinition<State, any>,
		payload: any,
		actionTime: Types.Timestamp
	): boolean
		local before = getState(payload)
		local accepted, after, effects = runReducer(definition, before, payload, {
			actionTime = actionTime,
		})
		if not accepted then
			return false
		end

		publish(before, after :: State)
		EffectScope.deliver(effects)
		return true
	end

	local function register<Payload>(
		definition: Types.ActionDefinition<State, Payload>,
		options: Types.ServerActionOptions<Actor, Payload>?
	): Types.BoundAction<Payload>
		Action.assertDefinition(definition)
		assert(registry[definition.id] == nil, `[Predictions] Action id "{definition.id}" is already registered`)
		assert(
			options == nil or type(options) == "table",
			`[Predictions] Options for action "{definition.id}" must be a table`
		)
		assert(
			options == nil or options.acceptClient == nil or type(options.acceptClient) == "function",
			`[Predictions] acceptClient for action "{definition.id}" must be a function`
		)

		registry[definition.id] = {
			definition = definition :: Types.ActionDefinition<State, any>,
			acceptClient = if options == nil then nil else options.acceptClient,
		}

		local function dispatch(payload: Payload): boolean
			if not validatePayload(definition, payload) then
				return false
			end

			local actionTime = now()
			assert(
				isFiniteNumber(actionTime),
				`[Predictions] Clock returned an invalid timestamp for action "{definition.id}"`
			)

			return reduceAndPublish(definition :: Types.ActionDefinition<State, any>, payload, actionTime)
		end

		return {
			dispatch = dispatch,
		}
	end

	local function receive(actor: Actor, envelope: unknown)
		if type(envelope) ~= "table" then
			return
		end

		local rawEnvelope = envelope :: { [any]: any }
		local sequence = rawEnvelope.sequence
		if not isFiniteNumber(sequence) or sequence < 1 or sequence % 1 ~= 0 then
			return
		end

		local expectedSequence = (processedSequences[actor] or 0) + 1
		if sequence < expectedSequence then
			warn(
				`[Predictions] Received stale or duplicate action sequence {sequence} from {tostring(actor)}; expected {expectedSequence}. The action was ignored.`
			)
			return
		elseif sequence > expectedSequence then
			warn(
				`[Predictions] Received out-of-order action sequence {sequence} from {tostring(actor)}; expected {expectedSequence}. The action was ignored. Client action transport must be reliable and ordered.`
			)
			return
		end

		-- The expected sequence is handled from here on, whatever happens to the action: a rejection, a
		-- failing reducer or a throwing `publish` all leave it acknowledged. The acknowledgement only
		-- leaves with the next sync, after everything below has run.
		processedSequences[actor] = sequence
		acknowledge(actor, sequence)

		local actionId = rawEnvelope.actionId
		local actionTime = rawEnvelope.actionTime
		if type(actionId) ~= "string" or actionId == "" or not isFiniteNumber(actionTime) then
			return
		end

		local registered = registry[actionId]
		if registered == nil then
			warn(
				`[Predictions] Received unregistered action "{actionId}" from {tostring(actor)} at sequence {sequence}. The action was rejected.`
			)
			return
		end

		local payload = rawEnvelope.payload
		if not validatePayload(registered.definition, payload) then
			return
		end

		if registered.acceptClient ~= nil and not authorize(actionId, registered.acceptClient, actor, payload) then
			return
		end

		reduceAndPublish(registered.definition, payload, actionTime)
	end

	local function removeActor(actor: Actor)
		processedSequences[actor] = nil
		forget(actor)
	end

	return {
		register = register,
		receive = receive,
		removeActor = removeActor,
	}
end

return createServer
