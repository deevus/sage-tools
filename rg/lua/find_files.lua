local h = require("helpers")
local DEFAULT_MAX_RESULTS = h.DEFAULT_MAX_RESULTS
local MAX_RESULTS_LIMIT = h.MAX_RESULTS_LIMIT
local DEFAULT_CONTEXT_LINES = h.DEFAULT_CONTEXT_LINES
local MAX_CONTEXT_LINES = h.MAX_CONTEXT_LINES
local DEFAULT_MAX_OUTPUT_BYTES = h.DEFAULT_MAX_OUTPUT_BYTES
local MAX_OUTPUT_BYTES_LIMIT = h.MAX_OUTPUT_BYTES_LIMIT
local DEFAULT_TIMEOUT_MS = h.DEFAULT_TIMEOUT_MS
local MAX_TIMEOUT_MS = h.MAX_TIMEOUT_MS
local MAX_SUMMARY_CHARS = h.MAX_SUMMARY_CHARS
local optional_bool = h.optional_bool
local optional_int = h.optional_int
local array_of_strings = h.array_of_strings
local validate_executable_name = h.validate_executable_name
local shorten = h.shorten
local add_globs = h.add_globs
local check_rg_available = h.check_rg_available
local parse_output = h.parse_output
local append_paths = h.append_paths
local validate_paths = h.validate_paths
local searched_paths_for = h.searched_paths_for
local append_limited_row = h.append_limited_row
local execute_rg = h.execute_rg

-- Helper functions for find_files

local function has_any_hints(filename_hints, content_hints)
  return (filename_hints and #filename_hints > 0) or (content_hints and #content_hints > 0)
end

local function lower(value)
  return string.lower(value or "")
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
