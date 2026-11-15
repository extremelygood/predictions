# Client and server runtimes

Runtimes execute shared action definitions. The client keeps both authoritative and predicted state; the server works each action out on the part of the authoritative state it belongs to and publishes the result.

## Client

```lua
local client = Predictions.client({
    initialState = {
        tools = toolStore.getAll(),
        abilities = abilityStore.getAll(),
    },

    publish = function(state)
        toolStore.setAll(state.tools)
        abilityStore.setAll(state.abilities)
    end,

    send = function(envelope)
        predictionAction:FireServer(envelope)
    end,

    now = function()
        return workspace:GetServerTimeNow()
    end,
})

local equipTool = client.register(EquipTool)
```

`initialState` seeds both client state copies. `publish` receives the complete predicted state after a local dispatch or reconciliation. `send` forwards a validated action envelope through your transport, and `now` supplies a finite action timestamp.

The client exposes a few inspection methods:

```lua
client.getAuthoritativeState()
client.getPredictedState()
client.getPendingCount()
```

Most games only need these for debugging or tests.

### Reconciliation

The low-level reconciliation call is:

```lua
client.reconcile(authoritativeState, processedSequence)
```

It replaces the authoritative state, removes pending actions through the processed sequence, replays the remaining actions, and publishes once. `processedSequence` must be a non-negative integer, must never move backwards from a previously applied watermark, and must never exceed the highest sequence dispatched by that client runtime. These are programmer/transport invariant failures; the runtime raises an assertion before reconciliation mutates core client state. When using Charm Sync, call the adapter's `apply` method instead; it builds the authoritative state and invokes reconciliation at the correct time.

## Server

Create and start the server Charm Sync adapter before allowing action messages to reach the runtime:

```lua
local predictionSync = Predictions.adapters.charmSync.server({
    charmSync = CharmSync,

    send = function(player, payload)
        stateSync:FireClient(player, payload)
    end,
})

predictionSync.start()

local server = Predictions.server({
    getState = function(payload)
        return {
            tools = toolStore.getAll(),
            abilities = abilityStore.getAll(),
        }
    end,

    publish = function(before, after)
        toolStore.setAll(after.tools)
        abilityStore.setAll(after.abilities)
    end,

    now = function()
        return workspace:GetServerTimeNow()
    end,

    replication = predictionSync,
})

server.register(EquipTool, {
    acceptClient = canEquipTool,
})

predictionAction.OnServerEvent:Connect(function(player, envelope)
    server.receive(player, envelope)
end)

RunService.Heartbeat:Connect(function()
    predictionSync.flush()
end)

Players.PlayerRemoving:Connect(function(player)
    CharmSync.server.removeClient(player)
    server.removeActor(player)
end)
```

### The state an action is worked out on

`getState(payload)` returns the state the action is reduced on. It is called with the action's payload after `validate` has accepted it, so a game can return only the part of its state the action belongs to, for example one character's. The reducer is given that state and must read and write nothing outside it. `publish(before, after)` then writes the result: `before` is the very table `getState` returned for this action, so the game can compare the two and write only what changed.

A game whose actions all work on the whole state returns everything from `getState` and writes `after` in `publish`, as above. There is no separate path for it.

### The network tick

`predictionSync.flush()` is the network tick. Call it once a frame, outside any `Charm.batch`, at a point where the getters subscribed through Charm Sync return current state. Each call takes one Charm Sync diff and sends every player his updates together with the highest sequence of his that the server has handled; a player with no updates gets that acknowledgement alone. An acknowledgement only ever leaves inside `flush`, so the state it arrives with always holds the actions it covers.

The adapter stops Charm Sync's own interval when it starts. Never call `CharmSync.server.flush` yourself: a flush that runs before the game's state is current (while an action is still being handled, for example) would send an acknowledgement ahead of the state that holds it.

### Receiving actions

`receive` checks the sequence order first. Once an envelope carries the expected sequence, that sequence is handled: it is recorded and acknowledged before anything else happens to the action. The runtime then checks the action ID, timestamp, payload and authorization and runs the reducer. A rejection at any of these steps, a failing reducer, or an error thrown by `getState` or `publish` all leave the sequence acknowledged, so the client can drop the prediction.

The transport must deliver client action envelopes reliably and in order. Stale/duplicate messages and sequence gaps are ignored and emit a warning because either case violates the expected transport sequence. An unregistered action id is rejected normally so its sequence is acknowledged, but also emits a warning because client/server action registration is inconsistent. Validator, authorization, and reducer rejections remain normal control flow and do not emit these warnings.

### Players leaving

Call `server.removeActor(player)` when a player leaves. It forgets his sequence and any acknowledgement still waiting for the next tick.

Call `predictionSync.destroy()` to stop the adapter; `flush` then sends nothing until it is started again. Starting and destroying it more than once is safe.

## Action envelope

The runtime sends this table through the client `send` callback:

```lua
{
    actionId = "EquipTool",
    payload = payload,
    sequence = 12,
    actionTime = 123.45,
}
```

Treat the envelope as library-owned data. Game code should forward it without changing its fields.
