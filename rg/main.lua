local source = debug.getinfo(1, "S").source
local dir = "."
if source:sub(1, 1) == "@" then
  dir = source:sub(2):match("^(.*)[/\\][^/\\]+$") or "."
end

local helpers = dofile(dir .. "/helpers.lua")
dofile(dir .. "/rg.lua")(helpers)
dofile(dir .. "/find_files.lua")(helpers)
