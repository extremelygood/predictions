# Predicted and Regular Store Demo

This demo shows the smallest useful integration between Predictions and Charm Sync 0.4. It uses two independent mock stores:

| Sync key | Initial value | Behavior |
| --- | --- | --- |
| `counter` | `0` | Predicted locally when the client dispatches `AdjustCounter`, then reconciled with the server. |
| `serverStatus` | `"Waiting"` | Never predicted. It changes only when an ordinary Charm Sync update arrives from the server. |

Both values use the same Charm Sync subscription and the same server-to-client payload. The adapter removes `counter` updates for reconciliation and returns `serverStatus` updates to normal Charm Sync.

## Requirements

The consuming game supplies:

- Predictions;
- Charm and Charm Sync 0.4;
- one `RemoteEvent` named `PredictionAction` for client action envelopes;
- one `RemoteEvent` named `StateSync` for reconciliation payloads; and
- one `RemoteEvent` named `StateReady` through which a client requests its subscriptions.

Predictions intentionally does not install Charm or Charm Sync itself. This example assumes all packages are available beneath `ReplicatedStorage.Packages` and all three remotes are beneath `ReplicatedStorage.Remotes`.

## Suggested game layout

The snippets in this directory represent the following small game layout. They remain documentation examples; this repository does not need these runtime files to build the library.

```text
ReplicatedStorage
|-- Packages
|   |-- Charm
|   |-- CharmSync
|   `-- Predictions
|-- Remotes
|   |-- PredictionAction
|   |-- StateReady
|   `-- StateSync
`-- Demo
    |-- AdjustCounter
    `-- Stores
        |-- CounterStore
        `-- ServerStatusStore
ServerScriptService
`-- DemoServer
StarterPlayer
`-- StarterPlayerScripts
    `-- DemoClient
```

## Read in order

1. [`01-shared-action.md`](01-shared-action.md) defines the two stores and the shared action.
2. [`02-server.md`](02-server.md) creates the authoritative runtime and owns Charm Sync delivery.
3. [`03-client.md`](03-client.md) predicts counter changes and applies regular status updates.
4. [`04-sync-flow.md`](04-sync-flow.md) follows one dispatch through prediction and reconciliation.

The snippets use dot syntax for every Predictions object. Roblox instances continue using their native colon syntax.
