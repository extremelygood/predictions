# Sync flow

Say this player's user id is `"7"`, he is on team red with an empty purse, and the chest `well` holds 5 coins. Both sides agree.

## 1. Dispatch

`client.dispatch(Demo.loot, "7", { chest = "well" })`:

- `validate` passes.
- The scope reads `purses["7"]` and `chests.well` from what the client's stores show.
- The reducer returns the purse with 5 coins and the chest with none.
- The client keeps the server's two entries aside, writes the two new ones, and sends:

```lua
{
	actionId = "loot",
	actor = "7",
	payload = { chest = "well" },
	sequence = 1,
	actionTime = 1234.5,
}
```

The coins effect prints 5 now. The action is pending until the server acknowledges sequence 1.

## 2. The server receives it

The sequence is the expected one, so it is acknowledged first. `loot` is allowed, `validate` passes, and `isActor` agrees that this player may act as `"7"`. The time is clamped to the server's window. The scope and reducer run on the server's stores, and the two entries are written in one batch. Both writes are marked for the next tick.

## 3. The tick

`flush` works each marked entry's change out once: the purse's `coins` field and the chest's `coins` field. Then, per client:

- This player: his acknowledgement, 1, and both changes. He holds his purse and the chest.
- A teammate: both changes, and no acknowledgement.
- A player on team blue: the chest's change only. He was never sent purse `"7"`, so he is told nothing of it.

## 4. The client receives its message

In one batch:

- The changes are applied to the entries kept aside, which become the server's new ones.
- Sequence 1 is acknowledged, so the action is dropped. Nothing is pending.
- The entries kept aside are shown. They equal the prediction, so nothing is written and nobody wakes.

Had the server rejected the action (another player emptied the chest first, say), the message would hold the acknowledgement and the chest's new state; the client would show the server's purse and chest, and the coins effect would print 0 again.

Had a message arrived before the acknowledgement with a change to the chest, the client would have worked `loot` out again on it, at once, and shown that.
