# Effects

Effects are optional, local events emitted by an accepted action. They are useful for one-time presentation such as sounds, particles, camera recoil, or controller callbacks.

Effects are never replicated by Predictions. A shared effect definition has separate listeners in each environment.

## Define and connect an effect

```lua
local WeaponFired = Predictions.defineEffect({
    name = "WeaponFired",
})

local connection = WeaponFired.connect(function(payload)
    weaponPresentation.playMuzzleFlash(payload.toolId)
end)
```

Disconnect the listener when it is no longer needed:

```lua
connection.disconnect()
```

## Emit from a reducer

```lua
local FireWeapon = Predictions.defineAction({
    id = "FireWeapon",
    validate = validateFireWeapon,

    reduce = function(state, payload)
        local nextState = consumeAmmo(state, payload)
        if nextState == nil then
            return nil
        end

        WeaponFired.emit({
            toolId = payload.toolId,
        })

        return nextState
    end,
})
```

`emit` records the effect while the reducer runs. Listeners are deferred until an actual dispatch is accepted. Effects collected during reconciliation replay are discarded, so replaying a pending action does not repeat its sound or particles.

Each listener runs in its own deferred task. A listener may yield or fail without holding up dispatch or preventing the other listeners from starting. Listener order is not guaranteed.

Only call `emit` from inside a reducer. Calling it elsewhere raises an error. Since a predicted effect cannot be undone if the server later rejects the action, use effects for consequences that are safe to play once and finish naturally.
