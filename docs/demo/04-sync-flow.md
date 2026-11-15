# Sync Flow

Assume both server values and both client values have completed initial synchronization:

```text
counter      = 0
serverStatus = "Waiting"
```

## 1. Client prediction

The client calls:

```lua
adjustCounter.dispatch({ amount = 1 })
```

The client runtime validates and reduces the action immediately. It publishes `counter = 1`, stores sequence `1` as pending, and sends an envelope shaped like:

```lua
{
    actionId = "AdjustCounter",
    payload = { amount = 1 },
    sequence = 1,
    actionTime = 123.45,
}
```

At this point:

| Location | `counter` | `serverStatus` |
| --- | ---: | --- |
| Client | `1` (predicted) | `"Waiting"` |
| Server | `0` | `"Waiting"` |

## 2. Authoritative processing

The server receives sequence `1` and records it as handled for the next tick. It runs the same reducer against authoritative state and publishes `counter = 1`. Nothing is sent yet.

On the next network tick, `predictionSync.flush()` takes one Charm Sync diff. Because the player subscribed to both keys, it may also hold a regular status change. The server adapter sends one causally aligned envelope:

```lua
{
    charmUpdates = {
        {
            type = "patch",
            data = {
                counter = 1,
                serverStatus = "Round running",
            },
        },
    },
    processedSequence = 1,
}
```

Actual Charm Sync batching may place changes in more than one ordered update. The adapter preserves that order. If the player sent several actions within one tick, the envelope carries the highest of their sequences.

## 3. Split and reconcile

Inside one `Charm.batch`, `predictionSync.apply(payload)`:

1. removes `counter` from the ordinary update stream;
2. applies it to the runtime's authoritative shadow state;
3. removes pending actions through sequence `1`;
4. replays any later pending actions;
5. publishes the final predicted counter once; and
6. returns the remaining `serverStatus` update.

The caller passes that returned update to `CharmSync.client.patch`, producing:

| Location | `counter` | `serverStatus` |
| --- | ---: | --- |
| Client | `1` (confirmed) | `"Round running"` |
| Server | `1` | `"Round running"` |

The counter does not flicker back to `0` during reconciliation, and the status never changes early.

## Rejection

If the server rejects the expected action, for example because `math.abs(amount) > 10`, sequence `1` is still handled. With no counter change to carry it, the next tick sends it alone:

```lua
{
    charmUpdates = {},
    processedSequence = 1,
}
```

Applying it removes sequence `1` and replays anything newer. With no remaining actions, the predicted counter rolls back to the last authoritative value. The regular status store is untouched.
