# Stores

A store holds entries under keys, and each entry is followed on its own. No signal ever holds a whole table, so a write costs the entries it changes and wakes only their readers.

The same stores are used on the server, on the client and for state that is never replicated.

## Keyed stores

```lua
local purses = Predictions.keyed() :: Predictions.Keyed<string, Purse>
```

| Member | What it does |
| --- | --- |
| `get(key)` | The entry, or nil. |
| `keys()` | The set of keys, `{ [key] = true }`, frozen. |
| `all()` | The live table of every entry, `{ [key] = entry }`. Read it; never change or keep it. |
| `set(key, value)` | Writes one entry. `nil` removes it. |
| `patch(changes)` | Writes several entries. `false` removes one. |
| `listen(listener)` | Calls `listener(key, value, previous)` for each written entry, after the write. Returns a disconnect function. |

Keys of a replicated store are strings. Use `tostring` for numeric ids such as user ids.

### Reading

- `get(key)` read inside an effect or a computed follows that entry alone. While the key does not exist it follows the coming and going of keys, so the reader wakes when the entry appears. Read with nothing reactive running, it subscribes nothing.
- `keys()` read reactively follows the coming and going of keys, not the entries' values. A new set is made only after a key came or went, so a set once handed out never changes. That makes it safe for `Charm.observe`, which iterates it while its callbacks may write:

  ```lua
  Charm.observe(purses.keys, function(_, key)
  	-- runs once per key; return a cleanup for when the key goes
  end)
  ```

  The first argument is `true`; the key is the second.
- `all()` is not reactive. It errors when it is called where a subscription is expected, directly inside an effect or a computed, and the error names `keys()` and `get()`. Inside an `observe` callback, an `effectScope`, under `Charm.untracked` or in plain code it is fine. (It tells the places apart by the shape of Charm's running node. A Charm whose nodes are shaped differently makes `all()` never error, which is the safe side.)

### Writing

- `set` and `patch` are the only writes. Each is one `Charm.batch`, so readers wake once, after it.
- A value identical (`==`) to the one held is no write.
- An entry may never be `false`. `set(key, false)` errors; in `patch`, `false` means remove.
- Write a new table, never change an entry in place. Charm deep-freezes what its signals hold in Studio, and an entry read reactively is held by a signal. The runtimes rely on it too: a change is found by comparing the entry before and after.
- When a key comes or goes, the readers of `keys()` wake before that entry's own readers, so an `observe` over the keys drops a gone key's scope before that key's effects run again.

### `listen`

`listen(listener)` calls `listener(key, value, previous)` for each written entry:

- after the outermost `Charm.batch` around the write has ended, not inside it;
- in the order the entries were first written;
- once per key for several writes to it before then, with `previous` from before the first and `value` after the last;
- not at all when the entry ends where it began.

Listeners run with nothing reactive active. They may write stores; those writes are delivered under the same rules, after the current listeners. A listener must not yield. An error in one is warned about and the others still run.

## Value stores

```lua
local phase = Predictions.value("waiting")
phase.get()
phase.set("playing")
phase.listen(function(value, previous) end)
```

A value store holds one value. `get()` follows it when read reactively. A value may not be `false`; it may be `nil` (`Predictions.value(nil :: Phase?)`), which is no entry. Underneath it is a keyed store with one entry under the key `"v"`, so it follows the same rules, and on the wire and in a view rule its key is `"v"`.

## Indexes

```lua
local byTeam = Predictions.index(purses, function(purse: Purse, _key: string): { string }
	return { purse.team }
end)

byTeam.get("red") -- the frozen set of purse keys found under "red"
byTeam.first("red") -- one of them, or nil
```

`index(source, keysOf)` is a lookup kept with every write to `source`. For each entry, `keysOf(value, key)` lists the index keys it is found under.

- `get(indexKey)` is the frozen set of source keys found under it, an empty frozen set when none. A new set is made only when that index key's members change.
- `first(indexKey)` is one of them, in no particular order, or nil.
- Both are current as soon as a write to `source` returns, inside a batch too.
- Read inside an effect or a computed they follow that index key alone. Read anywhere else they subscribe nothing.
- An index is read-only.

## Stores given to a runtime

A runtime's `tables` is a list `name -> store`, typed `Predictions.Tables`. Keep the stores themselves under their own types and build the list beside them:

```lua
local purses = Predictions.keyed() :: Predictions.Keyed<string, Purse>
local phase = Predictions.value("waiting")
local tables: Predictions.Tables = { purses = purses, phase = phase }
```

On a client, the runtime seals every table it is given: from then on `set` and `patch` error, and only the library writes them. On the server the game writes them as usual, and every write is sent at the next tick.
