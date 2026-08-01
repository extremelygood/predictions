--!strict

-- Shared public and internal contracts for Predictions. This module intentionally
-- has no runtime behavior; keeping the types here avoids circular dependencies
-- between the action, effect, client, server, and sync implementations.

export type Sequence = number
export type Timestamp = number

export type ActionContext = {
	actionTime: Timestamp,
}

export type ActionValidator<Payload> = (payload: Payload) -> boolean
export type ActionReducer<State, Payload> = (state: State, payload: Payload, context: ActionContext) -> State?

export type ActionConfig<State, Payload> = {
	id: string,
	validate: ActionValidator<Payload>,
	reduce: ActionReducer<State, Payload>,
}

export type ActionDefinition<State, Payload> = {
	id: string,
	validate: ActionValidator<Payload>,
	reduce: ActionReducer<State, Payload>,
}

export type ActionEnvelope<Payload> = {
	actionId: string,
	payload: Payload,
	sequence: Sequence,
	actionTime: Timestamp,
}

export type AnyActionEnvelope = ActionEnvelope<any>

export type BoundAction<Payload> = {
	dispatch: (payload: Payload) -> boolean,
}

export type EffectConfig = {
	name: string,
}

export type EffectListener<Payload> = (payload: Payload) -> ()

export type EffectConnection = {
	disconnect: () -> (),
}

export type Effect<Payload> = {
	name: string,
	emit: (payload: Payload) -> (),
	connect: (listener: EffectListener<Payload>) -> EffectConnection,
}

-- Effect emissions are deliberately type-erased inside a collector because one
-- reducer may emit several effects with unrelated payload types.
export type EffectEmission = {
	deliver: (payload: any) -> (),
	payload: any,
}

export type EffectCollector = { EffectEmission }

export type Clock = () -> Timestamp
export type Publisher<State> = (state: State) -> ()

export type ClientConfig<State> = {
	initialState: State,
	publish: Publisher<State>,
	send: (envelope: AnyActionEnvelope) -> (),
	now: Clock,
}

export type ClientRuntime<State> = {
	register: <Payload>(definition: ActionDefinition<State, Payload>) -> BoundAction<Payload>,
	reconcile: (authoritativeState: State, processedSequence: Sequence) -> (),
	getAuthoritativeState: () -> State,
	getPredictedState: () -> State,
	getPendingCount: () -> number,
}

export type PendingAction<State> = {
	definition: ActionDefinition<State, any>,
	envelope: AnyActionEnvelope,
}

export type ClientActionRegistry<State> = {
	[string]: ActionDefinition<State, any>,
}

export type ServerActionOptions<Actor, Payload> = {
	acceptClient: ((actor: Actor, payload: Payload) -> boolean)?,
}

export type RegisteredServerAction<State, Actor> = {
	definition: ActionDefinition<State, any>,
	acceptClient: ((actor: Actor, payload: any) -> boolean)?,
}

export type ServerActionRegistry<State, Actor> = {
	[string]: RegisteredServerAction<State, Actor>,
}

-- This is the private bridge used by the server runtime. The adapter owns the
-- batching and flush so a processed sequence can never overtake the state patch
-- produced by `apply`.
export type ServerReplication<Actor> = {
	_commit: (actor: Actor, processedSequence: Sequence, apply: () -> ()) -> (),
}

export type ServerConfig<State, Actor> = {
	getState: () -> State,
	publish: Publisher<State>,
	now: Clock,
	replication: ServerReplication<Actor>,
}

export type ServerRuntime<State, Actor> = {
	register: <Payload>(
		definition: ActionDefinition<State, Payload>,
		options: ServerActionOptions<Actor, Payload>?
	) -> BoundAction<Payload>,
	receive: (actor: Actor, envelope: unknown) -> (),
}

export type PredictionLibrary = {
	defineAction: <State, Payload>(config: ActionConfig<State, Payload>) -> ActionDefinition<State, Payload>,
	defineEffect: <Payload>(config: EffectConfig) -> Effect<Payload>,
	client: <State>(config: ClientConfig<State>) -> ClientRuntime<State>,
	server: <State, Actor>(config: ServerConfig<State, Actor>) -> ServerRuntime<State, Actor>,
}

return {}
