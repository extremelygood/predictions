--!strict

local TestRunner = require(script.TestRunner)
local cases = require(script["CharmSyncAdapter.spec"])

TestRunner.run(cases)
