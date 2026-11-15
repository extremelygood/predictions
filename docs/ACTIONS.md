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

## The state a reducer is given

On the client a reducer is given the whole predicted state. On the server it is given the state the server runtime's `getState(payload)` returns for its payload, which may be only the part of the state the action belongs to, such as one character's. A reducer must read and write nothing outside the state it is given: no store reads, no globals. That way the client and server work the same action out on the same values. A game whose actions all work on the whole state returns everything from `getState`; see [Runtimes](RUNTIMES.md#the-state-an-action-is-worked-out-on).

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

A direct server dispatch validates, reduces on the state `getState` returns for its payload, and publishes like a client action, but does not call `acceptClient` and does not affect a client's sequence number.
