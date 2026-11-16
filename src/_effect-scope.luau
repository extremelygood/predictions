--!strict

local Types = require(script.Parent._types)

-- The effects of a reducer that emitted none, shared.
local NO_EFFECTS: Types.EffectCollector = table.freeze({}) :: any

-- How many reducers are running, one inside another; each depth's effects, made at its first emission.
local depth = 0
local collectors: { [number]: Types.EffectCollector } = {}

local function emit(effectName: string, deliverEffect: (payload: any) -> (), payload: any)
	if depth == 0 then
		error(`[Predictions] Effect "{effectName}" can only be emitted inside a reducer`, 2)
	end

	local collector = collectors[depth]
	if collector == nil then
		collector = {}
		collectors[depth] = collector
	end
	table.insert(collector, {
		deliver = deliverEffect,
		payload = payload,
	})
end

local function onFailure(message: any): string
	return debug.traceback(tostring(message), 2)
end

-- Runs `reduce(state, payload, context)`, collecting the effects it emits. Returns whether it succeeded, its result
-- (the traceback when it threw) and its effects, NO_EFFECTS when it emitted none.
local function collect(reduce: (any, any, any) -> any, state: any, payload: any, context: any): (boolean, any, Types.EffectCollector)
	depth += 1
	collectors[depth] = nil
	local succeeded, result = xpcall(reduce, onFailure, state, payload, context)
	local collector = collectors[depth]
	collectors[depth] = nil
	depth -= 1
	return succeeded, result, collector or NO_EFFECTS
end

local function deliver(collector: Types.EffectCollector)
	for _, emission in collector do
		emission.deliver(emission.payload)
	end
end

return {
	NO_EFFECTS = NO_EFFECTS,
	emit = emit,
	collect = collect,
	deliver = deliver,
}
