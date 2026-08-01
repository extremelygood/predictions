--!strict

local Client = require(script.Parent.client)
local Server = require(script.Parent.server)
local Types = require(script.Parent.Parent["_charm-sync-adapter-types"])

export type CharmSyncData = Types.CharmSyncData
export type CharmSyncUpdate = Types.CharmSyncUpdate
export type CharmSyncUpdates = Types.CharmSyncUpdates
export type ReconciliationPayload = Types.ReconciliationPayload
export type CharmSyncClientApi = Types.CharmSyncClientApi
export type CharmSyncServerApi<Actor> = Types.CharmSyncServerApi<Actor>
export type CharmSyncClientLibrary = Types.CharmSyncClientLibrary
export type CharmSyncServerLibrary<Actor> = Types.CharmSyncServerLibrary<Actor>
export type CharmSyncClientConfig<State> = Types.CharmSyncClientConfig<State>
export type CharmSyncClient = Types.CharmSyncClient
export type CharmSyncServerConfig<Actor> = Types.CharmSyncServerConfig<Actor>
export type CharmSyncServer<Actor> = Types.CharmSyncServer<Actor>
export type PredictionCharmSyncLibrary = Types.PredictionCharmSyncLibrary

local PredictionCharmSync: Types.PredictionCharmSyncLibrary = {
	client = Client,
	server = Server,
}

return PredictionCharmSync
