# Predictions

Predictions keeps a Roblox game's state in stores that the server replicates to each client, and lets a client apply its own actions at once while the server confirms them.

## A small game

One score everyone sees, and one action that adds to it. The client shows the points the moment the button is pressed; the server works the same action out and sends the result to everyone.

```lua
-- ReplicatedStorage.Score: required by the server and by each client, so each side has its own store.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Predictions = require(ReplicatedStorage.Packages.Predictions)

type State = { score: number }

local score = Predictions.value(0)
local tables: Predictions.Tables = { score = score }

local addPoints = Predictions.defineAction({
	id = "addPoints",
	validate = function(points: unknown): boolean
		return points == 1 or points == 2 or points == 3
	end,
	reduce = function(state: State, points: number): State?
		return { score = state.score + points }
	end,
})

return { score = score, tables = tables, addPoints = addPoints }
```

```lua
-- ServerScriptService.Server
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Predictions = require(ReplicatedStorage.Packages.Predictions)
local Score = require(ReplicatedStorage.Score)
local remote = ReplicatedStorage.Remote :: RemoteEvent

local server = Predictions.server({ tables = Score.tables, views = { score = true }, now = os.clock })
server.allow(Score.addPoints)
Players.PlayerAdded:Connect(server.addClient)
Players.PlayerRemoving:Connect(server.removeClient)
remote.OnServerEvent:Connect(server.receive)
RunService.Heartbeat:Connect(function()
	for player, message in server.flush() do
		remote:FireClient(player, message)
	end
end)
```

```lua
-- A LocalScript inside a TextButton
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Predictions = require(ReplicatedStorage.Packages.Predictions)
local Score = require(ReplicatedStorage.Score)
local remote = ReplicatedStorage.Remote :: RemoteEvent
local button = script.Parent :: TextButton

local client = Predictions.client({
	tables = Score.tables,
	send = function(envelope)
		remote:FireServer(envelope)
	end,
	now = os.clock,
})
remote.OnClientEvent:Connect(client.receive)

button.Activated:Connect(function()
	client.dispatch(Score.addPoints, Players.LocalPlayer, 1)
end)
```

The action has no scope, so it sees every table whole. The server has no `isActor`, so a client may only act as himself: the actor of each dispatch is `Players.LocalPlayer`. The same scripts run as a test in `tests/server/EndToEnd.spec.luau`.

## Reading state

Every store is read the same way on the server and the client. On a client the stores show the server's state with his unconfirmed actions on top.

```lua
local Charm = require(ReplicatedStorage.Packages.Charm)

Score.score.get() -- a value's value

local purses = Predictions.keyed() :: Predictions.Keyed<string, { coins: number }>
purses.get("123") -- one entry, or nil
purses.keys() -- the set of keys, { [key] = true }
for key, purse in purses.all() do -- every entry, for a plain loop
	print(key, purse.coins)
end

-- Reactive code follows single entries: this effect wakes only when purse "123" changes.
Charm.effect(function()
	print(purses.get("123"))
end)

-- One scope per entry, made when its key comes and cleaned up when it goes.
Charm.observe(purses.keys, function(_, key)
	print("purse", key, "came")
	return function()
		print("purse", key, "went")
	end
end)

-- Each change with what it was, after the write.
purses.listen(function(key, purse, previous)
	print(key, previous, "->", purse)
end)
```

`all()` is not reactive: called directly inside an effect or a computed it errors, naming `keys()` and `get()`. See [Stores](docs/STORES.md).

## A bigger game adds

- **An actor.** Each dispatch names who acts: `dispatch(action, actor, payload)`, the same call on the client and the server, and the reducer reads it as `context.actor`. A player who controls several things picks one per dispatch. The server's `isActor(client, actor)` says whether a client may act as that actor; an action sent as an actor he may not use is rejected and rolled back on his side. See [Actions](docs/ACTIONS.md).
- **A scope.** An action's `scope(world, actor, payload)` returns the entries it may see and change, read by key from `world`. A reducer may not write an entry it was not given. A runtime's `scope` is the default for actions that name none. See [Actions](docs/ACTIONS.md).
- **Views.** Each table's view on the server says which entries a client may see: `true`, or a function that returns his rule. He is sent an entry whole when it enters his view, its changes while it stays, and that it is gone when it leaves. He is never told of the rest. See [Sync](docs/SYNC.md).
- **An index.** `Predictions.index(store, keysOf)` is a lookup kept with every write, such as the members of each team. See [Stores](docs/STORES.md).

The [demo](docs/demo/README.md) is a small game with all four.

## Install

With Wally:

```toml
[dependencies]
Predictions = "extremelygood/predictions@0.2.0"
Charm = "littensy/charm@0.11.1"
```

Predictions depends on [Charm](https://github.com/littensy/charm) and requires it as its own Wally dependency. The game must resolve the same Charm package as the library: depend on the very version above, so Wally installs one copy. Two copies of Charm do not share reactivity, so effects made with the game's Charm would not follow the library's stores. Mount the packages at `ReplicatedStorage.Packages`.

Start with the [documentation](docs/README.md).

## Development

The test place needs Charm at `ReplicatedStorage.Packages.Charm`, beside `Predictions`. Install the tools in `rokit.toml`, then, in the library's folder:

```sh
wally install
rojo build dev.project.json -o predictions-tests.rbxlx
```

`wally install` puts Charm in `Packages/`, which `dev.project.json` mounts at `ReplicatedStorage.Packages` beside the library's `src`. Open `predictions-tests.rbxlx` in Studio and press **Play**. The server output reports whether the tests passed.
