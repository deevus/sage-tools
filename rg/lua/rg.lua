local constants = require("constants")
local validation = require("validation")
local rg_process = require("rg_process")
local output = require("output")

local DEFAULT_MAX_RESULTS = constants.DEFAULT_MAX_RESULTS
local MAX_RESULTS_LIMIT = constants.MAX_RESULTS_LIMIT
local DEFAULT_CONTEXT_LINES = constants.DEFAULT_CONTEXT_LINES
local MAX_CONTEXT_LINES = constants.MAX_CONTEXT_LINES
local DEFAULT_MAX_OUTPUT_BYTES = constants.DEFAULT_MAX_OUTPUT_BYTES
local MAX_OUTPUT_BYTES_LIMIT = constants.MAX_OUTPUT_BYTES_LIMIT
local DEFAULT_TIMEOUT_MS = constants.DEFAULT_TIMEOUT_MS
local MAX_TIMEOUT_MS = constants.MAX_TIMEOUT_MS
local MAX_SUMMARY_CHARS = constants.MAX_SUMMARY_CHARS
local fail = validation.fail
local require_string = validation.require_string
local optional_bool = validation.optional_bool
local optional_int = validation.optional_int
local array_of_strings = validation.array_of_strings
local validate_project_relative_path = validation.validate_project_relative_path
local validate_executable_name = validation.validate_executable_name
local add_globs = rg_process.add_globs
local check_rg_available = rg_process.check_rg_available
local parse_output = output.parse_output

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
