# Client Setup

The client runtime publishes only predicted state. The adapter privately registers the `counter` setter with Charm Sync, while game code registers `serverStatus` as a normal signal.

```lua
--!strict
-- StarterPlayer/StarterPlayerScripts/DemoClient.client.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage.Packages.Charm)
local CharmSync = require(ReplicatedStorage.Packages.CharmSync)
local Prediction = require(ReplicatedStorage.Packages.Predictions)

local AdjustCounter = require(ReplicatedStorage.Demo.AdjustCounter)
local CounterStore = require(ReplicatedStorage.Demo.Stores.CounterStore)
local ServerStatusStore = require(ReplicatedStorage.Demo.Stores.ServerStatusStore)

local remotes = ReplicatedStorage.Remotes
local actionRemote = remotes.PredictionAction :: RemoteEvent
local readyRemote = remotes.StateReady :: RemoteEvent
local syncRemote = remotes.StateSync :: RemoteEvent

type State = {
    counter: number,
}

local client = Prediction.client({
    initialState = {
        counter = CounterStore.get(),
    },

    publish = function(state: State)
        CounterStore.set(state.counter)
    end,

    send = function(envelope)
        actionRemote:FireServer(envelope)
    end,

    now = function(): number
        return workspace:GetServerTimeNow()
    end,
})

local predictionSync = Prediction.adapters.charmSync.client({
    runtime = client,
    charmSync = CharmSync,
    -- State key "counter" is synced under the Charm Sync key "counter".
    predictedSignals = { counter = "counter" },
})

-- The adapter already registered "counter". Register only regular signals here.
CharmSync.client.addSignals({
    serverStatus = ServerStatusStore.set,
})

syncRemote.OnClientEvent:Connect(function(payload)
    Charm.batch(function()
        -- Applies counter updates to the authoritative shadow state and reconciles.
        -- The returned updates contain only non-predicted signals.
        local regularUpdates = predictionSync.apply(payload)
        CharmSync.client.patch(regularUpdates)
    end)
end)

local adjustCounter = client.register(AdjustCounter)

-- Request both server subscriptions before allowing predicted input.
readyRemote:FireServer()

local accepted = adjustCounter.dispatch({ amount = 1 })
if accepted then
    -- This is already 1, even if no server response has arrived yet.
    print("Predicted counter:", CounterStore.get())
end

-- This remains "Waiting" until a serverStatus sync update arrives.
print("Server status:", ServerStatusStore.get())
```

In a real game, wait for an explicit ready or hydration response before enabling the input that calls `dispatch`. A one-way `StateReady` request keeps this mock short, but does not prove that the initial state reached the client.

Do not also pass `counter = CounterStore.set` to `CharmSync.client.addSignals`. The prediction adapter owns the predicted setter so it can update authoritative shadow state without exposing an intermediate, unreconciled value.
