local constants = ctx.pack.require("support.constants")
local output = ctx.pack.require("support.output")
local paths = ctx.pack.require("support.paths")
local validation = ctx.pack.require("support.validation")

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
    validation.fail(message)
  end
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
    validation.fail("rg failed: " .. tostring(err_msg) .. " - " .. stderr)
  end
  validation.fail("rg failed: " .. tostring(err_msg))
end

local function validate_match_limits(input)
  local max_results_info = validation.optional_int(input.max_results, constants.DEFAULT_MAX_RESULTS, 1, constants.MAX_RESULTS_LIMIT, "max_results")
  local context_info = validation.optional_int(input.context_lines, constants.DEFAULT_CONTEXT_LINES, 0, constants.MAX_CONTEXT_LINES, "context_lines")
  local max_bytes_info = validation.optional_int(input.max_output_bytes, constants.DEFAULT_MAX_OUTPUT_BYTES, 1, constants.MAX_OUTPUT_BYTES_LIMIT, "max_output_bytes")
  local timeout_info = validation.optional_int(input.timeout_ms, constants.DEFAULT_TIMEOUT_MS, 1, constants.MAX_TIMEOUT_MS, "timeout_ms")

  return {
    max_results = max_results_info.value,
    max_results_capped = max_results_info.capped,
    context_lines = context_info.value,
    context_lines_capped = context_info.capped,
    max_output_bytes = max_bytes_info.value,
    max_output_bytes_capped = max_bytes_info.capped,
    timeout_ms = timeout_info.value,
    timeout_capped = timeout_info.capped,
  }
end

local function build_match_argv(input, paths_validated, query, options)
  options = options or {}
  local rg_executable = validation.validate_executable_name(input.rg_executable or "rg")
  local include_globs = options.include_globs or validation.array_of_strings(input.include_globs, "include_globs")
  local exclude_globs = options.exclude_globs or validation.array_of_strings(input.exclude_globs, "exclude_globs")
  local context_lines = options.context_lines or constants.DEFAULT_CONTEXT_LINES

  local argv = {
    rg_executable,
    "--line-number",
    "--column",
    "--with-filename",
    "--color", "never",
    "--field-match-separator", "\t",
    "--field-context-separator", "\t",
    "--max-columns", tostring(constants.MAX_SUMMARY_CHARS),
    "--max-columns-preview",
  }

  if options.fixed_strings then
    argv[#argv + 1] = "--fixed-strings"
  end

  if options.word_regexp then
    argv[#argv + 1] = "--word-regexp"
  end

  if validation.optional_bool(input.case_sensitive, true) == false then
    argv[#argv + 1] = "--ignore-case"
  end

  if context_lines > 0 then
    argv[#argv + 1] = "--context"
    argv[#argv + 1] = tostring(context_lines)
  end

  add_globs(argv, include_globs, exclude_globs)

  argv[#argv + 1] = "--"
  argv[#argv + 1] = query
  paths.append_paths(argv, paths_validated)

  return argv, rg_executable
end

local function search_matches(input, paths_validated, query, options)
  options = options or {}
  local limits = options.limits or validate_match_limits(input)
  local argv, rg_executable = build_match_argv(input, paths_validated, query, {
    include_globs = options.include_globs,
    exclude_globs = options.exclude_globs,
    context_lines = limits.context_lines,
    fixed_strings = options.fixed_strings,
    word_regexp = options.word_regexp,
  })

  check_rg_available(rg_executable)

  local result, stdout = execute_rg(argv, limits.timeout_ms)
  local rows, truncated_by_results, truncated_by_output_bytes, total_bytes = output.parse_output(
    stdout, limits.max_results, limits.max_output_bytes
  )

  if options.match_kind then
    for _, row in ipairs(rows) do
      if row.kind == "match" then
        row.kind = options.match_kind
      end
    end
  end

  return {
    rows = rows,
    limits = limits,
    result = result,
    truncated_by_results = truncated_by_results,
    truncated_by_output_bytes = truncated_by_output_bytes,
    truncated = truncated_by_results or truncated_by_output_bytes,
    total_summary_bytes = total_bytes,
    searched_paths = paths.searched_paths_for(paths_validated),
  }
end

local function match_meta(search)
  return {
    searched_paths = search.searched_paths,
    max_results = search.limits.max_results,
    max_results_capped = search.limits.max_results_capped,
    context_lines = search.limits.context_lines,
    context_lines_capped = search.limits.context_lines_capped,
    max_output_bytes = search.limits.max_output_bytes,
    max_output_bytes_capped = search.limits.max_output_bytes_capped,
    timeout_ms = search.limits.timeout_ms,
    timeout_capped = search.limits.timeout_capped,
    truncated = search.truncated,
    truncated_by_results = search.truncated_by_results,
    truncated_by_output_bytes = search.truncated_by_output_bytes,
    stdout_limited = search.result.stdout_limited == true,
    stdout_total_bytes = search.result.stdout_total_bytes or 0,
    exit_status = search.result.exit_status,
    row_count = #search.rows,
    total_summary_bytes = search.total_summary_bytes,
  }
end

return {
  add_globs = add_globs,
  check_rg_available = check_rg_available,
  execute_rg = execute_rg,
  validate_match_limits = validate_match_limits,
  build_match_argv = build_match_argv,
  search_matches = search_matches,
  match_meta = match_meta,
}
