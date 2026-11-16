# Runtimes

A runtime runs actions on one side. The server runtime works actions out on the stores and, once a frame, tells each client what changed. The client runtime applies its own actions at once and corrects them from the server's messages.

## Server

```lua
local server = Predictions.server({
	tables = tables,
	views = views,
	now = function(): number
		return workspace:GetServerTimeNow()
	end,
	isActor = function(player: Player, actor: unknown): boolean
		return actor == tostring(player.UserId)
	end,
	scope = defaultScope,
	actionTime = { maxAge = 0.5, maxLead = 0.05 },
} :: Predictions.ServerConfig<State, string, Player>)
```

| Field | Meaning |
| --- | --- |
| `tables` | The replicated tables, `name -> store`, with the same names as the clients'. |
| `views` | One view per table, no more and no less: `true` or a function `(client) -> rule`. See [Sync](SYNC.md#views). |
| `now()` | The server's time, a finite number. |
| `isActor(client, actor)` | Optional. Whether this client may act as this actor. Without it the actor must be the client itself. |
| `scope(world, actor, payload)` | Optional. The scope of actions that name none. Without it such an action sees every table whole. |
| `actionTime` | Optional. `{ maxAge, maxLead }`, both at least 0: how far a client's action time may be behind or ahead of `now()`. |

| Method | What it does |
| --- | --- |
| `server.allow(action, accept?)` | Clients may send this action. `accept(client, actor, payload)` is the game's own check. An action allowed twice errors. |
| `server.dispatch(action, actor, payload)` | The server's own action: no `allow`, no `validate`, no actor check, the time is `now()`. Returns whether it was applied, true also when it changes nothing. |
| `server.receive(client, envelope)` | An envelope a client sent. |
| `server.addClient(client)` | His next message holds everything he may see. Adding a client twice errors. |
| `server.removeClient(client)` | Drops his views, his sequence and any acknowledgement waiting for him. |
| `server.flush()` | The tick: one message per client that has something to be told, `{ [client]: message }`. Call it once a frame, outside any `Charm.batch`, and send each message to its client. |

`Client` is whatever the game uses to name a client, the `Player` in most games; the same value goes to `addClient`, `receive` and `removeClient`, and comes back as the keys of `flush`'s result.

### Receiving an action

`receive` checks, in order:

1. The envelope is a table with a whole sequence of at least 1.
2. The sequence is the next one from that client. A stale or duplicate one, or one that skips ahead, is warned about and ignored.
3. The sequence is now handled and acknowledged, whatever happens to the action. The acknowledgement goes out with his next message.
4. The action id is one the server allows (warned if not), and the envelope has a finite action time.
5. `validate(payload)`.
6. The actor: `isActor(client, actor)`, or without it `actor == client`.
7. `accept(client, actor, payload)`, when the action has one.
8. The action time is clamped, the action is worked out (scope, reduce, the write guard) and its changes are written in one `Charm.batch`. Then its effects are delivered.

Any step that fails simply ends there. The acknowledgement stands, so the client drops his prediction at the next message. An error in `validate`, `isActor`, `accept`, the scope or the reducer counts as a rejection and is warned about.

### Action time

A client stamps each action with its own `now()`. The server clamps that time to `now() - maxAge .. now() + maxLead` before the reducer sees it as `context.actionTime`. Without `actionTime` in the config the window is empty and the time is the server's `now()`. A game whose reducers read the action time should use a clock both sides share, such as `workspace:GetServerTimeNow()`.

## Client

```lua
local client = Predictions.client({
	tables = tables,
	send = function(envelope)
		remote:FireServer(envelope)
	end,
	now = function(): number
		return workspace:GetServerTimeNow()
	end,
	scope = defaultScope,
} :: Predictions.ClientConfig<State, string>)

remote.OnClientEvent:Connect(client.receive)
```

| Field | Meaning |
| --- | --- |
| `tables` | The replicated tables, with the same names as the server's. The runtime seals them: from then on only the library writes them. |
| `send(envelope)` | Sends an envelope to the server over a reliable, ordered transport. Forward it unchanged. |
| `now()` | The time actions are stamped with, a finite number. |
| `scope(world, actor, payload)` | Optional. The scope of actions that name none; the same as the server's. |

| Method | What it does |
| --- | --- |
| `client.dispatch(action, actor, payload)` | Validates and works the action out on what the stores show, writes the result at once, sends the envelope and delivers its effects. Returns whether it was applied. A dispatch from inside an effect subscribes it to nothing. |
| `client.receive(message)` | A message the server's `flush` made for this client. |

### Receiving a message

A message is handled in one `Charm.batch`, so readers wake once, after it:

1. Every change in it is applied to the server's side: to the entry kept aside for a key under prediction, straight into the store for any other key.
2. The pending actions the acknowledgement covers are dropped.
3. When some are still pending and either the acknowledgement advanced or the message touched a key a pending action read or wrote, the pending actions are worked out again, in order, on the server's side. Replays deliver no effects.
4. Each key under prediction is shown again: the replays' result when one wrote it, else the server's entry. It is written only when it differs from what the store shows, so a confirmed action whose result equals the prediction wakes nobody.

## Sequences and acknowledgements

Each client numbers its actions 1, 2, 3, and so on. The server handles them in that order only and acknowledges the highest sequence it has handled, accepted or not. The client keeps every action it sent until an acknowledgement covers it.

The client asserts that an acknowledgement is a whole number of at least 0, never moves backwards and never passes the highest sequence it sent. A failing assertion means the transport or the wiring is wrong.

Both directions must be reliable and ordered: a `RemoteEvent`, not an `UnreliableRemoteEvent`.

## The envelope

```lua
export type ActionEnvelope = {
	actionId: string,
	actor: any,
	payload: any,
	sequence: number,
	actionTime: number,
}
```

The client's `send` gets one per dispatch. Treat it as the library's: forward it without changing it.
