# Actions

An action is a shared definition of a state transition. Register the same definition on the client and server so both sides validate and reduce a payload in the same way.

## Define an action

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Predictions = require(ReplicatedStorage.Packages.Predictions)

type State = {
    equippedTool: string?,
}

type Payload = {
    toolId: string,
}

local EquipTool = Predictions.defineAction({
    id = "EquipTool",

    validate = function(payload: Payload): boolean
        return type(payload) == "table" and type(payload.toolId) == "string"
    end,

    reduce = function(
        state: State,
        payload: Payload,
        context: Predictions.ActionContext
    ): State?
        if payload.toolId == "" then
            return nil
        end

        local nextState = table.clone(state)
        nextState.equippedTool = payload.toolId
        return nextState
    end,
})

return EquipTool
```

The fields have separate jobs:

- `id` is the stable identifier sent over the network. It must be unique within a runtime.
- `validate` checks the payload's shape. It runs before the reducer on both client and server.
- `reduce` applies state-dependent rules and returns the next state.
- `context.actionTime` is the timestamp captured when the action was dispatched. Reconciliation reuses that same timestamp.

Return `nil` from `reduce` to reject an action. Returning the original state accepts it as a no-op.

Reducers should be deterministic, must not mutate their input state, and must not yield. Store updates and networking belong in the runtime callbacks rather than in the reducer.

## Dispatch on the client

```lua
local equipTool = client.register(EquipTool)

local accepted = equipTool.dispatch({
    toolId = "Sword",
})
```

If the action is accepted locally, `dispatch` publishes the predicted state, queues the action for reconciliation, sends its envelope, and returns `true`. Invalid or reducer-rejected actions return `false` and are not sent.

## Authorize on the server

The server can add a check that only applies to client requests:

```lua
local equipTool = server.register(EquipTool, {
    acceptClient = function(player, payload)
        return inventory.owns(player, payload.toolId)
    end,
})
```

Use `acceptClient` for permissions tied to the sending player. Put rules based only on shared state in the reducer so prediction uses the same rules.

## Dispatch on the server

The bound server action can also be called by server code:

```lua
local accepted = equipTool.dispatch({
    toolId = "Sword",
})
```

A direct server dispatch validates and reduces normally, but does not call `acceptClient` and does not affect a client's sequence number.
