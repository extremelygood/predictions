# Client and server runtimes

Runtimes execute shared action definitions. The client keeps both authoritative and predicted state; the server reads and publishes the authoritative state.

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

It replaces the authoritative state, removes pending actions through the processed sequence, replays the remaining actions, and publishes once. When using Charm Sync, call the adapter's `apply` method instead; it builds the authoritative state and invokes reconciliation at the correct time.

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
    getState = function()
        return {
            tools = toolStore.getAll(),
            abilities = abilityStore.getAll(),
        }
    end,

    publish = function(state)
        toolStore.setAll(state.tools)
        abilityStore.setAll(state.abilities)
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
```

`receive` validates action IDs, payloads, timestamps, authorization, and sequence order. A handled request advances the player's cumulative processed sequence even when it is rejected, allowing the client to remove the corresponding prediction.

The transport must deliver client action envelopes reliably and in order. Stale messages and sequence gaps are ignored.

Call `predictionSync.destroy()` when the adapter should disconnect from Charm Sync. Starting and destroying it more than once is safe.

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
