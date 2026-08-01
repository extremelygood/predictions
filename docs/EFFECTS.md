# Effect Definitions

Effects represent local, one-time consequences that do not reasonably belong in durable state.

Examples include:

- sounds;
- muzzle flashes;
- camera recoil;
- short particles;
- local presentation callbacks.

Effects are optional. Ordinary actions do not need them.

## Definition

The configuration is a table so more options can be added later without changing the call shape.

```lua
local WeaponFired = Prediction.defineEffect({
    name = "WeaponFired",
})
```

`name` is for diagnostics and debugging. Effects are not identified or decoded over the network.

## Connecting listeners

Scripts connect directly to the effect definition:

```lua
local connection = WeaponFired.connect(function(payload)
    weaponPresentation.playMuzzleFlash(payload)
end)
```

Multiple listeners may connect independently.

```lua
WeaponFired.connect(function(payload)
    audioController.playWeaponSound(payload)
end)

WeaponFired.connect(function(payload)
    recoilController.apply(payload)
end)
```

The returned connection exposes `disconnect()`.

No runtime registration API is needed for effects.

## Emitting from a reducer

Effects are callable inside reducers:

```lua
local FireWeapon = Prediction.defineAction({
    id = "FireWeapon",
    validate = validateFireWeapon,

    reduce = function(state, payload)
        local nextState = consumeAmmo(state, payload)

        if nextState == nil then
            return nil
        end

        WeaponFired({
            characterId = payload.characterId,
            toolId = payload.toolId,
        })

        return nextState
    end,
})
```

Calling an effect does not immediately invoke listeners. It records the effect in the current reducer execution.

After reduction:

- an accepted real client dispatch fires the client-side listeners;
- an accepted server execution fires the server-side listeners;
- a rejected action discards collected effects;
- reconciliation replay discards collected effects.

This prevents sounds and particles from replaying every time pending actions are recalculated.

## Local-only behavior

The library must never automatically serialize, route, or replicate effects.

The same shared effect module may have different listeners in the client and server environments, but those listeners are local to that environment.

A server-originated action therefore fires only server-side effect listeners. Other clients receive nothing unless the game explicitly uses its own networking or represents the event through replicated state.

## Constraints

- Emitting outside an active reducer should raise a clear error containing the effect name.
- Reducers must not yield while effect collection is active.
- Effect payloads should be treated as immutable descriptions.
- The library does not reverse effects if a predicted action is later rejected.
- Use effects only for consequences that are safe to happen once and end naturally.
