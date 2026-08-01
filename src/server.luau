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
	local succeeded, failure = xpcall(function()
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
	local succeeded, failure = xpcall(function()
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
	assert(type(config.replication._commit) == "function", "[Predictions] Server replication must define _commit")

	local getState = config.getState
	local publish = config.publish
	local now = config.now
	local commit = config.replication._commit
	local registry: Types.ServerActionRegistry<State, Actor> = {}
	local processedSequences: { [any]: Types.Sequence } = {}

	local function register<Payload>(
		definition: Types.ActionDefinition<State, Payload>,
		options: Types.ServerActionOptions<Actor, Payload>?
	): Types.BoundAction<Payload>
		Action.assertDefinition(definition)
		assert(registry[definition.id] == nil, `[Predictions] Action id "{definition.id}" is already registered`)
		assert(options == nil or type(options) == "table", `[Predictions] Options for action "{definition.id}" must be a table`)
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
			assert(isFiniteNumber(actionTime), `[Predictions] Clock returned an invalid timestamp for action "{definition.id}"`)

			local state = getState()
			local accepted, nextState, effects = runReducer(definition, state, payload, {
				actionTime = actionTime,
			})
			if not accepted then
				return false
			end

			publish(nextState :: State)
			EffectScope.deliver(effects)
			return true
		end

		return table.freeze({
			dispatch = dispatch,
		})
	end

	local function commitRejection(actor: Actor, sequence: Types.Sequence)
		commit(actor, sequence, function()
			processedSequences[actor] = sequence
		end)
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
		if sequence ~= expectedSequence then
			return
		end

		local actionId = rawEnvelope.actionId
		local actionTime = rawEnvelope.actionTime
		if type(actionId) ~= "string" or actionId == "" or not isFiniteNumber(actionTime) then
			commitRejection(actor, sequence)
			return
		end

		local registered = registry[actionId]
		if registered == nil then
			commitRejection(actor, sequence)
			return
		end

		local payload = rawEnvelope.payload
		if not validatePayload(registered.definition, payload) then
			commitRejection(actor, sequence)
			return
		end

		if registered.acceptClient ~= nil and not authorize(actionId, registered.acceptClient, actor, payload) then
			commitRejection(actor, sequence)
			return
		end

		local state = getState()
		local accepted, nextState, effects = runReducer(registered.definition, state, payload, {
			actionTime = actionTime,
		})
		if not accepted then
			commitRejection(actor, sequence)
			return
		end

		commit(actor, sequence, function()
			publish(nextState :: State)
			processedSequences[actor] = sequence
			EffectScope.deliver(effects)
		end)
	end

	return table.freeze({
		register = register,
		receive = receive,
	})
end

return createServer
