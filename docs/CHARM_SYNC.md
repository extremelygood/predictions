# Charm Sync integration

The included adapter connects Predictions to the singleton API from Charm Sync 0.4. Your game supplies the Charm Sync module, transport callbacks, and subscriptions; Predictions does not install or import Charm Sync itself.

Prediction is enabled per top-level signal. Other signals continue through the regular Charm Sync patch path, including when both kinds arrive in the same message.

## Client setup

Create the prediction runtime first, then create the adapter with the state keys that should be predicted, each mapped to the Charm Sync key its signal is synced under:

```lua
local predictionSync = Predictions.adapters.charmSync.client({
    runtime = client,
    charmSync = CharmSync,
    predictedSignals = {
        tools = "tools",
        abilities = "playerAbilities",
    },
})
```

Each state key must be a top-level key in the runtime's initial state, and each Charm Sync key may be predicted only once. The adapter registers a Charm Sync setter under each Charm Sync key that writes the mapped state key, so do not register another client setter for the same signal. Payloads keep their Charm Sync keys; nothing is renamed on the way.

Apply incoming messages inside one Charm batch:

```lua
stateSync.OnClientEvent:Connect(function(payload)
    Charm.batch(function()
        local regularUpdates = predictionSync.apply(payload)
        CharmSync.client.patch(regularUpdates)
    end)
end)
```

`apply` takes the predicted Charm Sync keys out of the incoming updates, reconciles them through the runtime, and returns the remaining updates for normal Charm Sync handling. The outer batch keeps both publications in one observer boundary.

The client adapter lasts for the client session and does not have a `destroy` method.

## Server setup

The server adapter owns the Charm Sync server connection while it is started:

```lua
local predictionSync = Predictions.adapters.charmSync.server({
    charmSync = CharmSync,

    send = function(player, payload)
        stateSync:FireClient(player, payload)
    end,
})

predictionSync.start()

RunService.Heartbeat:Connect(function()
    predictionSync.flush()
end)

Players.PlayerRemoving:Connect(function(player)
    CharmSync.server.removeClient(player)
    server.removeActor(player)
end)
```

Pass `predictionSync` as the `replication` value when creating the server runtime. Do not also call `CharmSync.server.connect` elsewhere while this adapter is active. Existing subscription management through Charm Sync can continue as usual, and predicted signals must be subscribed for the player before their actions are processed.

`start()` connects to Charm Sync and stops its automatic interval, which leaves the adapter's `flush` as the only sync. `flush()` is the network tick:

- Call it once a frame, outside any `Charm.batch`, at a point where the synced getters return current state.
- Each call takes one Charm Sync diff. Every player with updates gets them together with the highest sequence of his the server has handled since the last tick; a player with no updates gets that acknowledgement alone.
- An acknowledgement only ever leaves inside `flush`. The server runtime records it the moment it starts handling an action, and it waits there until the tick, so the state it arrives with always holds the action, whether it was applied or rejected.
- Never call `CharmSync.server.flush` yourself. A flush that runs before the game's state is current, for example while an action is still being handled, would send an acknowledgement ahead of the state that holds it.

Call `server.removeActor(player)` when a player leaves; it drops any acknowledgement still waiting for him.

`start()` and `destroy()` are idempotent. `destroy()` stops the adapter and drops waiting acknowledgements; `flush` sends nothing until `start()` is called again.

## Payload shape

The server-to-client transport carries one envelope:

```lua
{
    charmUpdates = {
        {
            type = "patch", -- or "init"
            data = updates,
        },
    },
    processedSequence = 12, -- optional
}
```

`charmUpdates` uses Charm Sync 0.4's ordered update array. `processedSequence` means the delivered authoritative state includes every action of that player through that sequence that the server accepted. Keep these fields together on one ordered transport; a separate acknowledgement channel can clear a prediction before its authoritative result arrives.

An acknowledgement-only message uses an empty update array:

```lua
{
    charmUpdates = {},
    processedSequence = 12,
}
```

See the [demo](demo/README.md) for subscription setup and a full message flow.
