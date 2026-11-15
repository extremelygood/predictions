--!strict

local Types = require(script.Parent.Parent["_charm-sync-adapter-types"])

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
	-- Per actor, the highest handled sequence that has not been sent to him yet.
	local acknowledged: { [any]: number } = {}

	-- Charm Sync calls this only inside `flush` below.
	local function handleSync(actor: Actor, updates: Types.CharmSyncUpdates)
		if not started then
			return
		end

		local sequence = acknowledged[actor]
		acknowledged[actor] = nil
		send(actor, {
			charmUpdates = updates,
			processedSequence = sequence,
		})
	end

	local function start()
		if started then
			return
		end

		started = true
		-- Disconnecting stops only Charm Sync's own interval and keeps the callback, so `flush` is the only sync.
		charmServer.connect(handleSync)
		charmServer.disconnect()
	end

	local function destroy()
		if not started then
			return
		end

		started = false
		acknowledged = {}
	end

	local function flush()
		if not started then
			return
		end

		charmServer.flush()

		-- The acknowledgements no payload carried go alone. Each send runs on its own, as Charm Sync's do, so one
		-- that fails keeps nothing from the other actors.
		local rest = acknowledged
		acknowledged = {}
		for actor, sequence in rest do
			task.spawn(send, actor, {
				charmUpdates = {},
				processedSequence = sequence,
			})
		end
	end

	local function acknowledge(actor: Actor, sequence: number)
		assert(started, "[Predictions.CharmSync] Server adapter must be started before processing actions")
		acknowledged[actor] = sequence
	end

	local function forget(actor: Actor)
		acknowledged[actor] = nil
	end

	return {
		_acknowledge = acknowledge,
		_forget = forget,
		start = start,
		destroy = destroy,
		flush = flush,
	}
end

return createServer
