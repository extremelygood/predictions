# Predictions documentation

Predictions provides client-predicted actions over server-authoritative state. A client applies an action locally for immediate feedback, sends the action to the server, and later replays any still-pending actions over the newest authoritative state.

The package is designed for top-level state that is already replicated with Charm Sync 0.4. Prediction is enabled per signal, so predicted and ordinary Charm signals can continue to use the same sync connection.

## How it fits together

An integration has three parts:

1. Define actions in shared code. Each action validates a payload and reduces the current state into a new state.
2. Register those actions with a client runtime and a server runtime.
3. Connect both runtimes through your action remote and the included Charm Sync adapter.

```text
client dispatch
    -> predict and publish locally
    -> send action envelope
    -> validate and reduce on server
    -> sync authoritative state and processed sequence
    -> reconcile and replay remaining actions on client
```

Reducers return complete state values. The runtime passes those values to your `publish` callback, which updates the stores used by the rest of the game.

## Requirements

- A shared Luau state shape on the client and server.
- A reliable, ordered client-to-server transport for action envelopes.
- Charm Sync 0.4 for authoritative state replication.
- Top-level state keys that match the names of the predicted Charm signals.

Predictions does not create remotes, install Charm Sync, or manage Charm Sync subscriptions. Those stay in game code.

## Read next

- [Demo](demo/README.md) — a complete predicted counter alongside a regular server-only value.
- [Actions](ACTIONS.md) — define reducers and validate or authorize dispatches.
- [Runtimes](RUNTIMES.md) — set up the client and server.
- [Charm Sync](CHARM_SYNC.md) — connect authoritative replication and reconciliation.
- [Effects](EFFECTS.md) — trigger local one-time presentation work from accepted actions.
- [API reference](PUBLIC_API.md) — the exported functions, objects, and payloads.

All Predictions objects use dot syntax:

```lua
local action = client.register(ActionDefinition)
action.dispatch(payload)
```

Roblox instances still use their normal colon syntax.
