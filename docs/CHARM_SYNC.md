# Charm Sync Adapter

The prediction library does not import an external Charm Sync package. Charm Sync support is exposed through a small adapter that receives the game's Charm Sync instance through configuration.

```lua
local Prediction = require(ReplicatedStorage.Packages.Predictions)
local PredictionCharmSync = Prediction.adapters.charmSync
```

## Compatibility

The adapter targets the singleton API from `littensy/charm-sync@0.4.0`. The game injects its Charm Sync module through adapter configuration, so the core package does not install or import Charm Sync.

On the client, the adapter uses `CharmSync.client.addSignals` and `CharmSync.client.patch`. On the server, it exclusively owns `CharmSync.server.connect` while started and uses `flush` and `disconnect`. Game code may continue managing subscriptions with `addSignalsToClient`, `removeSignalsFromClient`, and `removeClient`, but must not install a competing server connection.

## Design rule

Prediction is opt-in per Charm signal.

Signals registered as predicted are reconciled through the prediction runtime. Every other signal continues through ordinary `CharmSync.client.patch` unchanged.

Predicted and regular signals may share:

- one Charm Sync instance;
- one namespace;
- one transport;
- one incoming payload.

## Reconciliation payload

Outgoing sync messages use one envelope:

```lua
{
    charmUpdates = {
        {
            type = "patch", -- or "init"
            data = updates,
        },
    },
    processedSequence = number?,
}
```

`charmUpdates` is the ordered payload array used by Charm Sync 0.4, including the complete array produced when `preserveHistory` is enabled. The Charm updates and processed sequence must not be delivered through independent channels.

## Causal watermark invariant

`processedSequence` is an authoritative-state watermark, not merely confirmation that the server received an action.

A payload carrying:

```lua
processedSequence = 12
```

means that the authoritative state represented by this payload together with previously delivered payloads already reflects every accepted client action through sequence `12`.

Therefore:

- an acknowledgement must never overtake its corresponding authoritative patch;
- an authoritative patch must not be published while its originating action is still replayed as pending;
- pending actions may be removed only as part of the same reconciliation transaction that applies the causally corresponding authoritative updates.

## Client adapter

```lua
local predictionSyncClient = PredictionCharmSync.client({
    runtime = client,
    charmSync = CharmSync,
    predictedSignals = {
        "tools",
        "abilities",
    },
})

SYNC_CHANNEL.onMessage(function(payload)
    Charm.batch(function()
        local regularUpdates = predictionSyncClient.apply(payload)
        CharmSync.client.patch(regularUpdates)
    end)
end)
```

Predicted signal names should match top-level keys in the prediction state.

The adapter registers private Charm Sync setters for predicted keys and owns those registrations for the lifetime of the client session. Do not register competing client setters for those keys. There is intentionally no client `destroy` method.

The outer `Charm.batch` in the example is required. It keeps the prediction runtime's publication and the regular Charm Sync patch in one observer boundary.

`apply` must perform one atomic reconciliation transaction:

1. apply predicted init or patch data to authoritative shadow state;
2. remove pending actions through the attached cumulative watermark;
3. replay remaining pending actions in order;
4. discard effects produced during replay;
5. publish the final predicted state exactly once;
6. remove predicted signal updates from the Charm update list;
7. return all regular updates unchanged.

Update order and values are preserved. Regular-only updates are returned by identity, mixed updates are shallow-cloned, and update entries left empty by filtering are omitted. The adapter never mutates incoming updates.

No intermediate state may be published between applying the patch, removing pending actions, and replaying the remaining actions.

Acknowledgement-only payloads must still reconcile even when there are no Charm updates.

A predicted patch without a watermark reconciles against the last cumulative watermark. A regular-only payload without a watermark does not invoke the prediction runtime. Malformed updates and watermarks that move backwards fail before any authoritative shadow state is changed.

## Server adapter

```lua
local predictionSyncServer = PredictionCharmSync.server({
    charmSync = CharmSync,

    send = function(player, payload)
        SYNC_CHANNEL.fireClient(player, payload)
    end,
})

predictionSyncServer.start()
```

`start` and `destroy` are idempotent. The adapter must be started before its replication bridge is used to process actions. Destroying it stops automatic syncing and clears pending watermark records.

For an accepted action that changes predicted Charm state, the state mutation and processed-sequence advancement must occur in the same server batching boundary. The adapter then flushes one payload containing both the resulting Charm updates and the new watermark.

The server must not send an independent acknowledgement before the corresponding Charm patch is emitted.

Charm Sync 0.4 starts its connected callback with `task.spawn` during `flush`. The adapter installs the pending watermark before applying state, forces a flush, and lets that callback consume the watermark when a patch was produced. Only a watermark record still present after `flush` may use the acknowledgement-only fallback.

Reducers, publishers, transport callbacks, and Charm Sync flush behavior must remain synchronous and non-yielding across this commit boundary. Predicted signals must already be subscribed to the originating actor through Charm Sync; the adapter does not manage subscriptions.

## Acknowledgement-only payloads

An acknowledgement-only payload is valid for a rejected action, accepted no-op, or action that produced no relevant predicted Charm update:

```lua
{
    charmUpdates = {},
    processedSequence = 12,
}
```

The adapter may send this only after the sync flush has established that no causally relevant predicted patch is still pending for that watermark. The acknowledgement-only fallback and normal patch path must not race each other.

Effects are unrelated to the Charm Sync adapter and must not be placed in these payloads.
