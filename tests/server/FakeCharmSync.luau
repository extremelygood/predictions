--!strict

type Update = {
	type: "init" | "patch",
	data: { [string]: any },
}

type Delivery = {
	actor: any,
	updates: { Update },
}

local function new()
	local setters: { [string]: (any) -> any } = {}
	local patchCalls: { { Update } } = {}
	local deliveries: { Delivery } = {}
	local syncCallback: ((any, { Update }) -> ())? = nil
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
			end,
			disconnect = function()
				disconnectCount += 1
				syncCallback = nil
			end,
			flush = function()
				flushCount += 1
				local callback = syncCallback
				assert(callback ~= nil, "Fake Charm Sync server is not connected")

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
			table.insert(deliveries, {
				actor = actor,
				updates = updates,
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
	}
end

return {
	new = new,
}
