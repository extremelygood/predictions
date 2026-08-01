--!strict

local Types = require(script.Parent._types)

local scopes: { Types.EffectCollector } = {}

local function emit(effectName: string, deliverEffect: (payload: any) -> (), payload: any)
	local collector = scopes[#scopes]
	if collector == nil then
		error(`[Predictions] Effect "{effectName}" can only be emitted inside a reducer`, 2)
	end

	table.insert(collector, {
		deliver = deliverEffect,
		payload = payload,
	})
end

local function collect<State>(callback: () -> State?): (boolean, State?, Types.EffectCollector, string?)
	local collector: Types.EffectCollector = {}
	local result: State? = nil
	local failure: string? = nil

	table.insert(scopes, collector)
	local succeeded = xpcall(function()
		result = callback()
	end, function(message)
		failure = debug.traceback(tostring(message), 2)
		return failure
	end)
	table.remove(scopes)

	return succeeded, result, collector, failure
end

local function deliver(collector: Types.EffectCollector)
	for _, emission in collector do
		emission.deliver(emission.payload)
	end
end

return {
	emit = emit,
	collect = collect,
	deliver = deliver,
}
