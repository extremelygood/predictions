# Server

```lua
--!strict
-- ServerScriptService.DemoServer

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Predictions = require(ReplicatedStorage.Packages.Predictions)
local Demo = require(ReplicatedStorage.Demo)

local remote = ReplicatedStorage.DemoRemote :: RemoteEvent

-- Not replicated: each player's team, by user id.
local teamOf = Predictions.keyed() :: Predictions.Keyed<string, string>

local server = Predictions.server({
	tables = Demo.tables,
	views = {
		chests = true,
		-- A player sees the purses of his own team.
		purses = function(player: Player)
			local team = teamOf.get(tostring(player.UserId))
			return function(_key: string, purse: Demo.Purse): boolean
				return purse.team == team
			end
		end,
	},
	now = function(): number
		return workspace:GetServerTimeNow()
	end,
	-- A player acts as his own purse.
	isActor = function(player: Player, actor: unknown): boolean
		return actor == tostring(player.UserId)
	end,
	actionTime = { maxAge = 0.5, maxLead = 0.05 },
} :: Predictions.ServerConfig<Demo.State, string, Player>)

server.allow(Demo.loot)

Demo.chests.patch({ well = { coins = 5 }, tower = { coins = 8 } })

Players.PlayerAdded:Connect(function(player: Player)
	local team = if #Players:GetPlayers() % 2 == 0 then "red" else "blue"
	teamOf.set(tostring(player.UserId), team)
	Demo.purses.set(tostring(player.UserId), { coins = 0, team = team })
	server.addClient(player)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	server.removeClient(player)
	Demo.purses.set(tostring(player.UserId), nil)
	teamOf.set(tostring(player.UserId), nil)
end)

remote.OnServerEvent:Connect(function(player: Player, envelope: unknown)
	server.receive(player, envelope)
end)

RunService.Heartbeat:Connect(function()
	for player, message in server.flush() do
		remote:FireClient(player, message)
	end
end)

-- Every half minute the chests fill again.
task.spawn(function()
	while true do
		task.wait(30)
		for chest in Demo.chests.keys() do
			server.dispatch(Demo.refill, "server", { chest = chest, coins = 5 })
		end
	end
end)
```

- `teamOf` is a store the server never replicates. The purse view reads it, so a player's view runs again only when his team changes, not every time a purse's coins do.
- The rule is called at each tick for the purses that changed, and for every purse when the player joins or his view runs again.
- `isActor` lets a player act as his own purse only. An envelope naming another purse is acknowledged and ignored, and the sender's prediction rolls back.
- His team is written before `server.addClient`, so his view starts from it. His first message, at the next tick, holds every chest and the purses of his team, his own included.
- `flush` runs once a frame, outside any batch, and every message it returns is sent as it is.
- `server.dispatch` is the server's own action: no `allow`, no `validate`, no actor check.
