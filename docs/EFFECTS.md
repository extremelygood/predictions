# Effects

Effects are local events an accepted action emits. Use them for one-time presentation: a sound, particles, a camera kick.

Effects are never replicated. A shared effect definition has its own listeners on each side.

## Define and connect an effect

```lua
local Looted = Predictions.defineEffect({ name = "Looted" }) :: Predictions.Effect<{ chest: string, coins: number }>

local connection = Looted.connect(function(payload)
	playCoinSound(payload.chest, payload.coins)
end)

connection.disconnect()
```

## Emit from a reducer

```lua
reduce = function(state: State, payload: { chest: string }, context: Predictions.ActionContext<string>): State?
	local purse = state.purses[context.actor]
	local chest = state.chests[payload.chest]
	if purse == nil or chest == nil or chest.coins == 0 then
		return nil
	end
	Looted.emit({ chest = payload.chest, coins = chest.coins })
	return {
		purses = { [context.actor] = { coins = purse.coins + chest.coins, team = purse.team } },
		chests = { [payload.chest] = { coins = 0 } },
	}
end,
```

`emit` records the effect while the reducer runs. It is delivered only when the action is accepted and written: on the client when it is dispatched, on the server when it is applied. A rejected action delivers nothing. A replay on the client discards what it emits, so an action worked out again does not repeat its sound.

Each listener runs in its own deferred task. A listener may yield or fail without holding up the action or the other listeners. Listener order is not guaranteed.

`emit` outside a reducer errors. A predicted effect cannot be taken back when the server later rejects the action, so use effects for things that are fine to have happened once.
