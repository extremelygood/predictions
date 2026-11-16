# Predictions documentation

Predictions keeps a game's state in stores, replicates them from the server to each client, and lets a client apply its own actions at once while the server confirms them.

## The model

1. **Stores.** State lives in keyed stores: entries under string keys, written with `set` or `patch`, every read current. `get(key)` follows one entry, `keys()` follows which keys exist, `all()` is the live table for plain loops, and `listen` tells each entry's change after the write. A single value is a `value` store.
2. **Tables.** One list, `name -> store`, says what is replicated. Both sides build it with the same names. On the server every table has a view: `true` (everyone sees every entry) or a rule that says which entries a client may see.
3. **The tick.** Once a frame the server builds one message per client: what changed in the entries he may see, and the acknowledgement of his actions. A client that already holds an entry is sent what changed inside it; one that newly sees it is sent it whole; one that stops seeing it is told it is gone. A client who joins newly sees everything in his view.
4. **Actions.** An action has `validate`, an optional `scope` (the part of the state it sees) and `reduce` (the new state of that part). It is dispatched for an actor: `dispatch(action, actor, payload)`, the same call on the client and the server. A client's action arrives in an envelope that carries the actor, and the server asks the game whether that client may act as it.
5. **Prediction.** On the client a dispatched action changes the stores at once. The library keeps the server's version of those entries aside. When messages arrive it replays what is still unconfirmed on top of the server's state, so a confirmed action wakes nobody, a rejected one snaps back, and a server change under a prediction is replayed over, not lost.

```text
client dispatch
    -> validate, scope, reduce on what the stores show; write the result at once
    -> send the envelope (sequence, actor, payload, action time)
server receive
    -> acknowledge the sequence; check the action, the actor and accept; scope, reduce, write
server flush (once a frame)
    -> per client: the acknowledgement and the changes he may see
client receive
    -> apply the changes; drop what is acknowledged; replay what is pending; show the result
```

## Read next

- [Stores](STORES.md): `keyed`, `value` and `index`, and the rules every store keeps.
- [Actions](ACTIONS.md): validate, scope and reduce; the write guard; payload types.
- [Runtimes](RUNTIMES.md): the server and client configs and methods, sequences and the action time.
- [Sync](SYNC.md): the tick, what a client is sent, joining and leaving, and what entries may hold.
- [Effects](EFFECTS.md): one-time presentation from accepted actions.
- [API reference](PUBLIC_API.md): every exported name and type.
- [Demo](demo/README.md): a small game with actors, a scope, a view and an index.

All Predictions objects use dot syntax: `server.flush()`, `store.get(key)`. Roblox instances keep their colon syntax.
