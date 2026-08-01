--!strict

local Types = require(script.Parent.Parent["_charm-sync-adapter-types"])

type PendingCommit = {
	sequence: number,
}

local function traceback(message: any): string
	return debug.traceback(tostring(message), 2)
end

local function isPositiveInteger(value: any): boolean
	return type(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
		and value >= 1
		and value % 1 == 0
end

local function createServer<Actor>(config: Types.CharmSyncServerConfig<Actor>): Types.CharmSyncServer<Actor>
	assert(type(config) == "table", "[Predictions.CharmSync] Server config must be a table")
	assert(type(config.charmSync) == "table", "[Predictions.CharmSync] Server config must define charmSync")
	assert(type(config.charmSync.server) == "table", "[Predictions.CharmSync] charmSync must define server")
	assert(
		type(config.charmSync.server.connect) == "function"
			and type(config.charmSync.server.disconnect) == "function"
			and type(config.charmSync.server.flush) == "function",
		"[Predictions.CharmSync] charmSync.server is missing required Charm Sync 0.4 functions"
	)
	assert(type(config.send) == "function", "[Predictions.CharmSync] Server config must define send")

	local charmServer = config.charmSync.server
	local send = config.send
	local started = false
	local pendingCommits: { [any]: PendingCommit } = {}

	local function handleSync(actor: Actor, updates: Types.CharmSyncUpdates)
		if not started then
			return
		end

		local pending = pendingCommits[actor]
		if pending ~= nil then
			pendingCommits[actor] = nil
		end

		send(actor, {
			charmUpdates = updates,
			processedSequence = if pending == nil then nil else pending.sequence,
		})
	end

	local function start()
		if started then
			return
		end

		charmServer.connect(handleSync)
		started = true
	end

	local function destroy()
		if not started then
			return
		end

		started = false
		table.clear(pendingCommits)
		charmServer.disconnect()
	end

	local function commit(actor: Actor, processedSequence: number, apply: () -> ())
		assert(started, "[Predictions.CharmSync] Server adapter must be started before processing actions")
		assert(actor ~= nil, "[Predictions.CharmSync] Commit actor must not be nil")
		assert(
			isPositiveInteger(processedSequence),
			"[Predictions.CharmSync] Commit sequence must be a positive integer"
		)
		assert(type(apply) == "function", "[Predictions.CharmSync] Commit apply callback must be a function")
		assert(pendingCommits[actor] == nil, "[Predictions.CharmSync] Overlapping commits for one actor are not supported")

		local pending: PendingCommit = {
			sequence = processedSequence,
		}
		pendingCommits[actor] = pending

		local applySucceeded, applyFailure = (xpcall :: any)(apply, traceback)
		if not applySucceeded then
			if pendingCommits[actor] == pending then
				pendingCommits[actor] = nil
			end
			error(applyFailure, 0)
		end

		local flushSucceeded, flushFailure = (xpcall :: any)(charmServer.flush, traceback)
		if not flushSucceeded then
			if pendingCommits[actor] == pending then
				pendingCommits[actor] = nil
			end
			error(flushFailure, 0)
		end

		if pendingCommits[actor] == pending then
			pendingCommits[actor] = nil
			send(actor, {
				charmUpdates = {},
				processedSequence = processedSequence,
			})
		end
	end

	return {
		_commit = commit,
		start = start,
		destroy = destroy,
	}
end

return createServer
