# Shared stores and actions

The server and each client require this module, so each side has its own stores. Both build the same table list, so the names on the wire match.

```lua
--!strict
-- ReplicatedStorage.Demo

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Predictions = require(ReplicatedStorage.Packages.Predictions)

export type Purse = { coins: number, team: string }
export type Chest = { coins: number }
export type State = {
	purses: { [string]: Purse },
	chests: { [string]: Chest },
}

-- Keyed by the player's user id, as a string.
local purses = Predictions.keyed() :: Predictions.Keyed<string, Purse>
local chests = Predictions.keyed() :: Predictions.Keyed<string, Chest>
local tables: Predictions.Tables = { purses = purses, chests = chests }

-- The purses of each team.
local teams = Predictions.index(purses, function(purse: Purse): { string }
	return { purse.team }
end)

-- The actor empties a chest into his purse.
local loot = Predictions.defineAction({
	id = "loot",
	validate = function(payload: unknown): boolean
		return type(payload) == "table" and type((payload :: any).chest) == "string"
	end,
	scope = function(world: State, actor: string, payload: { chest: string }): State
		return {
			purses = { [actor] = world.purses[actor] },
			chests = { [payload.chest] = world.chests[payload.chest] },
		}
	end,
	reduce = function(state: State, payload: { chest: string }, context: Predictions.ActionContext<string>): State?
		local purse = state.purses[context.actor]
		local chest = state.chests[payload.chest]
		if purse == nil or chest == nil or chest.coins == 0 then
			return nil
		end
		return {
			purses = { [context.actor] = { coins = purse.coins + chest.coins, team = purse.team } },
			chests = { [payload.chest] = { coins = 0 } },
		}
	end,
})

-- The server fills a chest again.
local refill = Predictions.defineAction({
	id = "refill",
	validate = function(payload: unknown): boolean
		return type(payload) == "table" and type((payload :: any).chest) == "string"
	end,
	scope = function(world: State, _actor: string, payload: { chest: string, coins: number }): State
		return { purses = {}, chests = { [payload.chest] = world.chests[payload.chest] } }
	end,
	reduce = function(state: State, payload: { chest: string, coins: number }): State?
		state.chests[payload.chest] = { coins = payload.coins }
		return state
	end,
})

return {
	purses = purses,
	chests = chests,
	tables = tables,
	teams = teams,
	loot = loot,
	refill = refill,
}
```

- `loot` names a scope: the actor's purse and the chest its payload names. Its reducer may change those two entries and nothing else; writing another existing purse would be rejected by the write guard.
- `refill` is only ever dispatched by the server. The server never allows it, so an envelope that names it is warned about and rejected. Its scope gives `purses` as `{}`: the typed `State` names every table, and the action needs none of the purses. Its reducer changes the chests table in place and returns the state, which is allowed; the entry itself is a new table.
- `teams` is kept with every write to `purses`, on each side. On a client it holds the purses that client was sent.
- Payload types come from the reducers: `client.dispatch(Demo.loot, me, { chest = 5 })` is a type error.
