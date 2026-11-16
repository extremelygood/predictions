--!strict

-- The library's types. They live in one module with no behaviour so the stores, actions, effects and runtimes can
-- share them without requiring each other.

-- Stores ---------------------------------------------------------------------------------------------------------

-- A table of entries, each followed on its own (see store.luau for the rules).
export type Keyed<K, V> = {
	get: (key: K) -> V?,
	keys: () -> { [K]: true },
	all: () -> { [K]: V },
	set: (key: K, value: V?) -> (),
	patch: (changes: { [K]: V | false }) -> (),
	listen: (listener: (key: K, value: V?, previous: V?) -> ()) -> () -> (),
}

-- One value, held as the only entry of a keyed store.
export type Value<V> = {
	get: () -> V,
	set: (value: V) -> (),
	listen: (listener: (value: V, previous: V) -> ()) -> () -> (),
}

-- A lookup derived from a keyed store: the frozen set of keys of the entries found under an index key, followed
-- per index key when read reactively.
export type Index<K, I> = {
	get: (indexKey: I) -> { [K]: true },
	first: (indexKey: I) -> K?,
}

-- Called synchronously inside a write, once for each entry the write changed. `value` nil: the entry is gone.
export type WriteListener<K, V> = (key: K, value: V?, previous: V?) -> ()

-- What a store made by `keyed` holds besides its public members. For the runtimes only.
export type KeyedStore<K, V> = {
	get: (key: K) -> V?,
	keys: () -> { [K]: true },
	all: () -> { [K]: V },
	set: (key: K, value: V?) -> (),
	patch: (changes: { [K]: V | false }) -> (),
	listen: (listener: (key: K, value: V?, previous: V?) -> ()) -> () -> (),
	_onWrite: (listener: WriteListener<K, V>) -> () -> (),
	_write: (changes: { [K]: V | false }) -> (),
	_seal: () -> (),
}

-- What a store made by `value` holds besides its public members. For the runtimes only.
export type ValueStore<V> = {
	get: () -> V,
	set: (value: V) -> (),
	listen: (listener: (value: V, previous: V) -> ()) -> () -> (),
	-- The keyed store underneath; its only key is `VALUE_KEY` in store.luau.
	_keyed: KeyedStore<string, V>,
}

-- What a runtime is given as its tables: the name of each table on the wire and its store.
export type Tables = { [string]: Keyed<string, any> | Value<any> }

-- Actions --------------------------------------------------------------------------------------------------------

export type ActionContext<Actor> = {
	actionTime: number,
	actor: Actor,
}

-- `State` is `{ [tableName]: { [key]: entry } }`, a value table appearing as its value.
export type ActionDefinition<State, Payload, Actor> = {
	id: string,
	-- Whether the payload has the shape the action takes. It is all that stands between a client and `reduce`.
	validate: (payload: unknown) -> boolean,
	-- The part of the world the action may see and change. `world` is read by key only.
	scope: ((world: State, actor: Actor, payload: Payload) -> State)?,
	-- The new scope, or nil to reject the action. Pure: it reads only its arguments.
	reduce: (state: State, payload: Payload, context: ActionContext<Actor>) -> State?,
}

-- What a client sends for each action it dispatches.
export type ActionEnvelope = {
	actionId: string,
	actor: any,
	payload: any,
	sequence: number,
	actionTime: number,
}

-- Effects --------------------------------------------------------------------------------------------------------

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

-- One reducer may emit several effects with unrelated payload types, so a collector holds them type-erased.
export type EffectEmission = {
	deliver: (payload: any) -> (),
	payload: any,
}

export type EffectCollector = { EffectEmission }

-- Runtimes -------------------------------------------------------------------------------------------------------

-- Which entries of a table a client may see: `true` for every entry, or a function called per client inside an
-- effect (so it follows the stores it reads) that returns the rule for that client.
export type View<Client> = true | (client: Client) -> (key: string, entry: any) -> boolean

export type ServerConfig<State, Actor, Client> = {
	tables: Tables,
	-- One view for every table, no more and no less.
	views: { [string]: View<Client> },
	now: () -> number,
	-- Whether `client` may act as `actor`. Without it the actor must be the client itself.
	isActor: ((client: Client, actor: unknown) -> boolean)?,
	-- The scope of actions that name none. Without it such an action sees every table whole.
	scope: ((world: State, actor: Actor, payload: any) -> State)?,
	-- A client's action time is clamped to `now() - maxAge .. now() + maxLead`.
	actionTime: { maxAge: number, maxLead: number }?,
}

export type ServerRuntime<State, Actor, Client> = {
	-- His next message holds everything he may see.
	addClient: (client: Client) -> (),
	-- Drops his views, his sequence and any acknowledgement waiting for him.
	removeClient: (client: Client) -> (),
	-- Clients may send this action; `accept` is the game's own check after `validate` and the actor check.
	allow: <Payload>(
		definition: ActionDefinition<State, Payload, Actor>,
		accept: ((client: Client, actor: Actor, payload: Payload) -> boolean)?
	) -> (),
	-- The server's own action; whether it was applied.
	dispatch: <Payload>(definition: ActionDefinition<State, Payload, Actor>, actor: Actor, payload: Payload) -> boolean,
	-- An envelope a client sent.
	receive: (client: Client, envelope: unknown) -> (),
	-- One message per client that has something to be told; the game sends them. Call it outside any `Charm.batch`.
	flush: () -> { [Client]: any },
}

export type ClientConfig<State, Actor> = {
	tables: Tables,
	send: (envelope: ActionEnvelope) -> (),
	now: () -> number,
	-- The scope of actions that name none. Without it such an action sees every table whole.
	scope: ((world: State, actor: Actor, payload: any) -> State)?,
}

export type ClientRuntime<State, Actor> = {
	-- A message the server's `flush` made for this client.
	receive: (message: unknown) -> (),
	-- Applies the action to the stores at once and sends it; whether it was applied.
	dispatch: <Payload>(definition: ActionDefinition<State, Payload, Actor>, actor: Actor, payload: Payload) -> boolean,
}

return {}
