--!strict

local Types = require(script.Parent._types)

local function assertDefinition(definition: any)
	assert(type(definition) == "table", "[Predictions] Action definition must be a table")
	assert(type(definition.id) == "string" and definition.id ~= "", "[Predictions] Action id must be a non-empty string")
	assert(type(definition.validate) == "function", `[Predictions] Action "{definition.id}" must define validate`)
	assert(
		definition.scope == nil or type(definition.scope) == "function",
		`[Predictions] Action "{definition.id}" scope must be a function`
	)
	assert(type(definition.reduce) == "function", `[Predictions] Action "{definition.id}" must define reduce`)
end

local function defineAction<State, Payload, Actor>(
	config: Types.ActionDefinition<State, Payload, Actor>
): Types.ActionDefinition<State, Payload, Actor>
	assertDefinition(config)

	return table.freeze({
		id = config.id,
		validate = config.validate,
		scope = config.scope,
		reduce = config.reduce,
	}) :: Types.ActionDefinition<State, Payload, Actor>
end

return {
	define = defineAction,
	assertDefinition = assertDefinition,
}
