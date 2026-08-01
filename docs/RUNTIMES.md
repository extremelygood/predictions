# Client and Server Runtimes

Runtimes bind shared action definitions to client-predicted or server-authoritative execution.

## Client runtime

```lua
local client = Prediction.client({
    initialState = {
        tools = toolStore.getAll(),
        abilities = abilityStore.getAll(),
    },

    publish = function(state)
        toolStore.setAll(state.tools)
        abilityStore.setAll(state.abilities)
    end,

    send = function(envelope)
        ACTION_CHANNEL.fireServer(envelope)
    end,

    now = function()
        return workspace:GetServerTimeNow()
    end,
})
```

`publish` receives the complete final predicted state and updates the game-facing client stores.

The client runtime owns:

- authoritative shadow state;
- current predicted state;
- the next client sequence;
- ordered pending actions;
- registered action definitions.

## Client reconciliation

```lua
client.reconcile(authoritativeState, processedSequence)
```

`processedSequence` is a watermark for the supplied authoritative state. It may only acknowledge actions whose accepted results are already represented by that state.

Reconciliation must execute as one transaction:

1. replace authoritative shadow state;
2. remove cumulatively acknowledged pending actions;
3. replay remaining pending actions in order;
4. discard all effects produced during replay;
5. publish the final predicted state exactly once.

The runtime must never publish after step 2 and then publish again after replay. Otherwise the client can briefly show an acknowledged action disappearing before its authoritative result is visible.

## Server runtime

```lua
local server = Prediction.server({
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

    replication = predictionSyncServer,
})
```

The server reads authoritative state through `getState` and commits accepted results through `publish`.

## Receiving client requests

```lua
ACTION_CHANNEL.onMessage(function(player, envelope)
    server.receive(player, envelope)
end)
```

The transport envelope is library-owned:

```lua
{
    actionId = "EquipTool",
    payload = payload,
    sequence = 12,
    actionTime = 123.45,
}
```

The server runtime handles envelope validation, sequencing, action lookup, payload validation, optional `acceptClient`, reduction, publication, effect delivery to local listeners, and acknowledgement.

Rejected client requests must still be acknowledged when their expected sequence is processed. Accepted actions that change state must advance their processed sequence only in causal alignment with the authoritative replication containing that change.

## Publishing

Reducers calculate state. Publishers expose it.

Version one should pass the complete final state to `publish`; it does not need generalized change sets.

Effects should fire only after an accepted state calculation and should never fire during reconciliation replay.
