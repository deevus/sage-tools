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

-- Build the rg argv from user inputs
local function build_rg_argv(input, paths_validated)
  local rg_executable = validate_executable_name(input.rg_executable or "rg")
  local context_info = optional_int(input.context_lines, DEFAULT_CONTEXT_LINES, 0, MAX_CONTEXT_LINES, "context_lines")
  local context_lines = context_info.value

  local argv = {
    rg_executable,
    "--line-number",
    "--column",
    "--with-filename",
    "--color", "never",
    "--field-match-separator", "\t",
    "--field-context-separator", "\t",
    "--max-columns", tostring(MAX_SUMMARY_CHARS),
    "--max-columns-preview",
  }

  if input.fixed_strings then
    argv[#argv + 1] = "--fixed-strings"
  end

  if optional_bool(input.case_sensitive, true) == false then
    argv[#argv + 1] = "--ignore-case"
  end

  if context_lines > 0 then
    argv[#argv + 1] = "--context"
    argv[#argv + 1] = tostring(context_lines)
  end

  local include_globs = array_of_strings(input.include_globs, "include_globs")
  local exclude_globs = array_of_strings(input.exclude_globs, "exclude_globs")
  add_globs(argv, include_globs, exclude_globs)

  -- Pattern and paths
  argv[#argv + 1] = "--"
  argv[#argv + 1] = input.pattern
  if paths_validated and #paths_validated > 0 then
    for _, p in ipairs(paths_validated) do
      argv[#argv + 1] = p
    end
  else
    argv[#argv + 1] = "."
  end

  return argv, rg_executable, context_lines
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

-- Helper functions for find_files

local function has_any_hints(filename_hints, content_hints)
  return (filename_hints and #filename_hints > 0) or (content_hints and #content_hints > 0)
end

local function lower(value)
  return string.lower(value or "")
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

local function filename_matches(path, filename_hints)
  local path_lower = lower(path)
  local matched = {}
  for _, hint in ipairs(filename_hints or {}) do
    if hint ~= "" and path_lower:find(lower(hint), 1, true) then
      matched[#matched + 1] = hint
    end
  end
  return matched
end

local function parse_files_output(stdout, filename_hints, rows, state, max_results, max_output_bytes)
  local pos = 1
  while pos <= #stdout do
    local next_newline = stdout:find("\n", pos, true)
    local path
    if next_newline then
      path = stdout:sub(pos, next_newline - 1)
      pos = next_newline + 1
    else
      path = stdout:sub(pos)
      pos = #stdout + 1
    end
    if path ~= "" then
      local matched = filename_matches(path, filename_hints)
      if #matched > 0 then
        local row = {
          path = path,
          kind = "filename",
          summary = shorten("filename matched: " .. table.concat(matched, ", ")),
        }
        if not append_limited_row(rows, row, state, max_results, max_output_bytes) then
          break
        end
      end
    end
  end
end

local function build_files_argv(input, paths_validated, include_globs, exclude_globs)
  local rg_executable = validate_executable_name(input.rg_executable or "rg")
  local argv = {
    rg_executable,
    "--files",
    "--color", "never",
  }
  add_globs(argv, include_globs, exclude_globs)
  append_paths(argv, paths_validated)
  return argv
end

local function build_content_argv(input, pattern, paths_validated, include_globs, exclude_globs, context_lines)
  local rg_executable = validate_executable_name(input.rg_executable or "rg")
  local argv = {
    rg_executable,
    "--line-number",
    "--column",
    "--with-filename",
    "--color", "never",
    "--field-match-separator", "\t",
    "--field-context-separator", "\t",
    "--max-columns", tostring(MAX_SUMMARY_CHARS),
    "--max-columns-preview",
  }
  if input.fixed_strings then
    argv[#argv + 1] = "--fixed-strings"
  end
  if optional_bool(input.case_sensitive, true) == false then
    argv[#argv + 1] = "--ignore-case"
  end
  if context_lines > 0 then
    argv[#argv + 1] = "--context"
    argv[#argv + 1] = tostring(context_lines)
  end
  add_globs(argv, include_globs, exclude_globs)
  argv[#argv + 1] = "--"
  argv[#argv + 1] = pattern
  append_paths(argv, paths_validated)
  return argv
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

sage.register_tool({
  name = "rg",
  description = "Search the active project with ripgrep and return compact, limited match rows. This is the raw ripgrep escape hatch for unsupported patterns; searches are project-root confined with safety limits. Ripgrep's own ignore rules (.gitignore, .ignore, .rgignore) apply automatically. Use include_globs and exclude_globs to add project-specific narrowing or noise reduction for directories like node_modules, build artifacts, or generated files.",
  parameters = {
    properties = {
      pattern = { type = "string", description = "Ripgrep search pattern. Interpreted as regex unless fixed_strings is true." },
      paths = { type = "array", description = "Project-relative files or directories to search. Defaults to the project root.", items = { type = "string", description = "Project-relative file or directory path." } },
      include_globs = { type = "array", description = "Additional ripgrep --glob include patterns.", items = { type = "string", description = "Ripgrep glob pattern to include." } },
      exclude_globs = { type = "array", description = "Additional ripgrep --glob exclude patterns.", items = { type = "string", description = "Ripgrep glob pattern to exclude." } },
      fixed_strings = { type = "boolean", description = "Treat pattern as literal text instead of a regex." },
      case_sensitive = { type = "boolean", description = "When false, pass --ignore-case. Defaults to ripgrep's case-sensitive behavior." },
      context_lines = { type = "integer", description = "Context lines before and after each match. Capped at 3.", minimum = 0 },
      max_results = { type = "integer", description = "Maximum rows to return. Capped at 500.", minimum = 1 },
      max_output_bytes = { type = "integer", description = "Maximum total bytes of row summaries returned in details/content. Capped at 65536.", minimum = 1 },
      timeout_ms = { type = "integer", description = "Ripgrep timeout in milliseconds. Capped at 10000.", minimum = 1 },
      rg_executable = { type = "string", description = "Optional ripgrep executable name for testing or custom PATH installs. Defaults to rg; path separators are rejected." },
    },
    required = { "pattern" },
  },
  handler = function(callback_ctx)
    local input = callback_ctx.input
    local rg_executable = input.rg_executable or "rg"

    -- Validate and cap inputs
    local max_results_info = optional_int(input.max_results, DEFAULT_MAX_RESULTS, 1, MAX_RESULTS_LIMIT, "max_results")
    local max_results = max_results_info.value
    local context_info = optional_int(input.context_lines, DEFAULT_CONTEXT_LINES, 0, MAX_CONTEXT_LINES, "context_lines")
    local context_lines = context_info.value
    local max_bytes_info = optional_int(input.max_output_bytes, DEFAULT_MAX_OUTPUT_BYTES, 1, MAX_OUTPUT_BYTES_LIMIT, "max_output_bytes")
    local max_output_bytes = max_bytes_info.value
    local timeout_info = optional_int(input.timeout_ms, DEFAULT_TIMEOUT_MS, 1, MAX_TIMEOUT_MS, "timeout_ms")
    local timeout_ms = timeout_info.value

    require_string(input.pattern, "pattern")

    -- Validate paths
    local paths_raw = array_of_strings(input.paths, "paths")
    local paths_validated = {}
    if paths_raw then
      for _, p in ipairs(paths_raw) do
        validate_project_relative_path(p)
        paths_validated[#paths_validated + 1] = p
      end
    end

    -- Validate executable name
    validate_executable_name(rg_executable)

    -- Check rg is available
    check_rg_available(rg_executable)

    -- Build argv
    local argv, effective_executable, effective_context = build_rg_argv(input, paths_validated)
    _ = effective_executable

    -- Execute rg
    local result = sage.execute({
      argv = argv,
      cwd = ".",
      capture_output_limit = 1048576,
      timeout_ms = timeout_ms,
    })

    -- Handle non-zero exit
    local stdout = ""
    if result.ok then
      stdout = result.stdout or ""
    elseif result.exit_status == 1 then
      -- Exit code 1 means no matches (not an error)
      if not result.error then
        stdout = ""
      else
        -- Process error (e.g., output limit) even with exit code 1
        fail("rg failed: " .. tostring(result.error))
      end
    else
      -- Any other failure
      local stderr = result.stderr or ""
      local err_msg = result.error or ("exit status " .. tostring(result.exit_status))
      if stderr ~= "" then
        fail("rg failed: " .. tostring(err_msg) .. " - " .. stderr)
      else
        fail("rg failed: " .. tostring(err_msg))
      end
    end

    -- Parse output
    local searched_paths = {}
    if paths_validated and #paths_validated > 0 then
      for _, p in ipairs(paths_validated) do
        searched_paths[#searched_paths + 1] = p
      end
    else
      searched_paths = { "." }
    end

    local rows, truncated_by_results, truncated_by_output_bytes, total_bytes = parse_output(
      stdout, max_results, max_output_bytes, context_lines
    )

    local truncated = truncated_by_results or truncated_by_output_bytes

    -- Build meta
    local meta = {
      pattern = input.pattern,
      searched_paths = searched_paths,
      max_results = max_results,
      max_results_capped = max_results_info.capped,
      context_lines = effective_context,
      context_lines_capped = context_info.capped,
      max_output_bytes = max_output_bytes,
      max_output_bytes_capped = max_bytes_info.capped,
      timeout_ms = timeout_ms,
      timeout_capped = timeout_info.capped,
      truncated = truncated,
      truncated_by_results = truncated_by_results,
      truncated_by_output_bytes = truncated_by_output_bytes,
      stdout_limited = result.stdout_limited == true,
      stdout_total_bytes = result.stdout_total_bytes or 0,
      exit_status = result.exit_status,
      row_count = #rows,
      total_summary_bytes = total_bytes,
    }

    -- Build compact content
    -- Format: pattern line, optional mode/paths, blank line, then count/rows/truncation.
    local content_lines = {}
    content_lines[#content_lines + 1] = 'pattern: "' .. input.pattern .. '"'
    if input.fixed_strings then
      content_lines[#content_lines + 1] = "mode: fixed string"
    end
    if paths_validated and #paths_validated > 0 then
      content_lines[#content_lines + 1] = "paths: " .. table.concat(paths_validated, ", ")
    end
    content_lines[#content_lines + 1] = ""
    if #rows == 0 then
      content_lines[#content_lines + 1] = "no matches"
    else
      if #rows == 1 then
        content_lines[#content_lines + 1] = "1 row"
      else
        content_lines[#content_lines + 1] = tostring(#rows) .. " rows"
      end
      for _, row in ipairs(rows) do
        local line_str = row.path .. ":" .. tostring(row.line)
        if row.column then
          line_str = line_str .. ":" .. tostring(row.column)
        end
        line_str = line_str .. ": " .. (row.summary or "")
        content_lines[#content_lines + 1] = line_str
      end
    end
    if truncated then
      content_lines[#content_lines + 1] = "results truncated"
    end

    return {
      content = table.concat(content_lines, "\n"),
      details = {
        rows = rows,
        meta = meta,
      },
    }
  end,
})

sage.register_tool({
  name = "find_files",
  description = "Find likely relevant project files by filename and/or content hints. Uses ripgrep, remains project-root confined, follows ripgrep ignore rules, and returns compact file-oriented rows with shared safety limits.",
  parameters = {
    properties = {
      filename_hints = { type = "array", description = "Case-insensitive literal fragments to match against project-relative file paths.", items = { type = "string", description = "Filename or path fragment." } },
      content_hints = { type = "array", description = "Content patterns to search. Regex by default, literal when fixed_strings is true.", items = { type = "string", description = "Content search pattern." } },
      paths = { type = "array", description = "Project-relative files or directories to search. Defaults to the project root.", items = { type = "string", description = "Project-relative file or directory path." } },
      include_globs = { type = "array", description = "Additional ripgrep --glob include patterns.", items = { type = "string", description = "Ripgrep glob pattern to include." } },
      exclude_globs = { type = "array", description = "Additional ripgrep --glob exclude patterns.", items = { type = "string", description = "Ripgrep glob pattern to exclude." } },
      fixed_strings = { type = "boolean", description = "Treat content hints as literal text instead of regex patterns." },
      case_sensitive = { type = "boolean", description = "When false, pass --ignore-case for content hints. Filename hint matching is always case-insensitive." },
      context_lines = { type = "integer", description = "Context lines before and after each content match. Capped at 3.", minimum = 0 },
      max_results = { type = "integer", description = "Maximum rows to return across filename and content matches. Capped at 500.", minimum = 1 },
      max_output_bytes = { type = "integer", description = "Maximum total bytes of row summaries returned in details/content. Capped at 65536.", minimum = 1 },
      timeout_ms = { type = "integer", description = "Ripgrep timeout in milliseconds for each ripgrep invocation. Capped at 10000.", minimum = 1 },
      rg_executable = { type = "string", description = "Optional ripgrep executable name for testing or custom PATH installs. Defaults to rg; path separators are rejected." },
    },
  },
  handler = function(callback_ctx)
    local input = callback_ctx.input
    local filename_hints = array_of_strings(input.filename_hints, "filename_hints") or {}
    local content_hints = array_of_strings(input.content_hints, "content_hints") or {}
    local include_globs = array_of_strings(input.include_globs, "include_globs")
    local exclude_globs = array_of_strings(input.exclude_globs, "exclude_globs")

    local max_results_info = optional_int(input.max_results, DEFAULT_MAX_RESULTS, 1, MAX_RESULTS_LIMIT, "max_results")
    local max_results = max_results_info.value
    local context_info = optional_int(input.context_lines, DEFAULT_CONTEXT_LINES, 0, MAX_CONTEXT_LINES, "context_lines")
    local context_lines = context_info.value
    local max_bytes_info = optional_int(input.max_output_bytes, DEFAULT_MAX_OUTPUT_BYTES, 1, MAX_OUTPUT_BYTES_LIMIT, "max_output_bytes")
    local max_output_bytes = max_bytes_info.value
    local timeout_info = optional_int(input.timeout_ms, DEFAULT_TIMEOUT_MS, 1, MAX_TIMEOUT_MS, "timeout_ms")
    local timeout_ms = timeout_info.value

    local rg_executable = input.rg_executable or "rg"
    validate_executable_name(rg_executable)
    local paths_validated = validate_paths(input)
    check_rg_available(rg_executable)

    local rows = {}
    local state = {
      truncated_by_results = false,
      truncated_by_output_bytes = false,
      stdout_limited = false,
      stdout_total_bytes = 0,
      total_summary_bytes = 0,
    }

    if has_any_hints(filename_hints, content_hints) then
      if #filename_hints > 0 then
        local files_result, files_stdout = execute_rg(build_files_argv(input, paths_validated, include_globs, exclude_globs), timeout_ms)
        state.stdout_limited = state.stdout_limited or files_result.stdout_limited == true
        state.stdout_total_bytes = state.stdout_total_bytes + (files_result.stdout_total_bytes or 0)
        parse_files_output(files_stdout, filename_hints, rows, state, max_results, max_output_bytes)
      end

      if not state.truncated_by_results and not state.truncated_by_output_bytes then
        for _, hint in ipairs(content_hints) do
          if hint ~= "" then
            local content_result, content_stdout = execute_rg(build_content_argv(input, hint, paths_validated, include_globs, exclude_globs, context_lines), timeout_ms)
            state.stdout_limited = state.stdout_limited or content_result.stdout_limited == true
            state.stdout_total_bytes = state.stdout_total_bytes + (content_result.stdout_total_bytes or 0)
            local parsed_rows, truncated_by_results, truncated_by_output_bytes, parsed_bytes = parse_output(content_stdout, max_results - #rows, max_output_bytes - state.total_summary_bytes, context_lines)
            state.truncated_by_results = state.truncated_by_results or truncated_by_results
            state.truncated_by_output_bytes = state.truncated_by_output_bytes or truncated_by_output_bytes
            state.total_summary_bytes = state.total_summary_bytes + parsed_bytes
            for _, row in ipairs(parsed_rows) do
              row.kind = "content"
              rows[#rows + 1] = row
            end
            if state.truncated_by_results or state.truncated_by_output_bytes then
              break
            end
          end
        end
      end
    end

    local truncated = state.truncated_by_results or state.truncated_by_output_bytes
    local meta = {
      filename_hints = filename_hints,
      content_hints = content_hints,
      searched_paths = searched_paths_for(paths_validated),
      max_results = max_results,
      max_results_capped = max_results_info.capped,
      context_lines = context_lines,
      context_lines_capped = context_info.capped,
      max_output_bytes = max_output_bytes,
      max_output_bytes_capped = max_bytes_info.capped,
      timeout_ms = timeout_ms,
      timeout_capped = timeout_info.capped,
      truncated = truncated,
      truncated_by_results = state.truncated_by_results,
      truncated_by_output_bytes = state.truncated_by_output_bytes,
      stdout_limited = state.stdout_limited,
      stdout_total_bytes = state.stdout_total_bytes,
      row_count = #rows,
      total_summary_bytes = state.total_summary_bytes,
    }

    local content_lines = {}
    if #filename_hints > 0 then
      content_lines[#content_lines + 1] = "filename_hints: " .. table.concat(filename_hints, ", ")
    end
    if #content_hints > 0 then
      content_lines[#content_lines + 1] = "content_hints: " .. table.concat(content_hints, ", ")
    end
    if input.fixed_strings then
      content_lines[#content_lines + 1] = "mode: fixed string"
    end
    if paths_validated and #paths_validated > 0 then
      content_lines[#content_lines + 1] = "paths: " .. table.concat(paths_validated, ", ")
    end
    content_lines[#content_lines + 1] = ""
    if #rows == 0 then
      content_lines[#content_lines + 1] = "no matches"
    elseif #rows == 1 then
      content_lines[#content_lines + 1] = "1 row"
    else
      content_lines[#content_lines + 1] = tostring(#rows) .. " rows"
    end
    for _, row in ipairs(rows) do
      local line_str = row.path
      if row.line then
        line_str = line_str .. ":" .. tostring(row.line)
        if row.column then
          line_str = line_str .. ":" .. tostring(row.column)
        end
      end
      line_str = line_str .. ": " .. (row.summary or "")
      content_lines[#content_lines + 1] = line_str
    end
    if truncated then
      content_lines[#content_lines + 1] = "results truncated"
    end

    return {
      content = table.concat(content_lines, "\n"),
      details = {
        rows = rows,
        meta = meta,
      },
    }
  end,
})
