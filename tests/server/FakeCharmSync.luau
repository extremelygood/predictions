--!strict

type Update = {
	type: "init" | "patch",
	data: { [string]: any },
}

type Delivery = {
	actor: any,
	updates: { Update },
}

-- Behaves like Charm Sync 0.4 where the adapter relies on it: `disconnect` stops only the interval and keeps the
-- callback, and `flush` calls the callback at most once per client with that client's updates in order.
local function new()
	local setters: { [string]: (any) -> any } = {}
	local patchCalls: { { Update } } = {}
	local deliveries: { Delivery } = {}
	local syncCallback: ((any, { Update }) -> ())? = nil
	local intervalRunning = false
	local connectCount = 0
	local disconnectCount = 0
	local flushCount = 0

	local library = {
		client = {
			addSignals = function(nextSetters: { [string]: (any) -> any })
				for key, setter in nextSetters do
					setters[key] = setter
				end
			end,
			patch = function(updates: { Update })
				table.insert(patchCalls, updates)
				for _, update in updates do
					for key, valueOrUpdater in update.data do
						local setter = setters[key]
						assert(setter ~= nil, `Fake Charm Sync has no setter for signal "{key}"`)
						setter(valueOrUpdater)
					end
				end
			end,
		},
		server = {
			connect = function(callback: (any, { Update }) -> ())
				connectCount += 1
				syncCallback = callback
				intervalRunning = true
			end,
			disconnect = function()
				disconnectCount += 1
				intervalRunning = false
			end,
			flush = function()
				flushCount += 1
				local callback = syncCallback
				if callback == nil then
					return
				end

				local queued = deliveries
				deliveries = {}
				for _, delivery in queued do
					callback(delivery.actor, delivery.updates)
				end
			end,
		},
	}

	return {
		library = library,
		queueDelivery = function(actor: any, updates: { Update })
			for _, delivery in deliveries do
				if delivery.actor == actor then
					table.move(updates, 1, #updates, #delivery.updates + 1, delivery.updates)
					return
				end
			end

			table.insert(deliveries, {
				actor = actor,
				updates = table.clone(updates),
			})
		end,
		getPatchCalls = function(): { { Update } }
			return patchCalls
		end,
		getConnectCount = function(): number
			return connectCount
		end,
		getDisconnectCount = function(): number
			return disconnectCount
		end,
		getFlushCount = function(): number
			return flushCount
		end,
		isIntervalRunning = function(): boolean
			return intervalRunning
		end,
	}
end

return {
	new = new,
}
