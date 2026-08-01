# Public API

This document locks down the intended public shape. Detailed behavior lives in the focused documents beside it.

All returned objects use closure-based dot functions. No public library function requires colon syntax or an implicit `self`.

## Definitions

```lua
local EquipTool = Prediction.defineAction({
    id = "EquipTool",
    validate = validateEquipTool,
    reduce = reduceEquipTool,
})

local ToolEquipped = Prediction.defineEffect({
    name = "ToolEquipped",
})
```

## Client

```lua
local client = Prediction.client({
    initialState = initialState,
    publish = publishPredictedState,
    send = sendActionEnvelope,
    now = function()
        return workspace:GetServerTimeNow()
    end,
})

local equipTool = client.register(EquipTool)

equipTool.dispatch({
    characterId = localCharacterId,
    toolId = selectedToolId,
})
```

## Server

```lua
local server = Prediction.server({
    getState = getAuthoritativeState,
    publish = publishAuthoritativeState,
    now = function()
        return workspace:GetServerTimeNow()
    end,
    replication = predictionSyncServer,
})

local equipTool = server.register(EquipTool, {
    acceptClient = function(player, payload)
        return payload.characterId == getPlayerCharacterId(player)
    end,
})

ACTION_CHANNEL.onMessage(function(player, envelope)
    server.receive(player, envelope)
end)
```

The same bound action can be dispatched directly by server code:

```lua
equipTool.dispatch({
    characterId = npcCharacterId,
    toolId = swordToolId,
})
```

## Sync delivery contract

The optional adapter is exposed by the main library and targets Charm Sync 0.4:

```lua
local Prediction = require(ReplicatedStorage.Packages.Predictions)
local PredictionCharmSync = Prediction.adapters.charmSync
```

The Charm Sync adapter delivers authoritative updates and the cumulative processed sequence in one envelope:

```lua
{
    charmUpdates = {
        {
            type = "patch",
            data = updates,
        },
    },
    processedSequence = 12,
}
```

Do not create a separate acknowledgement channel. `processedSequence = 12` guarantees that the authoritative state delivered so far already reflects every accepted action through sequence `12`. The client applies the patch, removes acknowledged actions, replays the rest, and publishes once.

## Effects

Effects are connected to directly. They are not registered with runtimes.

```lua
ToolEquipped.connect(function(payload)
    toolPresentation.update(payload.characterId, payload.toolId)
end)
```

Reducers may emit them:

```lua
local function reduceEquipTool(state, payload)
    local nextState = tryEquipTool(state, payload)

    if nextState == nil then
        return nil
    end

    ToolEquipped.emit(payload)
    return nextState
end
```

The runtime schedules each collected effect listener in an independent deferred task after an accepted real dispatch. A yielding or failing listener does not block dispatch or other listeners. Effects are discarded during reconciliation replay.

Effects are never automatically sent over the network.

## Minimal public surface

```lua
Prediction.defineAction(config)
Prediction.defineEffect(config)

Prediction.client(config)
client.register(actionDefinition)
client.reconcile(authoritativeState, processedSequence)
client.getAuthoritativeState()
client.getPredictedState()
client.getPendingCount()
clientAction.dispatch(payload)

Prediction.server(config)
server.register(actionDefinition, options?)
server.receive(player, envelope)
serverAction.dispatch(payload)

effect.emit(payload)
effect.connect(callback)
connection.disconnect()

Prediction.adapters.charmSync.client(config)
clientSync.apply(payload)

Prediction.adapters.charmSync.server(config)
serverSync.start()
serverSync.destroy()
```

Avoid adding public helpers until a concrete use case requires them.
