# Action Definitions

Actions describe deterministic state transitions. An action definition is shared between the client and server.

## Definition

```lua
--!strict
local Prediction = require(ReplicatedStorage.Packages.Prediction)

type GameState = {
    tools: {
        [string]: {
            ownerCharacterId: string,
            isEquipped: boolean,
        },
    },
}

type EquipToolPayload = {
    characterId: string,
    toolId: string,
}

local EquipTool = Prediction.defineAction({
    id = "EquipTool",

    validate = function(payload: any): boolean
        return type(payload) == "table"
            and type(payload.characterId) == "string"
            and type(payload.toolId) == "string"
    end,

    reduce = function(
        state: GameState,
        payload: EquipToolPayload,
        _context: Prediction.ActionContext
    ): GameState?
        local tool = state.tools[payload.toolId]

        if tool == nil or tool.ownerCharacterId ~= payload.characterId then
            return nil
        end

        if tool.isEquipped then
            return state
        end

        local nextTools = table.clone(state.tools)
        local nextTool = table.clone(tool)
        nextTool.isEquipped = true
        nextTools[payload.toolId] = nextTool

        local nextState = table.clone(state)
        nextState.tools = nextTools
        return nextState
    end,
})

return EquipTool
```

## Rules

- `id` is a stable network identifier.
- `validate` checks payload structure.
- `reduce` checks state-based game rules and calculates the next absolute state.
- Returning `nil` rejects the action.
- Returning the same state accepts a no-op action.
- Reducers must not mutate their input state.
- Reducers must not update stores, send remotes, or yield.
- Game targets such as `characterId`, `toolId`, or `targetId` belong in the payload.

## Client dispatch

```lua
local equipTool = client.register(EquipTool)

local applied = equipTool.dispatch({
    characterId = localCharacterId,
    toolId = selectedToolId,
})
```

A successful client dispatch predicts immediately, queues the action, publishes the new predicted state, and sends a sequenced envelope.

A locally rejected action is not queued or sent.

## Server registration

```lua
local equipTool = server.register(EquipTool, {
    acceptClient = function(player, payload)
        return payload.characterId == characterStore.getPlayerCharacterId(player)
    end,
})
```

`acceptClient` is optional and server-only. It checks whether the requesting player may submit that payload.

State-based checks such as ownership, cooldowns, ammunition, and entity existence belong in the reducer when that information is represented in state.

## Direct server dispatch

```lua
local applied = equipTool.dispatch({
    characterId = npcCharacterId,
    toolId = swordToolId,
})
```

Direct server dispatch:

- uses the same reducer;
- does not require an actor argument;
- does not call `acceptClient`;
- does not create or advance a client sequence.
