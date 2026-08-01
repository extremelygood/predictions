--!strict

local EffectScope = require(script.Parent["_effect-scope"])
local Types = require(script.Parent._types)

type ListenerEntry<Payload> = {
	listener: Types.EffectListener<Payload>,
}

local function defineEffect<Payload>(config: Types.EffectConfig): Types.Effect<Payload>
	assert(type(config) == "table", "[Predictions] Effect config must be a table")
	assert(type(config.name) == "string" and config.name ~= "", "[Predictions] Effect name must be a non-empty string")

	local name = config.name
	local listeners: { ListenerEntry<Payload> } = {}

	local function connect(listener: Types.EffectListener<Payload>): Types.EffectConnection
		assert(type(listener) == "function", `[Predictions] Effect "{name}" listener must be a function`)

		local connected = true
		local entry: ListenerEntry<Payload> = {
			listener = listener,
		}
		table.insert(listeners, entry)

		local function disconnect()
			if not connected then
				return
			end

			connected = false
			local index = table.find(listeners, entry)
			if index ~= nil then
				table.remove(listeners, index)
			end
		end

		return {
			disconnect = disconnect,
		}
	end

	local function deliver(payload: Payload)
		local snapshot: { Types.EffectListener<Payload> } = table.create(#listeners) :: any
		for _, entry in listeners do
			table.insert(snapshot, entry.listener)
		end

		for _, listener in snapshot do
			local failure: string? = nil
			local succeeded = xpcall(function()
				listener(payload)
			end, function(message)
				failure = debug.traceback(tostring(message), 2)
				return failure
			end)
			if not succeeded then
				warn(`[Predictions] Listener for effect "{name}" failed:\n{failure}`)
			end
		end
	end

	local function emit(payload: Payload)
		EffectScope.emit(name, deliver :: any, payload)
	end

	return {
		name = name,
		emit = emit,
		connect = connect,
	}
end

return {
	define = defineEffect,
}
