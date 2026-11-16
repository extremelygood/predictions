--!strict

--[[
	What the server sends a client, and how an entry's change is told. The only module that knows the layout.

	CHANGES. A change turns a value the receiver holds into the sender's value. A table counts as an array when it has
	the key 1, and as a dictionary otherwise (the empty table too).
	- A dictionary in both is sent as the fields that differ, each one a change of its own (so the rules repeat at
	  every level); a removed field is NONE.
	- An array in both is sent as an element change: a dictionary with the new length under "#" (true when the length
	  is the same) and, under each differing index as a string, that element's change by the same rules (a new element
	  whole). Elements past the new length are dropped. When every element would go whole, the array goes whole
	  instead, as that is smaller.
	- Anything else is sent whole: a scalar, a table where there was none or a scalar where there was a table, an
	  array over a dictionary and a dictionary over an array (an array emptied to {} too).
	The receiver tells them apart by what it holds: a dictionary arriving over a dictionary is a field diff, a
	dictionary with "#" arriving over an array is an element change, and everything else replaces what it holds. So a
	dictionary with a "#" field cannot be sent whole over an array: it would read as an element change.
	NONE is NaN: no value equals it, not even itself, and it survives a RemoteEvent. A field holding NaN therefore
	arrives as removed.

	MESSAGE. A dictionary with short string keys, nothing in it for a part that is empty:
		["0"] = the acknowledged sequence, when there is one to send;
		["<i>"] = the changes to table i, where i is the table's position (from 1) in the sorted list of table names
		          both sides build from their tables (`tableNames`).
	A table's changes are, in the common case of diffs alone, just the diffs dictionary itself. Otherwise they are an
	array { diffs or false, whole or false, gone } with the empty parts at the end left out:
		diffs = { [key] = change of that entry }
		whole = { [key] = the entry, to be held as it is (it replaces anything the receiver holds) }
		gone  = { key, ... }  the entries the receiver must drop
	The two forms are told apart by the key 1: the array has it, a dictionary of entry keys (strings) does not.

	WHAT THE WIRE CANNOT CARRY. Nothing here checks or converts values: that would walk every value every tick. What a
	RemoteEvent cannot carry (functions, tables with metatables, tables mixing array and dictionary keys or with nil
	holes, dictionary keys that are not strings, NaN, which reads as NONE) arrives changed or not at all. Keep such
	values out of replicated entries.
]]

local NONE = 0 / 0

-- Whether a change is NONE, the mark of a removed field.
local function isNone(value: any): boolean
	return value ~= value
end

local function isDictionary(value: { [any]: any }): boolean
	return value[1] == nil
end

-- The key of an element change's length; it cannot be an index, which is sent as digits.
local LENGTH = "#"

-- Deep equality: the same scalar, or tables with equal values under the same keys.
local function equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- The change that turns `previous` into `value`, or nil when they are deep-equal. NONE when `value` is nil.
local function diff(previous: any, value: any): any
	if previous == value then
		return nil
	end
	if value == nil then
		return NONE
	end
	if type(previous) == "table" and type(value) == "table" then
		if isDictionary(previous) and isDictionary(value) then
			local changes: { [any]: any }? = nil
			for key, field in value do
				local change = diff(previous[key], field)
				if change ~= nil then
					changes = changes or {}
					(changes :: { [any]: any })[key] = change
				end
			end
			for key in previous do
				if value[key] == nil then
					changes = changes or {}
					(changes :: { [any]: any })[key] = NONE
				end
			end
			return changes
		end
		if not isDictionary(previous) and not isDictionary(value) then
			local length = #value
			local changes: { [string]: any }? = nil
			local wholeElements = 0
			for index, element in value do
				local change = diff(previous[index], element)
				if change ~= nil then
					changes = changes or {}
					(changes :: { [string]: any })[tostring(index)] = change
					if change == element then
						wholeElements += 1
					end
				end
			end
			if changes == nil then
				if length == #previous then
					return nil
				end
				return { [LENGTH] = length }
			end
			if wholeElements == length then
				return value
			end
			(changes :: { [string]: any })[LENGTH] = if length == #previous then true else length
			return changes
		end
	end
	return value
end

-- `entry` with `change` applied: nil for NONE, a new table for a diff (sharing every sub-table the diff leaves
-- alone, since held entries may be frozen), else the change itself.
local function apply(entry: any, change: any): any
	if isNone(change) then
		return nil
	end
	if type(change) == "table" and type(entry) == "table" and isDictionary(change) and isDictionary(entry) then
		local result = table.clone(entry)
		for key, fieldChange in change do
			result[key] = apply(entry[key], fieldChange)
		end
		return result
	end
	if type(change) == "table" and type(entry) == "table" and change[LENGTH] ~= nil and not isDictionary(entry) then
		local length = change[LENGTH]
		if length == true then
			length = #entry
		end
		local result = table.move(entry, 1, math.min(length, #entry), 1, table.create(length))
		for key, elementChange in change do
			if key ~= LENGTH then
				local index = tonumber(key) :: number
				result[index] = apply(entry[index], elementChange)
			end
		end
		return result
	end
	return change
end

-- The table names in the order both sides number them.
local function tableNames(tables: { [string]: any }): { string }
	local names: { string } = {}
	for name in tables do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

local function nonEmpty<T>(part: T?): T?
	if part ~= nil and next(part :: any) ~= nil then
		return part
	end
	return nil
end

-- One table's changes for a message, or nil when all three are empty. The tables given become part of the message
-- as they are, so one built part may go into the messages of several clients.
local function tablePart(whole: { [string]: any }?, diffs: { [string]: any }?, gone: { string }?): any
	local wholePart = nonEmpty(whole)
	local diffsPart = nonEmpty(diffs)
	local gonePart = nonEmpty(gone)
	if gonePart ~= nil then
		return { diffsPart or false, wholePart or false, gonePart }
	elseif wholePart ~= nil then
		return { diffsPart or false, wholePart }
	end
	return diffsPart
end

-- A message from the acknowledged sequence (nil: none to send) and each table's part from `tablePart`, keyed by the
-- table's position in `tableNames`. Nil when there is nothing to send.
local function message(ack: number?, parts: { [number]: any }): { [string]: any }?
	local result: { [string]: any }? = nil
	if ack ~= nil then
		result = { ["0"] = ack }
	end
	for index, part in parts do
		result = result or {}
		(result :: { [string]: any })[tostring(index)] = part
	end
	return result
end

export type TableChanges = {
	diffs: { [string]: any }?,
	whole: { [string]: any }?,
	gone: { string }?,
}

export type Message = {
	ack: number?,
	-- Keyed by the table's position in `tableNames`.
	tables: { [number]: TableChanges },
}

local function optionalTable(value: any): any
	if value == false then
		return nil
	end
	return value
end

-- What a message holds, or nil when it does not have the layout above.
local function read(raw: unknown): Message?
	if type(raw) ~= "table" then
		return nil
	end
	local result: Message = { ack = nil, tables = {} }
	for key, part in raw :: { [any]: any } do
		local index = if type(key) == "string" then tonumber(key) else nil
		if index == nil or index < 0 or index % 1 ~= 0 then
			return nil
		end
		if index == 0 then
			if type(part) ~= "number" then
				return nil
			end
			result.ack = part
			continue
		end
		if type(part) ~= "table" then
			return nil
		end
		local changes: TableChanges
		if part[1] == nil then
			changes = { diffs = part, whole = nil, gone = nil }
		else
			changes = { diffs = optionalTable(part[1]), whole = optionalTable(part[2]), gone = part[3] }
		end
		if
			(changes.diffs ~= nil and type(changes.diffs) ~= "table")
			or (changes.whole ~= nil and type(changes.whole) ~= "table")
			or (changes.gone ~= nil and type(changes.gone) ~= "table")
		then
			return nil
		end
		result.tables[index] = changes
	end
	return result
end

return {
	NONE = NONE,
	isNone = isNone,
	equal = equal,
	diff = diff,
	apply = apply,
	tableNames = tableNames,
	tablePart = tablePart,
	message = message,
	read = read,
}
