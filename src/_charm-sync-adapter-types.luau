--!strict

-- Structural contracts for the optional Charm Sync 0.4 adapter. The adapter
-- accepts Charm Sync through configuration so the prediction core never imports
-- the package and consumers only install it when they use the integration.

local CoreTypes = require(script.Parent._types)

export type CharmSyncData = { [string]: any }

export type CharmSyncUpdate =
	{
		type: "init",
		data: CharmSyncData,
	}
	| {
		type: "patch",
		data: CharmSyncData,
	}

export type CharmSyncUpdates = { CharmSyncUpdate }

export type ReconciliationPayload = {
	charmUpdates: CharmSyncUpdates,
	processedSequence: CoreTypes.Sequence?,
}

export type CharmSyncSetter = (valueOrUpdater: any) -> any

export type CharmSyncClientApi = {
	addSignals: (signals: { [string]: CharmSyncSetter }) -> (),
	patch: (updates: CharmSyncUpdates) -> (),
}

export type CharmSyncServerApi<Actor> = {
	connect: (callback: (actor: Actor, updates: CharmSyncUpdates) -> ()) -> (),
	disconnect: () -> (),
	flush: () -> (),
}

export type CharmSyncClientLibrary = {
	client: CharmSyncClientApi,
}

export type CharmSyncServerLibrary<Actor> = {
	server: CharmSyncServerApi<Actor>,
}

export type CharmSyncClientConfig<State> = {
	runtime: CoreTypes.ClientRuntime<State>,
	charmSync: CharmSyncClientLibrary,
	predictedSignals: { string },
}

export type CharmSyncClient = {
	apply: (payload: ReconciliationPayload) -> CharmSyncUpdates,
}

export type CharmSyncServerConfig<Actor> = {
	charmSync: CharmSyncServerLibrary<Actor>,
	send: (actor: Actor, payload: ReconciliationPayload) -> (),
}

export type CharmSyncServer<Actor> = CoreTypes.ServerReplication<Actor> & {
	start: () -> (),
	destroy: () -> (),
}

export type PredictionCharmSyncLibrary = {
	client: <State>(config: CharmSyncClientConfig<State>) -> CharmSyncClient,
	server: <Actor>(config: CharmSyncServerConfig<Actor>) -> CharmSyncServer<Actor>,
}

return {}
