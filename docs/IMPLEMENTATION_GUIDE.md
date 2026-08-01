# Implementation Guide

## Suggested package shape

```text
Prediction/
├── init.luau
├── action.luau
├── effect.luau
├── effectScope.luau
├── client.luau
├── server.luau
└── types.luau

PredictionCharmSync/
├── init.luau
├── client.luau
└── server.luau
```

The private structure may differ. Preserve the public API described in the other documents.

## Closure-based public objects

Every public object returned by the library must expose functions as closures. Calls use dot syntax and functions must not depend on an implicit `self` parameter. This applies to runtimes, bound actions, effects, adapter objects, and returned connections.

```lua
local boundAction = client.register(ActionDefinition)
boundAction.dispatch(payload)

local connection = Effect.connect(listener)
connection.disconnect()
```

## Action registry

`defineAction` creates an immutable, stateless definition containing `id`, `validate`, and `reduce`.

Each runtime keeps an internal action-ID registry. Duplicate IDs fail during registration. The network sends IDs and payloads, never functions.

## Effect scope

`defineEffect` creates a local signal-like definition containing a diagnostic `name`, an `emit` closure, and listener connections.

Calling an effect's `emit` closure during reduction appends its delivery closure and payload to the currently active effect collector.

The collector should be scoped safely:

- support nested reducer execution through a stack or equivalent mechanism;
- always restore the previous scope after errors;
- reject emission when no reducer scope is active;
- assume reducers do not yield.

The runtime decides whether collected effects are scheduled or discarded. Each captured listener is scheduled independently with `task.defer`; listener errors use native task error reporting and listener completion order is not guaranteed.

## Client dispatch

When a bound client action is dispatched:

1. validate the payload;
2. create sequence and time metadata;
3. run the reducer against predicted state while collecting effects;
4. return `false` and discard effects if the reducer returns `nil`;
5. queue the action;
6. store and publish the returned predicted state;
7. schedule collected local effect listeners;
8. send the action envelope;
9. return `true`.

Do not allocate a sequence for locally rejected actions.

## Client reconciliation

When authoritative state and a cumulative processed sequence arrive, treat them as one reconciliation transaction:

1. replace authoritative state;
2. remove acknowledged pending actions;
3. replay remaining pending actions in order;
4. ignore `nil` results for state reconstruction while retaining those pending entries until acknowledgement;
5. discard every effect collected during replay;
6. publish the final predicted state exactly once.

Never publish an intermediate state after removing acknowledged actions but before authoritative replacement and pending replay are complete.

## Server receipt

For the next expected client sequence:

1. validate the envelope;
2. look up the action;
3. validate the payload;
4. run optional `acceptClient`;
5. run the reducer against authoritative state while collecting effects;
6. publish accepted state and advance the processed sequence in the same batching boundary;
7. schedule local effects only when the reducer returns a state;
8. flush replication so the authoritative patch and watermark are sent together;
9. send an acknowledgement-only payload only when the flush produced no causally relevant predicted patch.

Rejected actions still advance the processed sequence, but their acknowledgement-only payload must use the same ordered flush path rather than an independent acknowledgement channel.

Malformed, unknown, unauthorized, and reducer-rejected actions at the expected sequence must still advance the cumulative acknowledgement.

Stale actions are not applied. Sequence gaps are not applied. Version one may assume reliable ordered transport.

## Direct server dispatch

A bound server action's `dispatch(payload)` should:

1. validate payload;
2. run the reducer while collecting effects;
3. discard effects and return `false` on `nil`;
4. publish accepted state;
5. schedule local server-side effect listeners;
6. return `true`.

It must not call `acceptClient`, create a client sequence, or change acknowledgement state.

## Charm Sync invariants

- Predicted signals are opt-in.
- Mixed predicted and regular payloads are supported.
- Regular signals are forwarded unchanged.
- Acknowledgements are cumulative authoritative-state watermarks.
- A watermark may acknowledge only actions whose accepted results are already represented by the delivered authoritative state.
- The corresponding patch and watermark travel in the same payload; there is no separate acknowledgement channel.
- State mutation and watermark advancement share the same batching boundary.
- The client applies predicted patches, removes acknowledged actions, replays pending actions, and publishes once.
- A rejected or no-op action can be cleared through an acknowledgement-only payload only after the flush confirms no relevant patch remains pending.
- The normal patch path and acknowledgement-only fallback must not race.
- Effects are never included in Charm Sync payloads.

## Required behavioral tests

1. client dispatch predicts and sends one sequenced envelope;
2. locally rejected action is neither queued nor sent;
3. an accepted client dispatch fires its local effects once;
4. a rejected client dispatch fires no effects;
5. reconciliation replay fires no effects;
6. accepted server execution updates authoritative state and fires server-local effects once;
7. rejected client action is still acknowledged;
8. acknowledgement removes all pending actions up to that sequence;
9. remaining pending actions replay over corrected authoritative state;
10. an accepted state-changing action sends its authoritative predicted patch and watermark in one payload;
11. the client publishes exactly once while applying a patch and watermark;
12. no observable state exists where an action has been removed before its authoritative result is applied;
13. no observable state exists where an authoritative result is published while the same action is still replayed as pending;
14. acknowledgement-only payload clears a rejected or no-op prediction;
15. acknowledgement-only fallback is not sent when the normal flush emitted a relevant patch;
16. delayed or separately delivered acknowledgement metadata is not supported by the adapter API;
17. direct server dispatch uses the same reducer without changing client sequence state;
18. stale and gap sequences are not applied;
19. duplicate action IDs fail registration;
20. effect emission outside a reducer fails clearly;
21. multiple effect listeners connect and disconnect correctly;
22. a mixed Charm payload reconciles predicted signals and forwards regular signals unchanged;
23. no effect data is serialized into action or Charm Sync payloads.
24. a yielding effect listener does not block dispatch or another listener;
25. a failing effect listener does not prevent another listener from running;
26. a re-entrant listener cannot overtake the action envelope or replication commit that scheduled it;
27. disconnecting after scheduling does not cancel a captured delivery.

## Simplicity constraints

Do not add until required by a concrete use case:

- effect networking;
- effect registries keyed by network IDs;
- middleware;
- reducer classes or inheritance;
- cancellation tokens;
- custom schedulers;
- automatic action discovery;
- multiple acknowledgement strategies;
- generalized store adapters.
