--!strict

local TestRunner = require(script.TestRunner)

local specs: { { TestRunner.TestCase } } = {
	require(script["Store.spec"]),
	require(script["Wire.spec"]),
	require(script["State.spec"]),
	require(script["Server.spec"]),
	require(script["Client.spec"]),
	require(script["EndToEnd.spec"]),
}

local cases: { TestRunner.TestCase } = {}
for _, spec in specs do
	for _, case in spec do
		table.insert(cases, case)
	end
end

TestRunner.run(cases)
