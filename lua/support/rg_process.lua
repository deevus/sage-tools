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

return {
  add_globs = add_globs,
  check_rg_available = check_rg_available,
  execute_rg = execute_rg,
}
