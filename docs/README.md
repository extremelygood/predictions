# Predicted Actions Library

## Goal

Create a small reusable Luau library for client-predicted actions over authoritative state.

The library should allow one shared action definition to be:

- predicted immediately by a client;
- confirmed or rejected by the server;
- replayed after authoritative corrections;
- dispatched directly by server code through the same reducer.

Simplicity is the primary design constraint.

## API style

All library-created objects use closure-based APIs. Public functions are called with dot syntax and do not receive an implicit `self` argument.

```lua
local action = client.register(ActionDefinition)
action.dispatch(payload)

local connection = Effect.connect(listener)
connection.disconnect()
```

Do not expose colon-style methods such as `action:dispatch(payload)`. Roblox built-in APIs may still use their native colon syntax where required.

## Core concepts

The public model has four pieces:

1. **Actions** describe deterministic state transitions.
2. **Effects** describe local, one-time consequences emitted by actions.
3. **Runtimes** execute actions on the client or server.
4. **The Charm Sync adapter** reconciles selected predicted signals while letting all other signals use ordinary Charm Sync.

Reducers calculate absolute state. Publishers expose the final state to the game's stores.

Effects are local only. The library must not serialize or replicate them.

## Scope for version one

Include:

- shared action definitions;
- shared effect definitions;
- client prediction and pending-action replay;
- authoritative server execution;
- cumulative acknowledgements;
- direct server dispatch through the same action reducer;
- opt-in Charm signal prediction;
- ordinary Charm Sync passthrough for all other signals;
- strict Luau types and focused behavioral tests.

Do not include:

- automatic effect networking;
- middleware pipelines;
- action inheritance;
- automatic action discovery;
- retries for unreliable transports;
- generalized change-set optimization;
- materialization or frame-based projection.

## Core reconciliation guarantee

A processed client sequence is an authoritative-state watermark, not an independent acknowledgement. The client may remove pending actions only while applying authoritative state that already reflects every accepted action through that sequence.

The Charm Sync adapter therefore delivers the relevant authoritative patch and its processed sequence together and publishes the reconciled predicted state only once.

## Documents

- [`demo/README.md`](demo/README.md) walks through a predicted counter and a regular server-status store sharing one Charm Sync connection.
- [`PUBLIC_API.md`](PUBLIC_API.md) gives the compact intended public surface.
- [`ACTIONS.md`](ACTIONS.md) defines action behavior and usage.
- [`EFFECTS.md`](EFFECTS.md) defines local effect behavior and usage.
- [`RUNTIMES.md`](RUNTIMES.md) covers client and server setup.
- [`CHARM_SYNC.md`](CHARM_SYNC.md) covers the optional Charm Sync adapter.
- [`IMPLEMENTATION_GUIDE.md`](IMPLEMENTATION_GUIDE.md) lists internal invariants and required tests.
