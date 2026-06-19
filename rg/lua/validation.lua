local function fail(message)
  error(message, 0)
end

local function require_string(value, label)
  if type(value) ~= "string" then
    fail(label .. " must be a string")
  end
  return value
end

local function optional_bool(value, default)
  if value == nil then return default end
  if type(value) ~= "boolean" then
    fail("expected boolean, got " .. type(value))
  end
  return value
end

local function optional_int(value, default, min_allowed, max_allowed, label)
  if value == nil then
    return { value = default, capped = false }
  end
  if type(value) ~= "number" or value ~= value or math.floor(value) ~= value then
    fail(label .. " must be an integer")
  end
  if value < min_allowed then
    fail(label .. " must be at least " .. tostring(min_allowed))
  end
  local capped = value > max_allowed
  if capped then value = max_allowed end
  return { value = value, capped = capped }
end

local function array_of_strings(value, label)
  if value == nil then return nil end
  if type(value) ~= "table" then
    fail(label .. " must be an array")
  end
  for i, v in ipairs(value) do
    if type(v) ~= "string" then
      fail(label .. "[" .. tostring(i) .. "] must be a string")
    end
  end
  return value
end

local function validate_project_relative_path(path)
  if path == "" then fail("path must not be empty") end
  if path:find("\0", 1, true) then fail("path must not contain NUL bytes") end
  if path:sub(1, 1) == "/" then fail("path must not be absolute") end
  if path:match("^[A-Za-z]:") then fail("path must not be a Windows absolute path") end
  if path:match("^\\") then fail("path must not be a Windows absolute path") end
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then fail("path must not contain parent traversal (..)") end
  end
  return path
end

local function validate_executable_name(name)
  if name == "" then fail("rg_executable must not be empty") end
  if name:find("\0", 1, true) then fail("rg_executable must not contain NUL bytes") end
  if name:find("/", 1, true) then fail("rg_executable must not contain path separators") end
  if name:find("\\", 1, true) then fail("rg_executable must not contain path separators") end
  if name:find("%.%.", 1, true) then fail("rg_executable must not contain ..") end
  return name
end

return {
  fail = fail,
  require_string = require_string,
  optional_bool = optional_bool,
  optional_int = optional_int,
  array_of_strings = array_of_strings,
  validate_project_relative_path = validate_project_relative_path,
  validate_executable_name = validate_executable_name,
}
