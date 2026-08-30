--!strict

local TestRunner = require(script.TestRunner)
local cases = require(script["CharmSyncAdapter.spec"])
local runtimeDiagnosticsCases = require(script["RuntimeDiagnostics.spec"])

for _, case in runtimeDiagnosticsCases do
	table.insert(cases, case)
end

TestRunner.run(cases)
