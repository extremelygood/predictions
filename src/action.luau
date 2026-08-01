--!strict

local Types = require(script.Parent._types)

local function assertDefinition(definition: any)
	assert(type(definition) == "table", "[Predictions] Action definition must be a table")
	assert(type(definition.id) == "string" and definition.id ~= "", "[Predictions] Action id must be a non-empty string")
	assert(type(definition.validate) == "function", `[Predictions] Action "{definition.id}" must define validate`)
	assert(type(definition.reduce) == "function", `[Predictions] Action "{definition.id}" must define reduce`)
end

local function defineAction<State, Payload>(
	config: Types.ActionConfig<State, Payload>
): Types.ActionDefinition<State, Payload>
	assertDefinition(config)

	return table.freeze({
		id = config.id,
		validate = config.validate,
		reduce = config.reduce,
	}) :: Types.ActionDefinition<State, Payload>
end

return {
	define = defineAction,
	assertDefinition = assertDefinition,
}
