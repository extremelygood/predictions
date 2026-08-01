--!strict

-- Contracts for the optional Charm Sync adapter. Keeping these separate ensures
-- the prediction core has no dependency on Charm Sync-specific concepts.

local Types = require(script.Parent._types)

-- Charm Sync updates are generic because their concrete representation belongs
-- to Charm Sync, not to the prediction core.
export type ReconciliationPayload<CharmUpdates> = {
	charmUpdates: CharmUpdates,
	processedSequence: Types.Sequence?,
}

export type CharmSyncClientConfig<State, CharmSync> = {
	runtime: Types.ClientRuntime<State>,
	charmSync: CharmSync,
	predictedSignals: { string },
}

export type CharmSyncClient = {
	apply: <CharmUpdates>(payload: ReconciliationPayload<CharmUpdates>) -> CharmUpdates,
}

export type CharmSyncServerConfig<Actor, CharmSync, CharmUpdates> = {
	charmSync: CharmSync,
	send: (actor: Actor, payload: ReconciliationPayload<CharmUpdates>) -> (),
}

export type CharmSyncServer<Actor> = Types.ServerReplication<Actor> & {
	start: () -> (),
	destroy: () -> (),
}

export type PredictionCharmSyncLibrary = {
	client: <State, CharmSync>(config: CharmSyncClientConfig<State, CharmSync>) -> CharmSyncClient,
	server: <Actor, CharmSync, CharmUpdates>(
		config: CharmSyncServerConfig<Actor, CharmSync, CharmUpdates>
	) -> CharmSyncServer<Actor>,
}

return {}
