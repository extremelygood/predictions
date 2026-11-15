# API reference

All public functions use dot syntax. Public objects do not expect an implicit `self` argument.

## Definitions

### `Predictions.defineAction(config)`

Creates a frozen action definition.

```lua
local action = Predictions.defineAction({
    id = "EquipTool",
    validate = function(payload): boolean
        return type(payload) == "table" and type(payload.toolId) == "string"
    end,
    reduce = function(state, payload, context)
        return nextState
    end,
})
```

`reduce` returns the next state or `nil` to reject the action. `context` contains `actionTime`.

### `Predictions.defineEffect(config)`

Creates a local effect with `name`, `emit(payload)`, and `connect(listener)` fields.

```lua
local effect = Predictions.defineEffect({ name = "ToolEquipped" })
local connection = effect.connect(listener)
connection.disconnect()
```

`effect.emit(payload)` is valid only while an action reducer is running.

## Client runtime

### `Predictions.client(config)`

```lua
local client = Predictions.client({
    initialState = initialState,
    publish = publishPredictedState,
    send = sendActionEnvelope,
    now = clock,
})
```

Returns:

| Function | Result |
| --- | --- |
| `client.register(definition)` | Registers an action and returns a bound action. Duplicate IDs raise an error. |
| `client.reconcile(state, sequence)` | Applies authoritative state, clears processed actions, replays the rest, and publishes once. |
| `client.getAuthoritativeState()` | Returns the latest authoritative state supplied to the runtime. |
| `client.getPredictedState()` | Returns the current state after pending actions are applied. |
| `client.getPendingCount()` | Returns the number of actions waiting for acknowledgement. |

A bound action exposes `dispatch(payload) -> boolean`.

## Server runtime

### `Predictions.server(config)`

```lua
local server = Predictions.server({
    getState = getActionState,
    publish = publishActionResult,
    now = clock,
    replication = predictionSyncServer,
})
```

| Field | Meaning |
| --- | --- |
| `getState(payload)` | Returns the state an action is worked out on. Called with a payload that has passed the action's `validate`. The reducer must read and write nothing outside this state. |
| `publish(before, after)` | Writes the reducer's result. `before` is the very table `getState` returned for this action. |
| `now()` | Returns a finite action timestamp for direct server dispatches. |
| `replication` | The started Charm Sync server adapter. |

Returns:

| Function | Result |
| --- | --- |
| `server.register(definition, options?)` | Registers an action and returns a bound action. `options.acceptClient(actor, payload)` can authorize client requests. |
| `server.receive(actor, envelope)` | Validates and processes an action envelope from a client. Every envelope with the expected sequence is acknowledged with the next tick, whether it is applied or rejected. |
| `server.removeActor(actor)` | Forgets a departed actor's sequence and any acknowledgement waiting for him. Call it when a player leaves. |

Calling `dispatch(payload)` on a server-bound action performs a direct authoritative dispatch through `getState` and `publish` and returns whether it was accepted.

## Charm Sync adapter

### `Predictions.adapters.charmSync.client(config)`

```lua
local adapter = Predictions.adapters.charmSync.client({
    runtime = client,
    charmSync = CharmSync,
    predictedSignals = { tools = "tools", abilities = "abilities" },
})

local regularUpdates = adapter.apply(payload)
```

`predictedSignals` maps each predicted top-level state key to the Charm Sync key its signal is synced under. `apply` reconciles predicted signals and returns the remaining Charm Sync updates.

### `Predictions.adapters.charmSync.server(config)`

```lua
local adapter = Predictions.adapters.charmSync.server({
    charmSync = CharmSync,
    send = sendReconciliationPayload,
})

adapter.start()
adapter.flush()
adapter.destroy()
```

| Function | Result |
| --- | --- |
| `adapter.start()` | Connects to Charm Sync and stops its automatic interval. Idempotent. |
| `adapter.flush()` | The network tick: one Charm Sync diff, each player's acknowledgement sent with his updates or alone. Call it once a frame, outside any `Charm.batch`, when the synced getters return current state. Never call `CharmSync.server.flush` yourself: a flush that runs before the game's state is current (while an action is still being handled, for example) would send an acknowledgement ahead of the state that holds it. |
| `adapter.destroy()` | Stops the adapter and drops waiting acknowledgements. Idempotent; `start()` restarts it. |

Pass this adapter to `Predictions.server` as `replication`. It must be started before the runtime receives client actions.

## Exported types

The main module exports types for action definitions and envelopes, effects, client and server configuration, runtimes, and their callbacks. The Charm Sync adapter module also exports its config, update, payload, and adapter types.

For practical examples, see [Actions](ACTIONS.md), [Runtimes](RUNTIMES.md), and [Charm Sync](CHARM_SYNC.md).
