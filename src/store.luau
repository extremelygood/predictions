--!strict

--[[
	Stores: state held as entries under keys, each entry followed on its own. No signal ever holds a whole table, so a
	write costs the entries it changes and wakes only their readers.

	keyed() makes a table of entries.
	- get(key): the entry, or nil. Read inside an effect or a computed it follows that entry alone, or, while the key
	  does not exist, the coming and going of keys. Read with nothing reactive running it subscribes nothing.
	- keys(): the set of keys, `{ [key] = true }`, frozen. A new set is made after a key came or went, so a set once
	  handed out never changes (Charm.observe iterates it while its callbacks may write). Read reactively it follows
	  the coming and going of keys, not the entries' values.
	- all(): the live table of every entry: read it, never change or keep it. It is not reactive, so it errors when it
	  is called where a subscription is expected, directly inside an effect or a computed; use keys() and get() there.
	  Inside an effectScope or an observe callback, under untracked or in plain code it is fine.
	- set(key, value) and patch(changes) are the only writes: set takes nil to remove, patch takes false. An entry may
	  never be false. A value identical (==) to the one held is no write. Each write is one Charm.batch, so readers
	  wake once, after it. When a key comes or goes the readers of keys() are woken before that entry's own readers,
	  so an observe over the keys drops a gone key's scope before that key's effects re-run.
	- listen(listener): listener(key, value, previous) for each written entry, after the outermost Charm.batch around
	  the write has ended, in the order the entries were first written. Several writes to one key before then are one
	  call (previous: before the first, value: after the last), and none when the entry ends where it began. Listeners
	  run with nothing reactive active, may write stores (their own calls follow under the same rules), must not yield,
	  and an error in one is warned about. Returns a disconnect.
	Charm deep-freezes what its signals hold in Studio, and an entry read reactively is held by a signal: write a new
	table, never change an entry in place.

	value(initial) makes one value: get(), set(value), listen(listener(value, previous)). Underneath it is a keyed
	store whose only entry is under VALUE_KEY (nil: no entry), so it follows the same rules; a value may not be false.

	index(source, keysOf) is a lookup kept with every write to `source`: for each entry, `keysOf(value, key)` lists
	the index keys it is found under. get(indexKey) is the frozen set of source keys found under it (an empty frozen
	set when none): a new set only when that index key's members change. first(indexKey) is one of them, in no
	particular order, or nil. Both are current as soon as a write to `source` returns, inside a batch too. Read inside
	an effect or a computed they follow that index key alone (the sets are a keyed store underneath, so a reader of an
	index key without members follows the coming and going of index keys until it has some); read anywhere else they
	subscribe nothing.

	Private, for the runtimes:
	- _onWrite(listener): listener(key, value, previous) synchronously inside every write, once for each entry the write
	  changes, after the live table holds the new value and before any reader wakes; in the order the write changes
	  them (for patch, the iteration order of its `changes`). It runs with nothing reactive active and an error in it is
	  warned about. A listener must not yield or throw and must not write the store it listens to; it may write other
	  stores (the write joins the batch it runs in). Returns a disconnect.
	- _write(changes): patch, on a sealed store too.
	- _seal(): from then on set and patch error and only _write writes.
	- A value store's _keyed is the keyed store underneath.

	How all() tells where it is called: Charm keeps the running subscriber in getActiveSub(). An effect's node carries
	its function as `fn` and a computed's as `getter`; an effectScope (which observe callbacks run in) carries neither,
	and untracked clears it. all() errors only when the active node has one of the two. A Charm whose nodes are shaped
	differently makes all() never error, which is the safe side.
]]

local Charm = require(script.Parent.Parent.Charm)
local Types = require(script.Parent._types)

local VALUE_KEY = "v"

type Listener = { fn: (key: any, value: any, previous: any) -> (), connected: boolean }

-- What a store's `listen` deliveries need of it.
type Listened = {
	values: { [any]: any },
	listeners: { Listener },
	-- The deliveries waiting for the batch to end, by key.
	waiting: { [any]: Delivery },
}

type Delivery = {
	store: Listened,
	key: any,
	previous: any,
	value: any,
}

local function warnFailure(message: any): ()
	warn(`[Predictions] A store listener failed: {debug.traceback(tostring(message), 2)}`)
end

-- Every store's waiting deliveries, in the order their entries were first written.
local deliveries: { Delivery } = {}
local delivering = false
local deliveryTick = 0
local getDeliveryTick, setDeliveryTick = Charm.signal(0)

local function deliver()
	while deliveries[1] ~= nil do
		local round = deliveries
		deliveries = {}
		-- The values at the end of the batch; writes made by the listeners below start deliveries of their own.
		for _, delivery in round do
			delivery.store.waiting[delivery.key] = nil
			delivery.value = delivery.store.values[delivery.key]
		end
		for _, delivery in round do
			if delivery.value == delivery.previous then
				continue
			end
			for _, listener in delivery.store.listeners do
				if listener.connected then
					xpcall(listener.fn, warnFailure, delivery.key, delivery.value, delivery.previous)
				end
			end
		end
	end
end

-- One effect for every store: a write that finds no delivery waiting bumps the tick, so Charm runs this once the
-- outermost batch has ended. A write made by a listener runs it again from inside `deliver`; that run only keeps the
-- subscription, and the loop in `deliver` picks the new deliveries up in order.
Charm.untracked(Charm.effect, function()
	getDeliveryTick()
	if delivering then
		return
	end
	delivering = true
	local previousSub = Charm.setActiveSub(nil)
	deliver()
	Charm.setActiveSub(previousSub)
	delivering = false
end)

local function isSubscriber(node: any): boolean
	return node.fn ~= nil or node.getter ~= nil
end

type Entry<V> = {
	get: () -> V?,
	set: (V?) -> V?,
}

local function create<K, V>(initial: { [K]: V }): Types.KeyedStore<K, V>
	local values = initial
	-- A signal per key that is in the table and has been read reactively, dropped with its key.
	local entries: { [K]: Entry<V> } = {}
	-- Bumped when a key comes or goes.
	local keysVersion = 0
	local getKeysVersion, setKeysVersion = Charm.signal(keysVersion)
	-- The frozen set keys() hands out, made again after a key came or went.
	local keySet: { [K]: true }? = nil
	-- Replaced, never changed, so a write can walk the list it started with.
	local writeListeners: { { fn: Types.WriteListener<K, V> } } = {}
	local listened: Listened = { values = values, listeners = {}, waiting = {} }
	local sealed = false

	local function get(key: K): V?
		local value = values[key]
		if Charm.getActiveSub() == nil then
			return value
		end
		if value == nil then
			-- Nothing to subscribe to yet: follow the keys until it appears.
			getKeysVersion()
			return nil
		end
		local entry = entries[key]
		if entry == nil then
			local getEntry, setEntry = Charm.signal(value :: V?)
			entry = { get = getEntry, set = setEntry }
			entries[key] = entry
		end
		return (entry :: Entry<V>).get()
	end

	local function keys(): { [K]: true }
		getKeysVersion()
		local set = keySet
		if set == nil then
			local made: { [K]: true } = {}
			for key in values do
				made[key] = true
			end
			set = table.freeze(made)
			keySet = set
		end
		return set :: { [K]: true }
	end

	local function all(): { [K]: V }
		local sub = Charm.getActiveSub()
		if sub ~= nil and isSubscriber(sub) then
			error("[Predictions] all() is not reactive: inside an effect or computed use keys() and get()", 2)
		end
		return values
	end

	-- One entry, inside a batch the caller holds.
	local function writeEntry(key: K, value: V?)
		local previous = values[key]
		if value == previous then
			return
		end
		values[key] = value :: V

		if writeListeners[1] ~= nil then
			local previousSub = Charm.setActiveSub(nil)
			for _, listener in writeListeners do
				xpcall(listener.fn, warnFailure, key, value, previous)
			end
			Charm.setActiveSub(previousSub)
		end

		if listened.listeners[1] ~= nil and listened.waiting[key] == nil then
			local delivery: Delivery = { store = listened, key = key, previous = previous, value = nil }
			listened.waiting[key] = delivery
			-- Only the first waiting delivery wakes the effect: `deliver` takes the rest with it.
			local first = deliveries[1] == nil
			table.insert(deliveries, delivery)
			if first then
				deliveryTick += 1
				setDeliveryTick(deliveryTick)
			end
		end

		local entry = entries[key]
		if previous == nil or value == nil then
			keySet = nil
			keysVersion += 1
			setKeysVersion(keysVersion)
			if value == nil then
				entries[key] = nil
			end
		end
		if entry ~= nil then
			entry.set(value)
		end
	end

	local function writeChanges(changes: { [K]: V | false })
		for key, change in changes do
			writeEntry(key, if change == false then nil else change :: V)
		end
	end

	-- Readers wake, and listen deliveries start, when the outermost batch ends.
	local function inBatch(write: (any, any) -> (), first: any, second: any)
		Charm.startBatch()
		local succeeded, failure: any = pcall(write :: any, first, second)
		Charm.endBatch()
		if not succeeded then
			error(failure, 0)
		end
	end

	local function assertOpen()
		if sealed then
			error("[Predictions] This store is replicated: only the library writes it", 3)
		end
	end

	local function set(key: K, value: V?)
		assertOpen()
		if (value :: any) == false then
			error("[Predictions] An entry may not be false: set nil to remove it", 2)
		end
		inBatch(writeEntry, key, value)
	end

	local function patch(changes: { [K]: V | false })
		assertOpen()
		inBatch(writeChanges, changes)
	end

	local function write(changes: { [K]: V | false })
		inBatch(writeChanges, changes)
	end

	local function listen(listener: (key: K, value: V?, previous: V?) -> ()): () -> ()
		local record: Listener = { fn = listener :: any, connected = true }
		local list = table.clone(listened.listeners)
		table.insert(list, record)
		listened.listeners = list
		return function()
			if not record.connected then
				return
			end
			record.connected = false
			local remaining = table.clone(listened.listeners)
			table.remove(remaining, table.find(remaining, record) :: number)
			listened.listeners = remaining
		end
	end

	local function onWrite(listener: Types.WriteListener<K, V>): () -> ()
		local record = { fn = listener }
		local list = table.clone(writeListeners)
		table.insert(list, record)
		writeListeners = list
		return function()
			local index = table.find(writeListeners, record)
			if index == nil then
				return
			end
			local remaining = table.clone(writeListeners)
			table.remove(remaining, index)
			writeListeners = remaining
		end
	end

	local function seal()
		sealed = true
	end

	return {
		get = get,
		keys = keys,
		all = all,
		set = set,
		patch = patch,
		listen = listen,
		_onWrite = onWrite,
		_write = write,
		_seal = seal,
	}
end

local function keyed<K, V>(): Types.Keyed<K, V>
	return create({} :: { [K]: V })
end

local function value<V>(initial: V): Types.Value<V>
	if (initial :: any) == false then
		error("[Predictions] A value may not be false", 2)
	end
	local inner = create((if initial == nil then {} else { [VALUE_KEY] = initial }) :: { [string]: V })

	local function get(): V
		return inner.get(VALUE_KEY) :: V
	end

	local function set(newValue: V)
		inner.set(VALUE_KEY, newValue)
	end

	local function listen(listener: (value: V, previous: V) -> ()): () -> ()
		return inner.listen(function(_key: string, newValue: V?, previous: V?)
			listener(newValue :: V, previous :: V)
		end)
	end

	local store: Types.ValueStore<V> = {
		get = get,
		set = set,
		listen = listen,
		_keyed = inner,
	}
	return store
end

local NO_KEYS = table.freeze({})

-- Whether `listed` holds exactly the index keys of `indexKeys`, repeats aside. Lists are short, so a search is cheap.
local function sameIndexKeys<I>(indexKeys: { [I]: true }, listed: { I }): boolean
	for _, indexKey in listed do
		if indexKeys[indexKey] == nil then
			return false
		end
	end
	for indexKey in indexKeys do
		if table.find(listed, indexKey) == nil then
			return false
		end
	end
	return true
end

local function index<K, V, I>(source: Types.Keyed<K, V>, keysOf: (value: V, key: K) -> { I }): Types.Index<K, I>
	local store = (source :: any) :: Types.KeyedStore<K, V>
	-- Index key -> the frozen set of source keys found under it; replaced, never changed, when its members change.
	local members = create({} :: { [I]: { [K]: true } })
	-- Source key -> the index keys it is found under.
	local indexKeysOf: { [K]: { [I]: true } } = {}

	local function setOf(listed: { I }): { [I]: true }
		local indexKeys: { [I]: true } = {}
		for _, indexKey in listed do
			indexKeys[indexKey] = true
		end
		return indexKeys
	end

	local function update(key: K, entry: V?)
		local before = indexKeysOf[key]
		local after: { [I]: true }? = nil
		if entry ~= nil then
			local listed = keysOf(entry, key)
			-- Most writes leave an entry under the index keys it had: then nothing is made or written.
			if before ~= nil and sameIndexKeys(before, listed) then
				return
			end
			after = setOf(listed)
		elseif before == nil then
			return
		end
		indexKeysOf[key] = after :: any
		local held = members.all()
		local changes: { [I]: { [K]: true } | false } = {}
		if before ~= nil then
			for indexKey in before do
				if after == nil or after[indexKey] == nil then
					local set = table.clone(held[indexKey])
					set[key] = nil
					changes[indexKey] = if next(set) == nil then false else table.freeze(set)
				end
			end
		end
		if after ~= nil then
			for indexKey in after do
				if before == nil or before[indexKey] == nil then
					local current = held[indexKey]
					local set: { [K]: true } = if current ~= nil then table.clone(current) else {}
					set[key] = true
					changes[indexKey] = table.freeze(set)
				end
			end
		end
		if next(changes) ~= nil then
			members._write(changes)
		end
	end

	Charm.untracked(function()
		local sets: { [I]: { [K]: true } } = {}
		for key, entry in store.all() do
			local indexKeys = setOf(keysOf(entry, key))
			indexKeysOf[key] = indexKeys
			for indexKey in indexKeys do
				local set = sets[indexKey]
				if set == nil then
					set = {}
					sets[indexKey] = set
				end
				(set :: { [K]: true })[key] = true
			end
		end
		local changes: { [I]: { [K]: true } | false } = {}
		for indexKey, set in sets do
			changes[indexKey] = table.freeze(set)
		end
		members._write(changes)
	end)
	store._onWrite(update)

	local function get(indexKey: I): { [K]: true }
		return members.get(indexKey) or NO_KEYS :: any
	end

	local function first(indexKey: I): K?
		local set = members.get(indexKey)
		if set == nil then
			return nil
		end
		return (next(set))
	end

	return {
		get = get,
		first = first,
	}
end

return {
	keyed = keyed,
	value = value,
	index = index,
	VALUE_KEY = VALUE_KEY,
}
