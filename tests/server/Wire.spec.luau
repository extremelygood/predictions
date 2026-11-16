--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TestRunner = require(script.Parent.TestRunner)
local Wire = require(ReplicatedStorage.Packages.Predictions._wire)

-- Whether a value is one a RemoteEvent carries unchanged: every table either a dense array or a dictionary of
-- string keys.
local function isSendable(value: any): boolean
	if type(value) ~= "table" then
		return true
	end
	local count = 0
	local stringKeys = 0
	for key, child in value do
		count += 1
		if type(key) == "string" then
			stringKeys += 1
		end
		if not isSendable(child) then
			return false
		end
	end
	return stringKeys == count or (stringKeys == 0 and #value == count)
end

-- About how many bytes a RemoteEvent spends on a value: strings their length and 2, numbers 9, booleans 2, a
-- Vector3 13, a table 3 and its keys and values.
local function sizeOf(value: any): number
	local kind = typeof(value)
	if kind == "string" then
		return #value + 2
	elseif kind == "number" then
		return 9
	elseif kind == "boolean" then
		return 2
	elseif kind == "Vector3" then
		return 13
	elseif kind == "table" then
		local size = 3
		for key, child in value do
			size += sizeOf(key) + sizeOf(child)
		end
		return size
	end
	return 9
end

-- `diff` then `apply` gives back `value`, and the diff is sendable.
local function expectRoundTrip(previous: any, value: any)
	local change = Wire.diff(previous, value)
	if Wire.equal(previous, value) then
		TestRunner.expectEqual(change, nil, "a diff between equal values")
		return
	end
	TestRunner.expectEqual(isSendable(change), true, "the diff is not sendable")
	TestRunner.expectEqual(Wire.equal(Wire.apply(previous, change), value), true, "the diff does not round-trip")
end

local cases: { TestRunner.TestCase } = {
	{
		name = "wire NONE equals nothing and is told by isNone",
		run = function()
			TestRunner.expectEqual(Wire.NONE == Wire.NONE, false)
			TestRunner.expectEqual(Wire.isNone(Wire.NONE), true)
			for _, value in { false, 0, "", {} } :: { any } do
				TestRunner.expectEqual(Wire.isNone(value), false)
			end
			TestRunner.expectEqual(Wire.isNone(nil), false)
		end,
	},
	{
		name = "wire equal is deep",
		run = function()
			TestRunner.expectEqual(Wire.equal({ a = { 1, 2 }, b = "x" }, { a = { 1, 2 }, b = "x" }), true)
			TestRunner.expectEqual(Wire.equal({ a = { 1, 2 } }, { a = { 1, 3 } }), false)
			TestRunner.expectEqual(Wire.equal({ a = 1 }, { a = 1, b = 2 }), false)
			TestRunner.expectEqual(Wire.equal({ a = 1, b = 2 }, { a = 1 }), false)
			TestRunner.expectEqual(Wire.equal(1, 1), true)
			TestRunner.expectEqual(Wire.equal(1, "1"), false)
			TestRunner.expectEqual(Wire.equal({}, {}), true)
		end,
	},
	{
		name = "wire diff is nil when nothing differs, deep",
		run = function()
			TestRunner.expectEqual(Wire.diff(1, 1), nil)
			TestRunner.expectEqual(Wire.diff({ a = { b = { 1, 2 } } }, { a = { b = { 1, 2 } } }), nil)
			TestRunner.expectEqual(Wire.diff({ 1, 2 }, { 1, 2 }), nil)
		end,
	},
	{
		name = "wire diff sends the fields that differ, recursively",
		run = function()
			local position = { x = 1, y = 2 }
			local previous = { position = position, health = 100, tags = { a = true } }
			local value = { position = position, health = 90, tags = { a = true, b = true } }
			TestRunner.expectDeepEqual(Wire.diff(previous, value), { health = 90, tags = { b = true } })
			expectRoundTrip(previous, value)
		end,
	},
	{
		name = "wire diff marks a removed field NONE at every level",
		run = function()
			local previous = { a = 1, inner = { keep = 1, drop = 2 } }
			local value = { inner = { keep = 1 } }
			local change = Wire.diff(previous, value)
			TestRunner.expectEqual(Wire.isNone(change.a), true)
			TestRunner.expectEqual(Wire.isNone(change.inner.drop), true)
			TestRunner.expectEqual(change.inner.keep, nil)
			expectRoundTrip(previous, value)

			TestRunner.expectEqual(Wire.isNone(Wire.diff(previous, nil)), true)
			TestRunner.expectEqual(Wire.apply(previous, Wire.NONE), nil)
		end,
	},
	{
		name = "wire sends an array as the elements that changed",
		run = function()
			TestRunner.expectDeepEqual(
				Wire.diff({ list = { 1, 2, 3 }, n = 1 }, { list = { 1, 2, 4 }, n = 1 }),
				{ list = { ["#"] = true, ["3"] = 4 } }
			)
			local previous = { slots = { { id = "a" }, { id = "b" } } }
			local value = { slots = { { id = "a" }, { id = "c" } } }
			TestRunner.expectDeepEqual(Wire.diff(previous, value), { slots = { ["#"] = true, ["2"] = { id = "c" } } })
			expectRoundTrip(previous, value)
			TestRunner.expectEqual(Wire.diff({ 1, 2 }, { 1, 2 }), nil)
		end,
	},
	{
		name = "wire round-trips arrays of records",
		run = function()
			local men = {
				{ position = Vector3.new(0, 0, 0), isDowned = false },
				{ position = Vector3.new(1, 0, 0), isDowned = false },
				{ position = Vector3.new(2, 0, 0), isDowned = false },
			}
			local function with(changes: { [number]: any }, length: number?): { any }
				local result = {}
				for index = 1, length or #men do
					result[index] = if changes[index] ~= nil then changes[index] else men[index]
				end
				return result
			end
			-- One element replaced.
			expectRoundTrip({ teamId = "t", men = men }, { teamId = "t", men = with({ [2] = { position = Vector3.new(5, 5, 5), isDowned = true } }) })
			-- One field of one element.
			expectRoundTrip({ men = men }, { men = with({ [3] = { position = men[3].position, isDowned = true } }) })
			-- An element appended.
			expectRoundTrip({ men = men }, { men = with({ [4] = { position = Vector3.zero, isDowned = false } }, 4) })
			-- The last element removed.
			local shorter = with({}, 2)
			TestRunner.expectDeepEqual(Wire.diff({ men = men }, { men = shorter }), { men = { ["#"] = 2 } })
			expectRoundTrip({ men = men }, { men = shorter })
			-- Shrunk to empty, grown from empty.
			expectRoundTrip({ men = men }, { men = {} })
			expectRoundTrip({ men = {} }, { men = men })
			-- Replaced by a dictionary and back.
			expectRoundTrip({ men = men }, { men = { leader = men[1] } })
			expectRoundTrip({ men = { leader = men[1] } }, { men = men })
		end,
	},
	{
		name = "wire round-trips nested arrays and arrays of scalars",
		run = function()
			expectRoundTrip({ grid = { { 1, 2 }, { 3, 4 } } }, { grid = { { 1, 2 }, { 3, 5, 6 } } })
			expectRoundTrip({ grid = { { 1, 2 }, { 3, 4 } } }, { grid = { { 1 }, {} } })
			expectRoundTrip({ grid = { { { 1 } } } }, { grid = { { { 2 } } } })
			local scalars = { 1, 2, 3, 4, 5, 6, 7, 8 }
			local fewChanged = { 1, 2, 3, 40, 5, 6, 7, 8 }
			TestRunner.expectDeepEqual(Wire.diff(scalars, fewChanged), { ["#"] = true, ["4"] = 40 })
			expectRoundTrip(scalars, fewChanged)
			-- Every element changed: the whole array is smaller, so it goes whole.
			local allChanged = { 9, 9, 9, 9, 9, 9, 9, 9 }
			TestRunner.expectEqual(Wire.diff(scalars, allChanged), allChanged)
			expectRoundTrip(scalars, allChanged)
			expectRoundTrip({ "a", "b" }, { "a", "b", "c" })
			expectRoundTrip({ "a", "b", "c" }, { "b" })
		end,
	},
	{
		name = "wire sends one changed field of one record smaller than the array",
		run = function()
			local men = {}
			for index = 1, 10 do
				men[index] = { position = Vector3.new(index, 0, 0), isDowned = false }
			end
			local changed = table.clone(men)
			changed[7] = { position = men[7].position, isDowned = true }
			local change = Wire.diff({ men = men }, { men = changed })
			TestRunner.expectDeepEqual(change, { men = { ["#"] = true, ["7"] = { isDowned = true } } })
			TestRunner.expectEqual(sizeOf(change) < sizeOf({ men = changed }) / 4, true)
		end,
	},
	{
		name = "wire apply makes a new array sharing the elements it leaves alone",
		run = function()
			local first = table.freeze({ n = 1 })
			local second = table.freeze({ n = 2 })
			local previous = table.freeze({ first, second })
			local result = Wire.apply(previous, Wire.diff(previous, { first, { n = 3 } }))
			TestRunner.expectEqual(result ~= previous, true)
			TestRunner.expectEqual(result[1], first)
			TestRunner.expectDeepEqual(result, { first, { n = 3 } })
			TestRunner.expectDeepEqual(previous[2], { n = 2 })
		end,
	},
	{
		name = "wire tells an element change from a replacement by what the receiver holds",
		run = function()
			-- A dictionary without "#" over an array replaces it.
			TestRunner.expectDeepEqual(Wire.apply({ 1, 2 }, { a = 1 }), { a = 1 })
			TestRunner.expectDeepEqual(Wire.apply({ 1, 2 }, {}), {})
			-- An array over an array replaces it.
			TestRunner.expectDeepEqual(Wire.apply({ 1, 2 }, { 3 }), { 3 })
			-- An element change over something that is not an array replaces it.
			TestRunner.expectDeepEqual(Wire.apply(nil, { ["#"] = 1, ["1"] = 5 }), { ["#"] = 1, ["1"] = 5 })
			TestRunner.expectDeepEqual(Wire.apply(4, { ["#"] = true }), { ["#"] = true })
			-- The other kinds of change still apply over an array and a dictionary.
			expectRoundTrip({ field = { a = 1 } }, { field = { 1, 2 } })
			expectRoundTrip({ field = { 1, 2 } }, { field = { a = 1 } })
		end,
	},
	{
		name = "wire sends a table replacing a scalar whole, and the reverse",
		run = function()
			TestRunner.expectDeepEqual(Wire.diff({ field = 1 }, { field = { a = 1 } }), { field = { a = 1 } })
			TestRunner.expectDeepEqual(Wire.diff({ field = { a = 1 } }, { field = 1 }), { field = 1 })
			TestRunner.expectDeepEqual(Wire.diff(1, { a = 1 }), { a = 1 })
			TestRunner.expectEqual(Wire.diff({ a = 1 }, 2), 2)
			expectRoundTrip({ field = 1 }, { field = { a = { b = 1 } } })
			expectRoundTrip("x", "y")
			expectRoundTrip(nil, { a = 1 })
		end,
	},
	{
		name = "wire counts the empty table a dictionary",
		run = function()
			TestRunner.expectDeepEqual(Wire.diff({ field = {} }, { field = { a = 1 } }), { field = { a = 1 } })
			local change = Wire.diff({ field = { a = 1 } }, { field = {} })
			TestRunner.expectEqual(Wire.isNone(change.field.a), true)
			expectRoundTrip({ field = { a = 1 } }, { field = {} })
			expectRoundTrip({ field = {} }, { field = { 1 } })
			expectRoundTrip({ field = { 1 } }, { field = {} })
		end,
	},
	{
		name = "wire apply makes a new table sharing what the diff leaves alone",
		run = function()
			local kept = table.freeze({ x = 1 })
			local previous = table.freeze({ kept = kept, inner = table.freeze({ a = 1, b = 2 }), n = 1 })
			local value = { kept = kept, inner = { a = 1, b = 3 }, n = 1 }
			local result = Wire.apply(previous, Wire.diff(previous, value))
			TestRunner.expectEqual(result ~= previous, true)
			TestRunner.expectEqual(result.kept, kept)
			TestRunner.expectEqual(result.inner ~= previous.inner, true)
			TestRunner.expectDeepEqual(result, value)
			TestRunner.expectDeepEqual(previous.inner, { a = 1, b = 2 })
		end,
	},
	{
		name = "wire round-trips mixed changes",
		run = function()
			local changes: { { any } } = {
				{ { a = 1, b = { c = { d = 1 } } }, { a = 1, b = { c = { d = 2, e = { 1 } } } } },
				{ { a = { 1 } }, { a = { 1 }, b = false } },
				{ { a = false }, { a = true } },
				{ { a = "x", b = { y = 1 } }, { b = { z = 2 } } },
				{ { a = { b = { c = 1 } } }, { a = {} } },
			}
			for _, pair in changes do
				expectRoundTrip(pair[1], pair[2])
			end
		end,
	},
	{
		name = "wire numbers tables by their sorted names",
		run = function()
			TestRunner.expectDeepEqual(Wire.tableNames({ round = 1, hands = 1, inventories = 1 }), {
				"hands",
				"inventories",
				"round",
			})
		end,
	},
	{
		name = "wire table parts leave empty parts out",
		run = function()
			TestRunner.expectEqual(Wire.tablePart(nil, nil, nil), nil)
			TestRunner.expectEqual(Wire.tablePart({}, {}, {}), nil)

			local diffs = { a = { n = 1 } }
			TestRunner.expectEqual(Wire.tablePart(nil, diffs, nil), diffs)
			TestRunner.expectEqual(Wire.tablePart({}, diffs, {}), diffs)

			local whole = { b = { n = 2 } }
			TestRunner.expectDeepEqual(Wire.tablePart(whole, nil, nil), { false, whole } :: { any })
			TestRunner.expectDeepEqual(Wire.tablePart(whole, diffs, nil), { diffs, whole } :: { any })
			TestRunner.expectDeepEqual(Wire.tablePart(nil, nil, { "c" }), { false, false, { "c" } } :: { any })
			TestRunner.expectDeepEqual(Wire.tablePart(whole, diffs, { "c" }), { diffs, whole, { "c" } } :: { any })
		end,
	},
	{
		name = "wire messages leave out what there is nothing of",
		run = function()
			TestRunner.expectEqual(Wire.message(nil, {}), nil)
			TestRunner.expectDeepEqual(Wire.message(4, {}), { ["0"] = 4 })
			local part = Wire.tablePart(nil, { a = 1 }, nil)
			TestRunner.expectDeepEqual(Wire.message(nil, { [3] = part }), { ["3"] = { a = 1 } })
		end,
	},
	{
		name = "wire reads back what it builds",
		run = function()
			local diffs = { a = { n = Wire.NONE, m = 2 } }
			local whole = { b = { n = 1, list = { 1, 2 } } }
			local built = Wire.message(7, {
				[1] = Wire.tablePart(nil, diffs, nil),
				[2] = Wire.tablePart(whole, nil, { "c", "d" }),
				[12] = Wire.tablePart(whole, diffs, nil),
			})
			TestRunner.expectEqual(isSendable(built), true)

			local read = Wire.read(built)
			assert(read ~= nil, "the message did not read")
			TestRunner.expectEqual(read.ack, 7)
			TestRunner.expectEqual(read.tables[1].diffs, diffs)
			TestRunner.expectEqual(read.tables[1].whole, nil)
			TestRunner.expectEqual(read.tables[1].gone, nil)
			TestRunner.expectEqual(read.tables[2].diffs, nil)
			TestRunner.expectEqual(read.tables[2].whole, whole)
			TestRunner.expectDeepEqual(read.tables[2].gone, { "c", "d" })
			TestRunner.expectEqual(read.tables[12].diffs, diffs)
			TestRunner.expectEqual(read.tables[12].whole, whole)
			TestRunner.expectEqual(read.tables[3], nil)

			local ackOnly = Wire.read(Wire.message(1, {}))
			assert(ackOnly ~= nil, "the message did not read")
			TestRunner.expectEqual(ackOnly.ack, 1)
			TestRunner.expectEqual(next(ackOnly.tables), nil)

			local noAck = Wire.read(Wire.message(nil, { [1] = Wire.tablePart(nil, diffs, nil) }))
			assert(noAck ~= nil, "the message did not read")
			TestRunner.expectEqual(noAck.ack, nil)
		end,
	},
	{
		name = "wire read refuses what does not have the layout",
		run = function()
			TestRunner.expectEqual(Wire.read(nil), nil)
			local malformed: { any } = {
				1,
				"x",
				{ [1] = {} },
				{ x = {} },
				{ ["-1"] = {} },
				{ ["1.5"] = {} },
				{ ["0"] = "1" },
				{ ["1"] = 5 },
			}
			for _, raw in malformed do
				TestRunner.expectEqual(Wire.read(raw), nil)
			end
			TestRunner.expectEqual(Wire.read({ ["1"] = { false, 5 } :: { any } }), nil)
		end,
	},
}

return cases
