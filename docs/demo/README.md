# Demo: chests and purses

A small game with everything a bigger game adds to the [small one](../../README.md#a-small-game): an actor, a scope, a view and an index.

- Chests stand in the world, each holding some coins. Everyone sees every chest.
- Each player has a purse and is on a team. A player sees the purses of his own team only.
- `loot` empties a chest into the actor's purse. The actor is the player's own purse, keyed by his user id, and the server checks that he dispatches as himself.
- The server fills the chests again every half minute with its own `refill` action.
- The client totals its team's coins through an index of purses by team.

## Layout

```text
ReplicatedStorage
|-- Packages
|   |-- Charm
|   `-- Predictions
|-- Demo          (ModuleScript, 01-shared-action.md)
`-- DemoRemote    (RemoteEvent)
ServerScriptService
`-- DemoServer    (Script, 02-server.md)
StarterPlayer
`-- StarterPlayerScripts
    `-- DemoClient    (LocalScript, 03-client.md)
```

## Read in order

1. [`01-shared-action.md`](01-shared-action.md): the stores, the table list, the index and the two actions.
2. [`02-server.md`](02-server.md): views, the actor check, joining and leaving, the tick.
3. [`03-client.md`](03-client.md): the client runtime, reading the stores, dispatching.
4. [`04-sync-flow.md`](04-sync-flow.md): one `loot` from the click to the confirmation.
