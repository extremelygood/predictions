# Charm Sync integration

The included adapter connects Predictions to the singleton API from Charm Sync 0.4. Your game supplies the Charm Sync module, transport callbacks, and subscriptions; Predictions does not install or import Charm Sync itself.

Prediction is enabled per top-level signal. Other signals continue through the regular Charm Sync patch path, including when both kinds arrive in the same message.

## Client setup

Create the prediction runtime first, then create the adapter with the state keys that should be predicted:

```lua
local predictionSync = Predictions.adapters.charmSync.client({
    runtime = client,
    charmSync = CharmSync,
    predictedSignals = {
        "tools",
        "abilities",
    },
})
```

Each predicted name must be a unique top-level key in the runtime's initial state. The adapter registers Charm Sync setters for those keys, so do not register another client setter for the same signal.

Apply incoming messages inside one Charm batch:

```lua
stateSync.OnClientEvent:Connect(function(payload)
    Charm.batch(function()
        local regularUpdates = predictionSync.apply(payload)
        CharmSync.client.patch(regularUpdates)
    end)
end)
```

`apply` takes predicted keys out of the incoming updates, reconciles them through the runtime, and returns the remaining updates for normal Charm Sync handling. The outer batch keeps both publications in one observer boundary.

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
```

Pass `predictionSync` as the `replication` value when creating the server runtime. Do not also call `CharmSync.server.connect` elsewhere while this adapter is active. Existing subscription management through Charm Sync can continue as usual, and predicted signals must be subscribed for the player before their actions are processed.

When an action is handled, the adapter flushes its authoritative updates together with the cumulative processed sequence. If an action is rejected or changes no subscribed state, it sends an acknowledgement-only payload so the client can clear the prediction.

`start()` and `destroy()` are idempotent. `destroy()` disconnects the adapter and clears pending commits.

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

`charmUpdates` uses Charm Sync 0.4's ordered update array. `processedSequence` means the delivered authoritative state includes every accepted action through that sequence. Keep these fields together on one ordered transport; a separate acknowledgement channel can clear a prediction before its authoritative result arrives.

An acknowledgement-only message uses an empty update array:

```lua
{
    charmUpdates = {},
    processedSequence = 12,
}
```

See the [demo](demo/README.md) for subscription setup and a full message flow.
