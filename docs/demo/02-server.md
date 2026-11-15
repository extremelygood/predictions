# Server Setup

The server owns both authoritative values. It also gives the Predictions adapter exclusive ownership of `CharmSync.server.connect` and of every flush, so a counter patch and its processed-sequence watermark are sent together on the network tick.

```lua
--!strict
-- ServerScriptService/DemoServer.server.luau

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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

type AdjustPayload = {
    amount: number,
}

local predictionSync = Prediction.adapters.charmSync.server({
    charmSync = CharmSync,

    send = function(player: Player, payload)
        syncRemote:FireClient(player, payload)
    end,
})

-- Start before the runtime receives any client action.
predictionSync.start()

local server = Prediction.server({
    -- The demo's actions all work on the whole state, so getState ignores the payload.
    getState = function(_payload: unknown): State
        return {
            counter = CounterStore.get(),
        }
    end,

    publish = function(_before: State, after: State)
        CounterStore.set(after.counter)
    end,

    now = function(): number
        return workspace:GetServerTimeNow()
    end,

    replication = predictionSync,
})

local adjustCounter = server.register(AdjustCounter, {
    acceptClient = function(_player: Player, payload: AdjustPayload): boolean
        -- A small server-only authorization rule for this demo.
        return math.abs(payload.amount) <= 10
    end,
})

actionRemote.OnServerEvent:Connect(function(player: Player, envelope)
    server.receive(player, envelope)
end)

readyRemote.OnServerEvent:Connect(function(player: Player)
    -- Both signals share one Charm Sync subscription.
    CharmSync.server.addSignalsToClient(player, {
        counter = CounterStore.get,
        serverStatus = ServerStatusStore.get,
    })
end)

Players.PlayerRemoving:Connect(function(player: Player)
    CharmSync.server.removeClient(player)
    server.removeActor(player)
end)

-- The network tick: one Charm Sync diff a frame, each acknowledgement with it.
RunService.Heartbeat:Connect(function()
    predictionSync.flush()
end)

-- Example of an ordinary authoritative update. The client does not predict it.
ServerStatusStore.set("Round running")
```

Do not install another `CharmSync.server.connect` callback while `predictionSync` is started, and never call `CharmSync.server.flush` yourself. The adapter owns that connection, stops Charm Sync's own interval, and sends through its configured `send` callback only when `predictionSync.flush()` runs. Call it once a frame, outside any `Charm.batch`, where `CounterStore.get` returns the current counter. A handled action's acknowledgement waits for that tick, so it always arrives with the counter that holds the action.

Call `server.removeActor(player)` when a player leaves, so his sequence and any waiting acknowledgement are forgotten.

The originating player must already be subscribed to `counter` before sending actions. Otherwise Charm Sync cannot produce the authoritative counter patch that the processed sequence is meant to accompany, and the acknowledgement goes alone.

Direct server actions are also available from the same object returned by `register`:

```lua
adjustCounter.dispatch({ amount = 1 })
```

Direct dispatch runs the shared reducer authoritatively on the state `getState` returns and publishes it, without calling `acceptClient` or advancing a client sequence. Registering the same action ID twice is an error.
