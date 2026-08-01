# Charm Sync Adapter

The prediction core must not import Charm Sync directly. Charm Sync support lives in a small optional adapter.

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
    charmUpdates = updates,
    processedSequence = number?,
}
```

The Charm updates and processed sequence must not be delivered through independent channels.

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

`apply` must perform one atomic reconciliation transaction:

1. apply predicted init or patch data to authoritative shadow state;
2. remove pending actions through the attached cumulative watermark;
3. replay remaining pending actions in order;
4. discard effects produced during replay;
5. publish the final predicted state exactly once;
6. remove predicted signal updates from the Charm update list;
7. return all regular updates unchanged.

No intermediate state may be published between applying the patch, removing pending actions, and replaying the remaining actions.

Acknowledgement-only payloads must still reconcile even when there are no Charm updates.

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

For an accepted action that changes predicted Charm state, the state mutation and processed-sequence advancement must occur in the same server batching boundary. The adapter then flushes one payload containing both the resulting Charm updates and the new watermark.

The server must not send an independent acknowledgement before the corresponding Charm patch is emitted.

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
