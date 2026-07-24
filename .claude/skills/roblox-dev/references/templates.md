# Roblox Module Templates

These are the canonical boilerplate templates. Every generated script MUST conform to one of these structures. Do not deviate from the section order or naming.

---

## Service Template (server-side ModuleScript)

```luau
--|| Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local FunctionUtils = require(ReplicatedStorage.Framework.Shared.Utils.FunctionUtils)
local ModuleUtils = require(ReplicatedStorage.Framework.Shared.Utils.ModuleUtils)
local UtilsLib = require(ReplicatedStorage.Framework.Shared.Utils.UtilsLibrary)
local Network = require(ReplicatedStorage.Framework.Shared.Network)

--|| Variables

--|| Constants

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	--Anything goes here
end

function Shared.Start()
	--Anything goes here
end

-- [[ Private Functions ]] --

-- [[ Public Functions ]] --

return Shared
```

---

## Controller Template (client-side ModuleScript)

```luau
--|| Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--|| References
local FunctionUtils = require(ReplicatedStorage.Framework.Shared.Utils.FunctionUtils)
local ModuleUtils = require(ReplicatedStorage.Framework.Shared.Utils.ModuleUtils)
local UtilsLib = require(ReplicatedStorage.Framework.Shared.Utils.UtilsLibrary)
local Network = require(ReplicatedStorage.Framework.Shared.Network)

local player = Players.LocalPlayer

--|| Variables

--|| Constants

--|| MAIN ||--
local Local = {}
local Shared = {}

-- [[ Startup ]] --
function Shared.Init()
	--Anything goes here
end

function Shared.Start()
	--Anything goes here
end

-- [[ Private Functions ]] --

-- [[ Public Functions ]] --

return Shared
```

---

## Class Template

```lua
--|| Services

--|| References

--|| Variables

--|| Constants

--|| Types
export type ClassType = typeof(setmetatable({}, {
	
}))

--|| MAIN ||--
local Class = {}
Class.__index = Class

function Class.new(...)
	local self = setmetatable({}, Class)
	
	return self
end

return Class
```

---

## Template Injection Rules

When generating a script, map planned logic into these sections:

| Section | What goes here |
|---|---|
| `--\|\| Services` | Only Roblox game services (`game:GetService(...)`) |
| `--\|\| References` | `require()` calls for shared modules |
| `--\|\| Variables` | Mutable state, instances, flags |
| `--\|\| Constants` | Immutable values, config numbers, strings |
| `local Local = {}` | Private-scope data (not returned) |
| `local Shared = {}` | The public API table (this is returned) |
| `Shared.Init()` | Pre-start setup, dependency wiring (runs before Start) |
| `Shared.Start()` | Initialization logic, event connections |
| `-- [[ Private Functions ]] --` | `Local.FunctionName()` helpers |
| `-- [[ Public Functions ]] --` | `Shared.FunctionName()` exposed API |
| `return Shared` | Never change this line |

---

## Naming Conventions

- **PascalCase**: All function names (`Shared.GetPlayerData`, `Local.ValidateInput`)
- **camelCase**: Local variables (`local playerData`, `local isReady`)
- **SCREAMING_SNAKE_CASE**: True constants (`local MAX_PLAYERS = 10`)
- **PascalCase**: Type definitions (`type PlayerData = { ... }`)
- **Connections**: Always store and disconnect via a cleanup pattern (Maid/Janitor or manual `:Disconnect()`)
