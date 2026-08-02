# Shared Stores and Action

The server and client each load their own copy of these stores. Charm signals provide a tiny getter/setter pair, which keeps the example focused on how Predictions integrates with synchronization.

## Predicted counter store

`CounterStore` is the game-facing value published by the prediction runtime. Client code may read it immediately after a successful dispatch.

```lua
--!strict
-- ReplicatedStorage/Demo/Stores/CounterStore.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Charm = require(ReplicatedStorage.Packages.Charm)

local getCounter, setCounter = Charm.signal(0)

return table.freeze({
    get = getCounter,
    set = setCounter,
})
```

## Regular server-status store

`ServerStatusStore` is authoritative-only. Nothing on the client predicts it; the client setter is registered directly with Charm Sync.

```lua
--!strict
-- ReplicatedStorage/Demo/Stores/ServerStatusStore.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Charm = require(ReplicatedStorage.Packages.Charm)

local getServerStatus, setServerStatus = Charm.signal("Waiting")

return table.freeze({
    get = getServerStatus,
    set = setServerStatus,
})
```

## Shared predicted action

Only the counter belongs to prediction state. The regular status store is deliberately absent because it never needs pending-action replay.

```lua
--!strict
-- ReplicatedStorage/Demo/AdjustCounter.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Prediction = require(ReplicatedStorage.Packages.Predictions)

type State = {
    counter: number,
}

type Payload = {
    amount: number,
}

local AdjustCounter = Prediction.defineAction({
    id = "AdjustCounter",

    validate = function(payload: any): boolean
        return type(payload) == "table"
            and type(payload.amount) == "number"
            and payload.amount == payload.amount
            and payload.amount > -math.huge
            and payload.amount < math.huge
    end,

    reduce = function(state: State, payload: Payload): State
        return {
            counter = state.counter + payload.amount,
        }
    end,
})

return AdjustCounter
```

The reducer returns a new absolute prediction state and does not write either store directly. Runtime `publish` callbacks perform store writes after the reducer succeeds.
