--!strict

local Types = require(script.Parent.Parent["_charm-sync-adapter-types"])

local function isNonNegativeInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
		and value >= 0
		and value % 1 == 0
end

local function assertDenseArray(array: { [any]: any }, label: string)
	local count = 0
	for key in array do
		assert(type(key) == "number" and key >= 1 and key % 1 == 0, `[Predictions.CharmSync] {label} must be an array`)
		count += 1
	end
	assert(count == #array, `[Predictions.CharmSync] {label} must be a dense array`)
end

local function splitUpdates(
	updates: Types.CharmSyncUpdates,
	predictedSignalSet: { [string]: boolean }
): (Types.CharmSyncUpdates, Types.CharmSyncUpdates)
	assert(type(updates) == "table", "[Predictions.CharmSync] charmUpdates must be an array")
	assertDenseArray(updates :: any, "charmUpdates")

	local predictedUpdates: Types.CharmSyncUpdates = {}
	local regularUpdates: Types.CharmSyncUpdates = {}

	for index, update in updates do
		assert(type(update) == "table", `[Predictions.CharmSync] charmUpdates[{index}] must be a table`)
		assert(
			update.type == "init" or update.type == "patch",
			`[Predictions.CharmSync] charmUpdates[{index}].type must be "init" or "patch"`
		)
		assert(type(update.data) == "table", `[Predictions.CharmSync] charmUpdates[{index}].data must be a table`)

		local predictedData: Types.CharmSyncData = {}
		local regularData: Types.CharmSyncData = {}
		local hasPredictedData = false
		local hasRegularData = false

		for key, value in update.data do
			assert(type(key) == "string", `[Predictions.CharmSync] charmUpdates[{index}].data keys must be strings`)
			if predictedSignalSet[key] then
				predictedData[key] = value
				hasPredictedData = true
			else
				regularData[key] = value
				hasRegularData = true
			end
		end

		if hasPredictedData then
			table.insert(
				predictedUpdates,
				{
					type = update.type,
					data = predictedData,
				} :: any
			)
		end

		if hasRegularData then
			if hasPredictedData then
				table.insert(
					regularUpdates,
					{
						type = update.type,
						data = regularData,
					} :: any
				)
			else
				table.insert(regularUpdates, update)
			end
		end
	end

	return predictedUpdates, regularUpdates
end

local function createClient<State>(config: Types.CharmSyncClientConfig<State>): Types.CharmSyncClient
	assert(type(config) == "table", "[Predictions.CharmSync] Client config must be a table")
	assert(type(config.runtime) == "table", "[Predictions.CharmSync] Client config must define runtime")
	assert(
		type(config.runtime.getAuthoritativeState) == "function" and type(config.runtime.reconcile) == "function",
		"[Predictions.CharmSync] Client runtime is missing required functions"
	)
	assert(type(config.charmSync) == "table", "[Predictions.CharmSync] Client config must define charmSync")
	assert(type(config.charmSync.client) == "table", "[Predictions.CharmSync] charmSync must define client")
	assert(
		type(config.charmSync.client.addSignals) == "function" and type(config.charmSync.client.patch) == "function",
		"[Predictions.CharmSync] charmSync.client is missing required Charm Sync 0.4 functions"
	)
	assert(type(config.predictedSignals) == "table", "[Predictions.CharmSync] predictedSignals must be an array")
	assertDenseArray(config.predictedSignals :: any, "predictedSignals")
	assert(#config.predictedSignals > 0, "[Predictions.CharmSync] predictedSignals must not be empty")

	local runtime = config.runtime
	local charmClient = config.charmSync.client
	local authoritativeState: any = runtime.getAuthoritativeState()
	assert(type(authoritativeState) == "table", "[Predictions.CharmSync] Prediction state must be a top-level table")

	local predictedSignalSet: { [string]: boolean } = {}
	local setters: { [string]: Types.CharmSyncSetter } = {}

	local function createSetter(key: string): Types.CharmSyncSetter
		return function(valueOrUpdater: any): any
			local previousValue = authoritativeState[key]
			local nextValue = if type(valueOrUpdater) == "function"
				then (valueOrUpdater :: any)(previousValue)
				else valueOrUpdater
			local nextState = table.clone(authoritativeState)
			nextState[key] = nextValue
			authoritativeState = nextState
			return nextValue
		end
	end

	for _, key in config.predictedSignals do
		assert(
			type(key) == "string" and key ~= "",
			"[Predictions.CharmSync] Predicted signal names must be non-empty strings"
		)
		assert(not predictedSignalSet[key], `[Predictions.CharmSync] Predicted signal "{key}" is duplicated`)
		assert(
			rawget(authoritativeState, key) ~= nil,
			`[Predictions.CharmSync] Predicted signal "{key}" is missing from prediction state`
		)
		predictedSignalSet[key] = true
		setters[key] = createSetter(key)
	end

	charmClient.addSignals(setters)

	local lastProcessedSequence = 0

	local function apply(payload: Types.ReconciliationPayload): Types.CharmSyncUpdates
		assert(type(payload) == "table", "[Predictions.CharmSync] Reconciliation payload must be a table")

		local processedSequence = payload.processedSequence
		if processedSequence ~= nil then
			assert(
				isNonNegativeInteger(processedSequence),
				"[Predictions.CharmSync] processedSequence must be a non-negative integer"
			)
			assert(
				processedSequence >= lastProcessedSequence,
				"[Predictions.CharmSync] processedSequence must not move backwards"
			)
		end

		local predictedUpdates, regularUpdates = splitUpdates(payload.charmUpdates, predictedSignalSet)

		if #predictedUpdates > 0 then
			charmClient.patch(predictedUpdates)
		end

		if processedSequence ~= nil then
			lastProcessedSequence = processedSequence
		end

		if #predictedUpdates > 0 or processedSequence ~= nil then
			runtime.reconcile(authoritativeState :: State, lastProcessedSequence)
		end

		return regularUpdates
	end

	return {
		apply = apply,
	}
end

return createClient
