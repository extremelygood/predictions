# Actions

An action is a shared definition of a change to the state. The client and the server run the same definition, so a prediction is worked out by the same rules the server applies.

## Define an action

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Predictions = require(ReplicatedStorage.Packages.Predictions)

type Purse = { coins: number, team: string }
type Chest = { coins: number }
type State = {
	purses: { [string]: Purse },
	chests: { [string]: Chest },
}

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
```

- `id` is the name sent over the network. It must be unique among the actions a server allows.
- `validate(payload)` says whether the payload has the shape the action takes. On the server it is all that stands between a client and `reduce`, so check every field the reducer reads.
- `scope(world, actor, payload)` returns the part of the state the action may see and change. It is optional.
- `reduce(state, payload, context)` returns the new state of that part, or nil to reject the action.

## The state

`State` is `{ [tableName]: { [key]: entry } }`, with a value table appearing as its value: `state.phase` is the phase itself.

## The scope

`world` is the whole state, read by key only: `world.purses[id]` is one entry, `world.phase` is a value table's value. Iterating `world` or one of its tables errors, so does writing it, and so does naming a table that does not exist. It can be read only while the scope runs: keep entries, not `world`. A scope returns plain tables holding the entries the action may see; an entry that does not exist is simply absent. Tables the scope leaves out are not touched.

An action without a scope uses the runtime's `scope`, the default for actions that name none. With neither, the action sees every table whole: the small-game case, where nothing needs a scope at all.

A typed `State` names every table. A scope that needs nothing of a table may give it as `{}`.

## The reducer

`reduce` is given the scope, the payload and a context:

```lua
export type ActionContext<Actor> = {
	actionTime: number,
	actor: Actor,
}
```

- `context.actor` is who acts, as named by the dispatch.
- `context.actionTime` is the time the action was dispatched. On the client it is the client's `now()`; on the server it is the client's time clamped to the server's window (see [Runtimes](RUNTIMES.md#action-time)). A replay reuses it.

What it returns:

- nil rejects the action. Nothing is written and no effect is delivered.
- A table missing from the result is unchanged.
- In a table the result holds, an entry that differs from the one given is written; a key missing that the state had is removed; a new key is added.
- Returning the state it was given, unchanged, accepts the action and changes nothing.

A reducer may:

- change the tables of its state in place and return the state, or return new tables;
- add entries that do not exist yet;
- emit [effects](EFFECTS.md).

A reducer must not:

- change an entry in place: build a new table for every entry it changes;
- read anything but its arguments: no stores, no globals, no clock, no randomness the payload does not carry. The client works it out again on the server's state each time a message touches what it read, so it must give the same result for the same arguments;
- yield.

`scope` and `reduce` run under `Charm.untracked`. An error in either rejects the action and is warned about.

## The write guard

A reducer may change only the entries it was given, and add entries that do not exist. Writing a key that exists in the store but was not in its state rejects the action with a warning. A reducer cannot touch what its scope did not give it.

## Payload types

The payload type comes from `reduce`'s annotation; `validate` takes `unknown`. So every `dispatch` is checked where it is called:

```lua
client.dispatch(loot, myId, { chest = "c1" }) -- fine
client.dispatch(loot, myId, { chest = 5 }) -- type error
```

The actor's type comes from `scope` or from `ActionContext<Actor>`, and is checked against the runtime's `Actor` the same way.

## Dispatching

```lua
local applied = client.dispatch(loot, myId, { chest = "c1" })
local applied = server.dispatch(loot, someId, { chest = "c1" })
```

The same call on both sides. On the client, an action that passes `validate` and `reduce` changes the stores at once, is sent, and `dispatch` returns true; a rejected one changes nothing, is not sent, and returns false. On the server, `dispatch` is the server's own action: no `allow`, no `validate`, no actor check. It returns whether it was applied.

## Allowing an action on the server

A client may send only the actions the server allows:

```lua
server.allow(loot, function(player: Player, actor: string, payload: { chest: string }): boolean
	return chestIsOpenTo(player, payload.chest)
end)
```

The optional `accept(client, actor, payload)` is the game's own check, after `validate` and the actor check. Use it for what the client must not be trusted with or cannot know. Rules on the shared state belong in the reducer, so the prediction follows them too.

## Effects on replay

Effects emitted while a reducer runs are delivered once the action is accepted: on the client when it is dispatched, on the server when it is applied. A replay on the client discards them, so an action that is worked out again does not repeat its sound. See [Effects](EFFECTS.md).
