--!strict

local Action = require(script.action)
local Client = require(script.client)
local Effect = require(script.effect)
local Server = require(script.server)
local Store = require(script.store)
local Types = require(script._types)

export type Keyed<K, V> = Types.Keyed<K, V>
export type Value<V> = Types.Value<V>
export type Index<K, I> = Types.Index<K, I>
export type Tables = Types.Tables
export type ActionContext<Actor> = Types.ActionContext<Actor>
export type ActionDefinition<State, Payload, Actor> = Types.ActionDefinition<State, Payload, Actor>
export type ActionEnvelope = Types.ActionEnvelope
export type View<Client> = Types.View<Client>
export type ServerConfig<State, Actor, Client> = Types.ServerConfig<State, Actor, Client>
export type ServerRuntime<State, Actor, Client> = Types.ServerRuntime<State, Actor, Client>
export type ClientConfig<State, Actor> = Types.ClientConfig<State, Actor>
export type ClientRuntime<State, Actor> = Types.ClientRuntime<State, Actor>
export type EffectConfig = Types.EffectConfig
export type EffectListener<Payload> = Types.EffectListener<Payload>
export type EffectConnection = Types.EffectConnection
export type Effect<Payload> = Types.Effect<Payload>

local Predictions = {
	keyed = Store.keyed,
	value = Store.value,
	index = Store.index,
	defineAction = Action.define,
	defineEffect = Effect.define,
	server = Server,
	client = Client,
}

export type PredictionsLibrary = typeof(Predictions)

return table.freeze(Predictions)
