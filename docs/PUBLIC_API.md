# API reference

```lua
local Predictions = require(ReplicatedStorage.Packages.Predictions)
```

Every function and object uses dot syntax; none takes an implicit `self`.

## Functions

| Name | Signature | See |
| --- | --- | --- |
| `Predictions.keyed` | `<K, V>() -> Keyed<K, V>` | [Stores](STORES.md#keyed-stores) |
| `Predictions.value` | `<V>(initial: V) -> Value<V>` | [Stores](STORES.md#value-stores) |
| `Predictions.index` | `<K, V, I>(source: Keyed<K, V>, keysOf: (value: V, key: K) -> { I }) -> Index<K, I>` | [Stores](STORES.md#indexes) |
| `Predictions.defineAction` | `<State, Payload, Actor>(config: ActionDefinition<State, Payload, Actor>) -> ActionDefinition<State, Payload, Actor>` | [Actions](ACTIONS.md) |
| `Predictions.defineEffect` | `<Payload>(config: EffectConfig) -> Effect<Payload>` | [Effects](EFFECTS.md) |
| `Predictions.server` | `<State, Actor, Client>(config: ServerConfig<State, Actor, Client>) -> ServerRuntime<State, Actor, Client>` | [Runtimes](RUNTIMES.md#server) |
| `Predictions.client` | `<State, Actor>(config: ClientConfig<State, Actor>) -> ClientRuntime<State, Actor>` | [Runtimes](RUNTIMES.md#client) |

`defineAction` returns a frozen copy of its config. `defineEffect` and the runtimes check their configs and error on a missing or mistyped field.

## Types

The module exports these types, used as `Predictions.Keyed<string, Purse>` and so on.

### Stores

```lua
export type Keyed<K, V> = {
	get: (key: K) -> V?,
	keys: () -> { [K]: true },
	all: () -> { [K]: V },
	set: (key: K, value: V?) -> (),
	patch: (changes: { [K]: V | false }) -> (),
	listen: (listener: (key: K, value: V?, previous: V?) -> ()) -> () -> (),
}

export type Value<V> = {
	get: () -> V,
	set: (value: V) -> (),
	listen: (listener: (value: V, previous: V) -> ()) -> () -> (),
}

export type Index<K, I> = {
	get: (indexKey: I) -> { [K]: true },
	first: (indexKey: I) -> K?,
}

-- A runtime's tables: the name of each table on the wire and its store.
export type Tables = { [string]: Keyed<string, any> | Value<any> }
```

### Actions

```lua
export type ActionContext<Actor> = {
	actionTime: number,
	actor: Actor,
}

export type ActionDefinition<State, Payload, Actor> = {
	id: string,
	validate: (payload: unknown) -> boolean,
	scope: ((world: State, actor: Actor, payload: Payload) -> State)?,
	reduce: (state: State, payload: Payload, context: ActionContext<Actor>) -> State?,
}

export type ActionEnvelope = {
	actionId: string,
	actor: any,
	payload: any,
	sequence: number,
	actionTime: number,
}
```

### Runtimes

```lua
export type View<Client> = true | (client: Client) -> (key: string, entry: any) -> boolean

export type ServerConfig<State, Actor, Client> = {
	tables: Tables,
	views: { [string]: View<Client> },
	now: () -> number,
	isActor: ((client: Client, actor: unknown) -> boolean)?,
	scope: ((world: State, actor: Actor, payload: any) -> State)?,
	actionTime: { maxAge: number, maxLead: number }?,
}

export type ServerRuntime<State, Actor, Client> = {
	addClient: (client: Client) -> (),
	removeClient: (client: Client) -> (),
	allow: <Payload>(
		definition: ActionDefinition<State, Payload, Actor>,
		accept: ((client: Client, actor: Actor, payload: Payload) -> boolean)?
	) -> (),
	dispatch: <Payload>(definition: ActionDefinition<State, Payload, Actor>, actor: Actor, payload: Payload) -> boolean,
	receive: (client: Client, envelope: unknown) -> (),
	flush: () -> { [Client]: any },
}

export type ClientConfig<State, Actor> = {
	tables: Tables,
	send: (envelope: ActionEnvelope) -> (),
	now: () -> number,
	scope: ((world: State, actor: Actor, payload: any) -> State)?,
}

export type ClientRuntime<State, Actor> = {
	receive: (message: unknown) -> (),
	dispatch: <Payload>(definition: ActionDefinition<State, Payload, Actor>, actor: Actor, payload: Payload) -> boolean,
}
```

### Effects

```lua
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
```

### The module

```lua
export type PredictionsLibrary = typeof(Predictions)
```
