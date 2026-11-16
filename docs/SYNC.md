# Sync

The server's stores are the state. Once a frame the server tells each client what changed in the part of it he may see, and the client's stores follow.

## The tick

```lua
RunService.Heartbeat:Connect(function()
	for player, message in server.flush() do
		remote:FireClient(player, message)
	end
end)
```

- Call `server.flush()` once a frame.
- Call it outside any `Charm.batch`. The views follow the stores through effects, and inside a batch those have not run yet; `flush` errors there.
- Send every message it returns to its client, unchanged, over a reliable `RemoteEvent`. It returns a message only for a client who has something to be told.
- On the client, hand every message to `client.receive`, in the order they came.

`flush` builds every message before it returns and then forgets what changed. A message the game drops is lost: the client's stores would miss those changes.

## What a client is sent

- For a table whose view is `true`: every entry.
- For a table whose view is a rule: the entries his rule lets him see.
- The acknowledgement of his actions: the highest sequence of his the server has handled.

Per entry:

- When it enters his view, or is created inside it, he is sent it whole.
- While it stays in his view, he is sent what changed inside it. A table that is a dictionary before and after is sent as the fields that differ, each one the same way; a removed field is marked as removed. A table that is an array before and after is sent as its new length and the elements that differ, each one the same way (unless every element differs: then it is sent whole). Anything else is sent whole: a number, a string, a table where there was none, an array that became a dictionary or the reverse.
- When it leaves his view, or is removed, he is told it is gone.

## What a client is never sent

- An entry his rule does not let him see. He is not told it exists, and not that it is gone.
- An entry created and removed between two ticks.
- A change that ends where it began: an entry written and written back before the tick.
- Anything of a table whose view or rule throws for him. That is warned about, and what he holds of the table is gone, until his view runs again.

## Views

```lua
views = {
	phase = true,
	purses = function(player: Player)
		-- teamOf is a store the server keeps and never replicates: user id -> team.
		local team = teamOf.get(tostring(player.UserId))
		return function(_key: string, purse: Purse): boolean
			return purse.team == team
		end
	end,
}
```

Every table needs a view, no more and no less.

- `true`: every client sees every entry.
- A function: called once per client, inside an effect, when he is added. It returns his rule, `(key, entry) -> boolean`. Because it runs in an effect it follows the stores it reads: above, it runs again when his team changes. Keep what it reads small; each run checks every entry of the table for him at the next tick.
- The rule is called at the tick for the entries that changed, and for every entry of the table when he joins or when his view ran again. It is not reactive. Read what it depends on in the view function, around it, so a change to that runs the view again; what the rule reads by itself is only looked at again when the entry it is asked about changes.
- A value table's single entry has the key `"v"`; a rule is called with it and the value.
- Visibility is decided at the tick, never at a write. Only a join and a view that ran again cost the entries of a table; the rest costs what changed.

## Joining and leaving

- `server.addClient(client)`: his next message holds everything he may see, whole. Call it once per client, when he joins.
- `server.removeClient(client)`: drops his views, his sequence and any acknowledgement waiting for him. Call it when he leaves.
- An action a client sends before he is added is handled as usual. Its acknowledgement waits and goes out with his first message.

## Confirmation

An action is worked out and written when the server receives it, and its acknowledgement goes into the client's next message. That message is built at the tick from the stores as they are then, so a confirmation always arrives in the message that holds the action's state, never ahead of it. When the client sees the acknowledgement it drops the action and shows the server's entries; when they equal its prediction nothing wakes.

## What entries may hold

Entries travel through a `RemoteEvent`, and nothing checks them on the way: that would walk every value every tick. Keep to values that survive the trip:

- Dictionaries with string keys. Use `tostring` for numeric ids.
- Arrays without holes, keys `1..n`. A table counts as an array when it has the key `1`, and as a dictionary otherwise (the empty table too). An array is sent as the elements that changed. A dictionary with a field named `"#"` cannot replace an array: it would arrive as an array change.
- No table mixing array and dictionary keys.
- No `false` as an entry: `false` means removal. A field inside an entry may be `false`.
- No NaN. NaN marks a removed field, so a field holding NaN arrives as removed.
- No functions, no metatables.
- Roblox data types such as `Vector3` and `CFrame` travel as values.

## Entries are replaced, never mutated

Write a new table for an entry each time it changes. Sub-tables that did not change may be shared with the old entry. The server finds what changed by comparing the entry it held before the tick's first write with the one it holds at the tick; an entry changed in place looks unchanged and is not sent. Charm also deep-freezes what its signals hold in Studio, so an entry that was read reactively errors when changed.
