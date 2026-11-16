# Client

```lua
--!strict
-- StarterPlayerScripts.DemoClient

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Charm = require(ReplicatedStorage.Packages.Charm)
local Predictions = require(ReplicatedStorage.Packages.Predictions)
local Demo = require(ReplicatedStorage.Demo)

local remote = ReplicatedStorage.DemoRemote :: RemoteEvent
local me = tostring(Players.LocalPlayer.UserId)

local client = Predictions.client({
	tables = Demo.tables,
	send = function(envelope: Predictions.ActionEnvelope)
		remote:FireServer(envelope)
	end,
	now = function(): number
		return workspace:GetServerTimeNow()
	end,
} :: Predictions.ClientConfig<Demo.State, string>)

remote.OnClientEvent:Connect(client.receive)

-- My coins, shown again whenever my purse changes, a prediction included.
Charm.effect(function()
	local purse = Demo.purses.get(me)
	print("coins:", if purse ~= nil then purse.coins else 0)
end)

-- My team's coins, followed through the index: it wakes when a teammate comes, goes or changes.
Charm.effect(function()
	local purse = Demo.purses.get(me)
	if purse == nil then
		return
	end
	local total = 0
	for key in Demo.teams.get(purse.team) do
		local mate = Demo.purses.get(key)
		total += if mate ~= nil then mate.coins else 0
	end
	print("team coins:", total)
end)

-- A chest's button, say.
local function onLoot(chest: string)
	client.dispatch(Demo.loot, me, { chest = chest })
end

onLoot("well")
```

- The runtime seals `Demo.purses` and `Demo.chests` on this side: only messages and dispatches write them.
- The first effect reads one entry with `get`, so it wakes only when this player's purse changes. It shows a prediction at once and wakes again only if the server's result differs from it.
- The second effect follows the index key of his team and each teammate's purse. It runs again when a teammate joins, leaves or changes.
- `dispatch` names the actor: this player's purse. `loot` on an empty chest is rejected on the client already: nothing is written or sent, and `dispatch` returns false.
