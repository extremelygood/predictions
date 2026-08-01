--!strict

export type TestCase = {
	name: string,
	run: () -> (),
}

local function formatValue(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end

	return tostring(value)
end

local function findDifference(actual: any, expected: any, path: string, visited: { [any]: any }): string?
	if type(actual) ~= type(expected) then
		return `{path}: expected type {type(expected)}, got {type(actual)}`
	end

	if type(actual) ~= "table" then
		if actual ~= expected then
			return `{path}: expected {formatValue(expected)}, got {formatValue(actual)}`
		end

		return nil
	end

	if visited[actual] == expected then
		return nil
	end
	visited[actual] = expected

	for key, expectedValue in expected do
		local difference = findDifference(actual[key], expectedValue, `{path}[{formatValue(key)}]`, visited)
		if difference ~= nil then
			return difference
		end
	end

	for key in actual do
		if expected[key] == nil then
			return `{path}[{formatValue(key)}]: unexpected value {formatValue(actual[key])}`
		end
	end

	return nil
end

local function expectEqual(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(message or `Expected {formatValue(expected)}, got {formatValue(actual)}`, 2)
	end
end

local function expectDeepEqual(actual: any, expected: any, message: string?)
	local difference = findDifference(actual, expected, "value", {})
	if difference ~= nil then
		error(message or difference, 2)
	end
end

local function expectError(callback: () -> (), messageFragment: string?)
	local succeeded, failure = pcall(callback)
	if succeeded then
		error("Expected callback to fail", 2)
	end

	if messageFragment ~= nil and not string.find(tostring(failure), messageFragment, 1, true) then
		error(`Expected error containing {formatValue(messageFragment)}, got {formatValue(failure)}`, 2)
	end
end

local function cloneDeep(value: any, seen: { [any]: any }?): any
	if type(value) ~= "table" then
		return value
	end

	local copies = seen or {}
	if copies[value] ~= nil then
		return copies[value]
	end

	local copy = {}
	copies[value] = copy
	for key, child in value do
		copy[cloneDeep(key, copies)] = cloneDeep(child, copies)
	end

	return copy
end

local function run(cases: { TestCase })
	local failures: { string } = {}

	for _, case in cases do
		local succeeded, failure = xpcall(case.run, function(message)
			return debug.traceback(tostring(message), 2)
		end)

		if succeeded then
			print(`[Predictions tests] PASS: {case.name}`)
		else
			table.insert(failures, `{case.name}\n{failure}`)
			warn(`[Predictions tests] FAIL: {case.name}\n{failure}`)
		end
	end

	if #failures > 0 then
		error(`[Predictions tests] {#failures} of {#cases} tests failed\n\n{table.concat(failures, "\n\n")}`, 0)
	end

	print(`[Predictions tests] PASS: {#cases} tests completed`)
end

return {
	cloneDeep = cloneDeep,
	expectDeepEqual = expectDeepEqual,
	expectEqual = expectEqual,
	expectError = expectError,
	run = run,
}
