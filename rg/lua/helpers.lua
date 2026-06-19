local DEFAULT_MAX_RESULTS = 100
local MAX_RESULTS_LIMIT = 500
local DEFAULT_CONTEXT_LINES = 0
local MAX_CONTEXT_LINES = 3
local DEFAULT_MAX_OUTPUT_BYTES = 32768
local MAX_OUTPUT_BYTES_LIMIT = 65536
local DEFAULT_TIMEOUT_MS = 5000
local MAX_TIMEOUT_MS = 10000
local MAX_SUMMARY_CHARS = 240
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

local function shorten(text)
  -- Trim trailing newlines/carriage returns
  local trimmed = text:gsub("[\r\n]+$", "")
  if #trimmed > MAX_SUMMARY_CHARS then
    return trimmed:sub(1, MAX_SUMMARY_CHARS) .. "..."
  end
  return trimmed
end

local function add_globs(argv, include_globs, exclude_globs)
  if include_globs then
    for _, glob in ipairs(include_globs) do
      argv[#argv + 1] = "--glob"
      argv[#argv + 1] = glob
    end
  end
  if exclude_globs then
    for _, glob in ipairs(exclude_globs) do
      argv[#argv + 1] = "--glob"
      if glob:sub(1, 1) == "!" then
        argv[#argv + 1] = glob
      else
        argv[#argv + 1] = "!" .. glob
      end
    end
  end
end


-- Check if rg is available
local function check_rg_available(rg_executable)
  local check = sage.execute({
    argv = { rg_executable, "--version" },
    cwd = ".",
    capture_output_limit = 4096,
    timeout_ms = 2000,
  })
  if not check.ok then
    local message = "ripgrep (" .. rg_executable .. ") is required for the rg tool.\n" ..
      "  brew install ripgrep\n" ..
      "  apt install ripgrep\n" ..
      "  pacman -S ripgrep"
    fail(message)
  end
end

-- Parse one line of rg output
local function parse_rg_line(line, current_path)
  -- Tab-separated: path\tline\t[column]\tsummary
  -- Context lines may lack column: path\tline\t\tsummary or path\tline\tcontext_summary
  local parts = {}
  for part in line:gmatch("([^\t]*)") do
    parts[#parts + 1] = part
  end

  -- Handle trailing empty fields from trailing tabs
  -- Count actual tabs in the line to determine field count
  local tab_count = select(2, line:gsub("\t", ""))

  if tab_count >= 3 and #parts >= 4 then
    -- Match row: path, line, column, summary
    local path = parts[1]
    local line_num = tonumber(parts[2])
    local column = tonumber(parts[3])
    local summary = parts[4]
    -- Rejoin remaining parts if there were more than 4 tab-delimited fields
    if #parts > 4 then
      local rest = {}
      for i = 4, #parts do
        rest[#rest + 1] = parts[i]
      end
      summary = table.concat(rest, "\t")
    end
    return {
      path = path,
      line = line_num or 0,
      column = column or 0,
      kind = "match",
      summary = shorten(summary),
    }
  end

  -- Context row or fallback
  -- Format: path\tline\t\tsummary (column empty) or path\tline\tsummary
  local path = parts[1] or ""
  local line_num = tonumber(parts[2])
  local summary = parts[3] or ""
  if #parts > 3 then
    local rest = {}
    for i = 3, #parts do
      rest[#rest + 1] = parts[i]
    end
    summary = table.concat(rest, "\t")
  end
  return {
    path = path,
    line = line_num or 0,
    kind = "context",
    summary = shorten(summary),
  }
end

-- Parse rg stdout into rows
local function parse_output(stdout, max_results, max_output_bytes, context_lines)
  local rows = {}
  local total_bytes = 0
  local truncated_by_results = false
  local truncated_by_output_bytes = false

  -- Split by newlines
  local pos = 1
  while pos <= #stdout do
    local next_newline = stdout:find("\n", pos, true)
    local line
    if next_newline then
      line = stdout:sub(pos, next_newline - 1)
      pos = next_newline + 1
    else
      line = stdout:sub(pos)
      pos = #stdout + 1
    end

    -- Skip empty lines and separator lines (-- separator between file groups)
    if line == "" or line == "--" then
      -- pass
    else
      local parsed = parse_rg_line(line)

      -- Check limits
      if #rows >= max_results then
        truncated_by_results = true
        break
      end

      -- Track byte count for summary fields
      local summary_bytes = #(parsed.summary or "")
      if total_bytes + summary_bytes > max_output_bytes then
        truncated_by_output_bytes = true
        break
      end
      total_bytes = total_bytes + summary_bytes

      rows[#rows + 1] = parsed
    end
  end

  return rows, truncated_by_results, truncated_by_output_bytes, total_bytes
end


local function append_paths(argv, paths_validated)
  if paths_validated and #paths_validated > 0 then
    for _, p in ipairs(paths_validated) do
      argv[#argv + 1] = p
    end
  else
    argv[#argv + 1] = "."
  end
end

local function validate_paths(input)
  local paths_raw = array_of_strings(input.paths, "paths")
  local paths_validated = {}
  if paths_raw then
    for _, p in ipairs(paths_raw) do
      validate_project_relative_path(p)
      paths_validated[#paths_validated + 1] = p
    end
  end
  return paths_validated
end

local function searched_paths_for(paths_validated)
  if paths_validated and #paths_validated > 0 then
    local searched_paths = {}
    for _, p in ipairs(paths_validated) do
      searched_paths[#searched_paths + 1] = p
    end
    return searched_paths
  end
  return { "." }
end

local function append_limited_row(rows, row, state, max_results, max_output_bytes)
  if #rows >= max_results then
    state.truncated_by_results = true
    return false
  end
  local summary_bytes = #(row.summary or "")
  if state.total_summary_bytes + summary_bytes > max_output_bytes then
    state.truncated_by_output_bytes = true
    return false
  end
  state.total_summary_bytes = state.total_summary_bytes + summary_bytes
  rows[#rows + 1] = row
  return true
end


local function execute_rg(argv, timeout_ms)
  local result = sage.execute({
    argv = argv,
    cwd = ".",
    capture_output_limit = 1048576,
    timeout_ms = timeout_ms,
  })
  if result.ok then
    return result, result.stdout or ""
  end
  if result.exit_status == 1 and not result.error then
    return result, ""
  end
  local stderr = result.stderr or ""
  local err_msg = result.error or ("exit status " .. tostring(result.exit_status))
  if stderr ~= "" then
    fail("rg failed: " .. tostring(err_msg) .. " - " .. stderr)
  end
  fail("rg failed: " .. tostring(err_msg))
end


return {
  DEFAULT_MAX_RESULTS = DEFAULT_MAX_RESULTS,
  MAX_RESULTS_LIMIT = MAX_RESULTS_LIMIT,
  DEFAULT_CONTEXT_LINES = DEFAULT_CONTEXT_LINES,
  MAX_CONTEXT_LINES = MAX_CONTEXT_LINES,
  DEFAULT_MAX_OUTPUT_BYTES = DEFAULT_MAX_OUTPUT_BYTES,
  MAX_OUTPUT_BYTES_LIMIT = MAX_OUTPUT_BYTES_LIMIT,
  DEFAULT_TIMEOUT_MS = DEFAULT_TIMEOUT_MS,
  MAX_TIMEOUT_MS = MAX_TIMEOUT_MS,
  MAX_SUMMARY_CHARS = MAX_SUMMARY_CHARS,
  fail = fail,
  require_string = require_string,
  optional_bool = optional_bool,
  optional_int = optional_int,
  array_of_strings = array_of_strings,
  validate_project_relative_path = validate_project_relative_path,
  validate_executable_name = validate_executable_name,
  shorten = shorten,
  add_globs = add_globs,
  check_rg_available = check_rg_available,
  parse_output = parse_output,
  append_paths = append_paths,
  validate_paths = validate_paths,
  searched_paths_for = searched_paths_for,
  append_limited_row = append_limited_row,
  execute_rg = execute_rg,
}
