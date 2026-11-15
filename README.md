# Predictions

Predictions is a small Luau library for running an action immediately on the client, validating it on the server, and reconciling it with authoritative Charm state.

The client and server share the same action reducer. This keeps prediction behavior close to the game logic it represents, while the included Charm Sync 0.4 adapter handles authoritative updates and pending-action replay.

## Setup

With Wally, add the package under the `Predictions` alias:

```toml
[dependencies]
Predictions = "extremelygood/predictions@0.2.0"
```

Mount it at `ReplicatedStorage.Packages.Predictions`. Predictions does not include Charm or Charm Sync, so games using the adapter need to provide their own Charm Sync 0.4 installation.

Start with the [documentation](docs/README.md), or follow the [counter demo](docs/demo/README.md) for a complete client/server example.

## Development

Install the tools in `rokit.toml`, then build the test place:

```sh
rojo build dev.project.json -o predictions-tests.rbxlx
```

Open `predictions-tests.rbxlx` in Studio and press **Play**. The server output will report whether the test suite passed.
