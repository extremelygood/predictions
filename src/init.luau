--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local adapterMain = require(ReplicatedStorage.Packages.Predictions.charmSync.adapterMain)
local Action = require(script.action)
local Client = require(script.client)
local Effect = require(script.effect)
local Server = require(script.server)
local Types = require(script._types)

export type Sequence = Types.Sequence
export type Timestamp = Types.Timestamp
export type ActionContext = Types.ActionContext
export type ActionValidator<Payload> = Types.ActionValidator<Payload>
export type ActionReducer<State, Payload> = Types.ActionReducer<State, Payload>
export type ActionConfig<State, Payload> = Types.ActionConfig<State, Payload>
export type ActionDefinition<State, Payload> = Types.ActionDefinition<State, Payload>
export type ActionEnvelope<Payload> = Types.ActionEnvelope<Payload>
export type AnyActionEnvelope = Types.AnyActionEnvelope
export type BoundAction<Payload> = Types.BoundAction<Payload>
export type EffectConfig = Types.EffectConfig
export type EffectListener<Payload> = Types.EffectListener<Payload>
export type EffectConnection = Types.EffectConnection
export type Effect<Payload> = Types.Effect<Payload>
export type Clock = Types.Clock
export type Publisher<State> = Types.Publisher<State>
export type ClientConfig<State> = Types.ClientConfig<State>
export type ClientRuntime<State> = Types.ClientRuntime<State>
export type ServerActionOptions<Actor, Payload> = Types.ServerActionOptions<Actor, Payload>
export type ServerReplication<Actor> = Types.ServerReplication<Actor>
export type ServerConfig<State, Actor> = Types.ServerConfig<State, Actor>
export type ServerRuntime<State, Actor> = Types.ServerRuntime<State, Actor>
export type PredictionLibrary = Types.PredictionLibrary

local Prediction: Types.PredictionLibrary = {
	defineAction = Action.define,
	defineEffect = Effect.define,
	client = Client,
	server = Server,

	adapters = {
		charmSync = adapterMain,
	},
}

return table.freeze(Prediction)
