--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage.Packages.Charm)
local Store = require(ReplicatedStorage.Packages.Predictions.store)
local Types = require(ReplicatedStorage.Packages.Predictions._types)
local TestRunner = require(script.Parent.TestRunner)

type Entry = { n: number }

local function keyedStore(): Types.KeyedStore<string, Entry>
	return Store.keyed() :: any
end

-- Runs `read` in an effect and counts its runs; returns the count reader and the effect's cleanup.
local function countRuns(read: () -> ()): (() -> number, () -> ())
	local runs = 0
	local stop = Charm.effect(function()
		read()
		runs += 1
	end)
	return function()
		return runs
	end, stop
end

local cases: { TestRunner.TestCase } = {
	{
		name = "store get outside anything reactive returns the live entry",
		run = function()
			local store = keyedStore()
			local entry = { n = 1 }
			store.set("a", entry)
			TestRunner.expectEqual(store.get("a"), entry)
			TestRunner.expectEqual(store.get("missing"), nil)
			TestRunner.expectEqual(store.all().a, entry)
		end,
	},
	{
		name = "store wakes the readers of the entry written and no others",
		run = function()
			local store = keyedStore()
			store.patch({ a = { n = 1 }, b = { n = 1 } })
			local runsOfA, stopA = countRuns(function()
				store.get("a")
			end)
			local runsOfB, stopB = countRuns(function()
				store.get("b")
			end)

			store.set("a", { n = 2 })
			TestRunner.expectEqual(runsOfA(), 2)
			TestRunner.expectEqual(runsOfB(), 1)

			-- The same value is no write.
			store.set("a", store.get("a"))
			store.patch({ b = store.get("b") :: Entry })
			TestRunner.expectEqual(runsOfA(), 2)
			TestRunner.expectEqual(runsOfB(), 1)

			-- A patch of both wakes each once.
			store.patch({ a = { n = 3 }, b = { n = 3 } })
			TestRunner.expectEqual(runsOfA(), 3)
			TestRunner.expectEqual(runsOfB(), 2)

			stopA()
			stopB()
		end,
	},
	{
		name = "store wakes a reader of a missing key when it appears and when it goes",
		run = function()
			local store = keyedStore()
			local seen: { any } = {}
			local stop = Charm.effect(function()
				local entry = store.get("a")
				table.insert(seen, if entry then entry.n else "none")
			end)
			store.set("other", { n = 0 })
			store.set("a", { n = 1 })
			store.set("a", nil)
			store.patch({ a = { n = 2 } })
			store.patch({ a = false })
			stop()
			-- The write of "other" wakes the keys' readers too: a reader of a missing key follows the keys.
			TestRunner.expectDeepEqual(seen, { "none", "none", 1, "none", 2, "none" } :: { any })
		end,
	},
	{
		name = "store keys is one frozen set until a key comes or goes",
		run = function()
			local store = keyedStore()
			store.patch({ a = { n = 1 }, b = { n = 1 } })
			local keys = store.keys()
			TestRunner.expectDeepEqual(keys, { a = true, b = true })
			TestRunner.expectEqual(table.isfrozen(keys), true)

			store.set("a", { n = 2 })
			TestRunner.expectEqual(store.keys(), keys)

			store.set("c", { n = 1 })
			local withC = store.keys()
			TestRunner.expectEqual(withC ~= keys, true)
			TestRunner.expectDeepEqual(keys, { a = true, b = true })
			TestRunner.expectDeepEqual(withC, { a = true, b = true, c = true })

			store.set("c", nil)
			TestRunner.expectDeepEqual(store.keys(), { a = true, b = true })
		end,
	},
	{
		name = "store keys wakes its readers when a key comes or goes, not when an entry changes",
		run = function()
			local store = keyedStore()
			store.set("a", { n = 1 })
			local runs, stop = countRuns(function()
				store.keys()
			end)
			store.set("a", { n = 2 })
			TestRunner.expectEqual(runs(), 1)
			store.set("b", { n = 1 })
			TestRunner.expectEqual(runs(), 2)
			store.patch({ a = false })
			TestRunner.expectEqual(runs(), 3)
			stop()
		end,
	},
	{
		name = "store observe over keys survives callbacks that add keys",
		run = function()
			local store = keyedStore()
			store.set("a", { n = 1 })
			local observed: { string } = {}
			local stop = Charm.observe(store.keys, function(isKey: boolean, key: string)
				TestRunner.expectEqual(isKey, true)
				table.insert(observed, key)
				if key == "a" then
					store.set("b", { n = 1 })
				end
				return nil
			end)
			table.sort(observed)
			TestRunner.expectDeepEqual(observed, { "a", "b" })
			stop()
		end,
	},
	{
		name = "store observe drops a gone key's scope before that key's effects re-run",
		run = function()
			local store = keyedStore()
			store.set("a", { n = 1 })
			local log: { string } = {}
			local stop = Charm.observe(store.keys, function(_, key: string)
				Charm.effect(function()
					local entry = store.get(key)
					table.insert(log, `run {key} {if entry then entry.n else "none"}`)
				end)
				return function()
					table.insert(log, `drop {key}`)
				end
			end)
			store.set("a", nil)
			stop()
			TestRunner.expectDeepEqual(log, { "run a 1", "drop a" })
		end,
	},
	{
		name = "store all errors inside an effect or computed and nowhere else",
		run = function()
			local store = keyedStore()
			store.set("a", { n = 1 })

			TestRunner.expectError(function()
				Charm.effect(function()
					store.all()
				end)
			end, "keys()")

			local readAll = Charm.computed(function()
				return store.all()
			end)
			TestRunner.expectError(function()
				readAll()
			end, "keys()")

			local reads = 0
			local stopScope = Charm.effectScope(function()
				store.all()
				reads += 1
			end)
			stopScope()

			local stopOuter = Charm.effect(function()
				Charm.untracked(function()
					store.all()
					reads += 1
				end)
				Charm.effectScope(function()
					store.all()
					reads += 1
				end)
			end)
			stopOuter()

			local stopObserve = Charm.observe(store.keys, function()
				store.all()
				reads += 1
				return nil
			end)
			stopObserve()

			store.all()
			TestRunner.expectEqual(reads, 4)
		end,
	},
	{
		name = "store all is not reactive",
		run = function()
			local store = keyedStore()
			store.set("a", { n = 1 })
			-- An effectScope inside an effect would hand a signal read to the effect: all() reads none.
			local runs, stop = countRuns(function()
				Charm.effectScope(function()
					store.all()
				end)
			end)
			store.set("a", { n = 2 })
			store.set("b", { n = 1 })
			TestRunner.expectEqual(runs(), 1)
			stop()
		end,
	},
	{
		name = "store entries may not be false and patch false removes",
		run = function()
			local store = keyedStore()
			TestRunner.expectError(function()
				store.set("a", false :: any)
			end, "may not be false")
			store.set("a", { n = 1 })
			store.patch({ a = false, b = { n = 2 } })
			TestRunner.expectDeepEqual(store.all(), { b = { n = 2 } })
			TestRunner.expectError(function()
				Store.value(false :: any)
			end, "may not be false")
		end,
	},
	{
		name = "store listen delivers after the outermost batch, coalesced, in write order",
		run = function()
			local store = keyedStore()
			local first = { n = 1 }
			store.set("a", first)
			local calls: { { any } } = {}
			local disconnect = store.listen(function(key, value, previous)
				table.insert(calls, { key, if value then value.n else "none", if previous then previous.n else "none" } :: { any })
			end)

			store.set("b", { n = 1 })
			TestRunner.expectDeepEqual(calls, { { "b", 1, "none" } :: { any } })
			table.clear(calls)

			Charm.batch(function()
				store.set("c", { n = 1 })
				store.set("a", { n = 2 })
				Charm.batch(function()
					store.set("c", { n = 2 })
				end)
				store.patch({ a = { n = 3 } })
				-- Created and removed again: it ends where it began.
				store.set("d", { n = 1 })
				store.set("d", nil)
				-- Changed and changed back.
				local b = store.get("b")
				store.set("b", { n = 9 })
				store.set("b", b)
				TestRunner.expectEqual(#calls, 0)
			end)
			TestRunner.expectDeepEqual(calls, { { "c", 2, "none" } :: { any }, { "a", 3, 1 } :: { any } })
			TestRunner.expectEqual(#calls, 2)

			disconnect()
			store.set("a", { n = 4 })
			TestRunner.expectEqual(#calls, 2)
		end,
	},
	{
		name = "store listen keeps order across stores and lets listeners write",
		run = function()
			local source = keyedStore()
			local mirror = keyedStore()
			local log: { string } = {}
			source.listen(function(key, value)
				table.insert(log, `source {key}`)
				mirror.set(key, value)
				table.insert(log, `source {key} done`)
			end)
			mirror.listen(function(key)
				table.insert(log, `mirror {key}`)
			end)

			Charm.batch(function()
				source.set("x", { n = 1 })
				mirror.set("m", { n = 1 })
				source.set("y", { n = 1 })
			end)
			-- The writes the listeners make are delivered after the batch's own, in their order.
			TestRunner.expectDeepEqual(log, {
				"source x",
				"source x done",
				"mirror m",
				"source y",
				"source y done",
				"mirror x",
				"mirror y",
			})
			TestRunner.expectDeepEqual(mirror.all(), { m = { n = 1 }, x = { n = 1 }, y = { n = 1 } })
		end,
	},
	{
		name = "store listen runs with nothing reactive active",
		run = function()
			local store = keyedStore()
			local other = keyedStore()
			other.set("o", { n = 1 })
			store.listen(function()
				other.get("o")
				other.all()
			end)
			local runs, stop = countRuns(function()
				store.set("a", { n = (Charm.untracked(store.get, "a") or { n = 0 }).n + 1 })
			end)
			other.set("o", { n = 2 })
			TestRunner.expectEqual(runs(), 1)
			stop()
		end,
	},
	{
		name = "store warns about a failing listener and still delivers to the rest",
		run = function()
			local store = keyedStore()
			local delivered = 0
			store.listen(function()
				error("listener broke")
			end)
			store.listen(function()
				delivered += 1
			end)
			TestRunner.expectWarning(function()
				store.set("a", { n = 1 })
			end, "listener broke")
			TestRunner.expectEqual(delivered, 1)
		end,
	},
	{
		name = "store onWrite runs inside each write with the previous value",
		run = function()
			local store = keyedStore()
			local first = { n = 1 }
			store.set("a", first)
			local writes: { { any } } = {}
			local disconnect = store._onWrite(function(key, value, previous)
				table.insert(writes, { key, value or "none", previous or "none" } :: { any })
			end)
			local second = { n = 2 }
			Charm.batch(function()
				store.set("a", second)
				TestRunner.expectDeepEqual(writes, { { "a", second, first } :: { any } })
				store.set("a", nil)
				store.set("a", second)
			end)
			TestRunner.expectDeepEqual(writes, {
				{ "a", second, first } :: { any },
				{ "a", "none", second } :: { any },
				{ "a", second, "none" } :: { any },
			})
			disconnect()
			store.set("a", first)
			TestRunner.expectEqual(#writes, 3)
		end,
	},
	{
		name = "store seal leaves only the library's writes",
		run = function()
			local store = keyedStore()
			store._seal()
			TestRunner.expectError(function()
				store.set("a", { n = 1 })
			end, "only the library writes it")
			TestRunner.expectError(function()
				store.patch({ a = { n = 1 } })
			end, "only the library writes it")
			store._write({ a = { n = 1 } })
			TestRunner.expectDeepEqual(store.all(), { a = { n = 1 } })
			store._write({ a = false })
			TestRunner.expectDeepEqual(store.all(), {})

			local value = (Store.value({ n = 1 }) :: any) :: Types.ValueStore<Entry>
			value._keyed._seal()
			TestRunner.expectError(function()
				value.set({ n = 2 })
			end, "only the library writes it")
			value._keyed._write({ [Store.VALUE_KEY] = { n = 2 } })
			TestRunner.expectEqual(value.get().n, 2)
		end,
	},
	{
		name = "store value holds one entry and listens to it",
		run = function()
			local value = (Store.value({ n = 1 }) :: any) :: Types.ValueStore<Entry>
			TestRunner.expectEqual(value.get().n, 1)
			TestRunner.expectDeepEqual(value._keyed.all(), { [Store.VALUE_KEY] = { n = 1 } })

			local calls: { { number } } = {}
			value.listen(function(newValue, previous)
				table.insert(calls, { newValue.n, previous.n })
			end)
			local runs, stop = countRuns(function()
				value.get()
			end)
			value.set({ n = 2 })
			TestRunner.expectDeepEqual(calls, { { 2, 1 } })
			TestRunner.expectEqual(runs(), 2)
			stop()

			local empty = Store.value(nil :: Entry?)
			TestRunner.expectEqual(empty.get(), nil)
			empty.set({ n = 1 })
			TestRunner.expectEqual((empty.get() :: Entry).n, 1)
		end,
	},
	{
		name = "store index follows every write and is current when the write returns",
		run = function()
			local store = keyedStore()
			store.set("a", { n = 1 })
			local byN = Store.index(store, function(entry: Entry, _key: string): { number }
				return { entry.n }
			end)
			TestRunner.expectDeepEqual(byN.get(1), { a = true })
			TestRunner.expectEqual(byN.first(1), "a")
			TestRunner.expectDeepEqual(byN.get(2), {})
			TestRunner.expectEqual(byN.first(2), nil)

			Charm.batch(function()
				store.patch({ b = { n = 1 }, c = { n = 2 } })
				TestRunner.expectDeepEqual(byN.get(1), { a = true, b = true })
				TestRunner.expectDeepEqual(byN.get(2), { c = true })
			end)

			store.set("a", { n = 2 })
			TestRunner.expectDeepEqual(byN.get(1), { b = true })
			TestRunner.expectDeepEqual(byN.get(2), { a = true, c = true })

			store.patch({ b = false })
			TestRunner.expectDeepEqual(byN.get(1), {})
			TestRunner.expectEqual(byN.first(1), nil)
		end,
	},
	{
		name = "store index hands out frozen sets, new only when an index key's members change",
		run = function()
			local store = keyedStore()
			store.patch({ a = { n = 1 }, b = { n = 2 } })
			local byN = Store.index(store, function(entry: Entry): { number }
				return { entry.n }
			end)
			local ones = byN.get(1)
			TestRunner.expectEqual(table.isfrozen(ones), true)
			TestRunner.expectEqual(table.isfrozen(byN.get(5)), true)
			-- A write that leaves index key 1's members alone keeps its set.
			store.set("b", { n = 3 })
			store.set("a", { n = 1 })
			TestRunner.expectEqual(byN.get(1), ones)
			store.set("c", { n = 1 })
			TestRunner.expectEqual(byN.get(1) ~= ones, true)
			TestRunner.expectDeepEqual(ones, { a = true })
		end,
	},
	{
		name = "store index wakes the readers of the index keys whose members change and no others",
		run = function()
			local store = keyedStore()
			store.patch({ a = { n = 1 }, b = { n = 2 } })
			local byN = Store.index(store, function(entry: Entry): { number }
				return { entry.n }
			end)
			local seenOne: { { [string]: true } } = {}
			local stopOne = Charm.effect(function()
				table.insert(seenOne, byN.get(1))
			end)
			local firstOfTwo: { any } = {}
			local stopTwo = Charm.effect(function()
				table.insert(firstOfTwo, byN.first(2) or "none")
			end)
			local seenThree: { { [string]: true } } = {}
			local stopThree = Charm.effect(function()
				table.insert(seenThree, byN.get(3))
			end)

			-- Index key 1 gains a member: only its reader wakes.
			store.set("c", { n = 1 })
			TestRunner.expectEqual(#seenOne, 2)
			TestRunner.expectDeepEqual(seenOne[2], { a = true, c = true })
			TestRunner.expectEqual(#firstOfTwo, 1)

			-- A write that changes no index key's members wakes nobody.
			store.set("a", { n = 1 })
			TestRunner.expectEqual(#seenOne, 2)
			TestRunner.expectEqual(#firstOfTwo, 1)

			-- An entry moving from 2 to 1 wakes both.
			store.set("b", { n = 1 })
			TestRunner.expectEqual(#seenOne, 3)
			TestRunner.expectDeepEqual(seenOne[3], { a = true, b = true, c = true })
			TestRunner.expectDeepEqual(firstOfTwo, { "b", "none" })

			-- A member removed.
			store.set("c", nil)
			TestRunner.expectEqual(#seenOne, 4)
			TestRunner.expectDeepEqual(seenOne[4], { a = true, b = true })

			-- The reader of an index key that had no members wakes when the first arrives.
			local runsOfThree = #seenThree
			TestRunner.expectDeepEqual(seenThree[1], {})
			store.set("d", { n = 3 })
			TestRunner.expectEqual(#seenThree > runsOfThree, true)
			TestRunner.expectDeepEqual(seenThree[#seenThree], { d = true })
			local afterArrival = #seenThree
			local onesBefore = #seenOne
			-- Now it has members it follows index key 3 alone.
			store.set("e", { n = 7 })
			TestRunner.expectEqual(#seenThree, afterArrival)
			TestRunner.expectEqual(#seenOne, onesBefore)

			stopOne()
			stopTwo()
			stopThree()
		end,
	},
	{
		name = "store index is current inside the batch of the write",
		run = function()
			local store = keyedStore()
			local byN = Store.index(store, function(entry: Entry): { number }
				return { entry.n }
			end)
			local woken: { { [string]: true } } = {}
			local stop = Charm.effect(function()
				table.insert(woken, byN.get(1))
			end)
			Charm.batch(function()
				store.set("a", { n = 1 })
				TestRunner.expectDeepEqual(byN.get(1), { a = true })
				TestRunner.expectEqual(byN.first(1), "a")
				store.set("a", { n = 2 })
				TestRunner.expectDeepEqual(byN.get(1), {})
				TestRunner.expectDeepEqual(byN.get(2), { a = true })
				store.set("b", { n = 1 })
				TestRunner.expectEqual(#woken, 1)
			end)
			TestRunner.expectEqual(#woken, 2)
			TestRunner.expectDeepEqual(woken[2], { b = true })
			stop()
		end,
	},
	{
		name = "store index lists an entry under several keys and under none",
		run = function()
			local store = keyedStore()
			local byTens = Store.index(store, function(entry: Entry): { string }
				if entry.n == 0 then
					return {}
				end
				return { "any", `tens{entry.n // 10}` }
			end)
			store.patch({ a = { n = 0 }, b = { n = 15 }, c = { n = 21 } })
			TestRunner.expectDeepEqual(byTens.get("any"), { b = true, c = true })
			TestRunner.expectDeepEqual(byTens.get("tens1"), { b = true })
			TestRunner.expectDeepEqual(byTens.get("tens2"), { c = true })
			store.set("b", { n = 0 })
			TestRunner.expectDeepEqual(byTens.get("any"), { c = true })
			TestRunner.expectDeepEqual(byTens.get("tens1"), {})
		end,
	},
}

return cases
