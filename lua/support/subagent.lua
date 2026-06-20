local v = ctx.pack.require("support.validation")

local fail = v.fail
local require_string = v.require_string
local array_of_strings = v.array_of_strings

local DEFAULT_SYSTEM_PROMPT = table.concat({
  "You are a read-only scout subagent.",
  "Inspect the requested code or context and report concise findings.",
  "Do not modify files. Prefer reading and analysis over action.",
}, "\n")

local BUILTIN_CHILD_TOOLS = {
  read = true,
  bash = true,
  apply_patch = true,
  write = true,
  create_temp_output = true,
}

local function sanitize_label(label)
  local sanitized = tostring(label or "scout"):gsub("[^%w._-]", "-")
  if sanitized == "" then return "scout" end
  return sanitized
end

local function unique_uri(label, suffix)
  return "temp://subagent/" .. sanitize_label(label) .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000000)) .. "-" .. suffix
end

local function copy_array(values)
  if values == nil then return nil end
  local copied = {}
  for index, value in ipairs(values) do copied[index] = value end
  return copied
end

local function normalize_child(input)
  local child = input.child or {}
  if type(child) ~= "table" then fail("child must be an object") end

  local tools = array_of_strings(child.tools, "child.tools")
  if tools == nil then tools = { "read" } end

  local extensions = child.extensions or { mode = "none" }
  if type(extensions) ~= "table" then fail("child.extensions must be an object") end
  local extension_mode = extensions.mode or "none"
  if type(extension_mode) ~= "string" then fail("child.extensions.mode must be a string") end
  local extension_dirs = array_of_strings(extensions.dirs, "child.extensions.dirs") or {}

  if extension_mode ~= "none" and extension_mode ~= "default" and extension_mode ~= "dirs" then
    fail("child.extensions.mode must be one of none, default, or dirs")
  end
  if extension_mode == "dirs" and #extension_dirs == 0 then
    fail("child.extensions.dirs must contain at least one directory when mode is dirs")
  end
  if extension_mode == "none" then
    for _, tool in ipairs(tools) do
      if not BUILTIN_CHILD_TOOLS[tool] then
        fail("child.extensions.mode cannot be none when child.tools includes extension tool " .. tool)
      end
    end
  end

  if child.provider ~= nil and type(child.provider) ~= "string" then fail("child.provider must be a string") end
  if child.model ~= nil and type(child.model) ~= "string" then fail("child.model must be a string") end
  if child.sage_executable ~= nil and type(child.sage_executable) ~= "string" then fail("child.sage_executable must be a string") end
  if child.timeout_ms ~= nil and (type(child.timeout_ms) ~= "number" or math.floor(child.timeout_ms) ~= child.timeout_ms or child.timeout_ms < 1) then fail("child.timeout_ms must be a positive integer") end

  return {
    sage_executable = child.sage_executable or child.executable or "sage",
    provider = child.provider,
    model = child.model,
    tools = tools,
    extensions = { mode = extension_mode, dirs = extension_dirs },
    timeout_ms = child.timeout_ms or 120000,
  }
end

local function build_child_argv(policy, prompt_path, system_prompt_path)
  local argv = {
    policy.sage_executable,
    "--prompt-file", prompt_path,
    "--system-prompt", system_prompt_path,
    "--structured-output",
    "--no-streaming",
  }

  if policy.provider then
    argv[#argv + 1] = "--provider"
    argv[#argv + 1] = policy.provider
  end
  if policy.model then
    argv[#argv + 1] = "--model"
    argv[#argv + 1] = policy.model
  end
  for _, tool in ipairs(policy.tools) do
    argv[#argv + 1] = "--allow-tool"
    argv[#argv + 1] = tool
  end

  if policy.extensions.mode == "none" then
    argv[#argv + 1] = "--no-extensions"
  elseif policy.extensions.mode == "dirs" then
    for _, dir in ipairs(policy.extensions.dirs) do
      argv[#argv + 1] = "--extension-dir"
      argv[#argv + 1] = dir
    end
  end

  return argv
end

local function decode_json_string_at(text, index)
  local output = {}
  local pos = index
  while pos <= #text do
    local ch = text:sub(pos, pos)
    if ch == '"' then
      return table.concat(output), pos + 1
    elseif ch == "\\" then
      local escaped = text:sub(pos + 1, pos + 1)
      if escaped == '"' then output[#output + 1] = '"'
      elseif escaped == "\\" then output[#output + 1] = "\\"
      elseif escaped == "/" then output[#output + 1] = "/"
      elseif escaped == "n" then output[#output + 1] = "\n"
      elseif escaped == "r" then output[#output + 1] = "\r"
      elseif escaped == "t" then output[#output + 1] = "\t"
      elseif escaped == "b" then output[#output + 1] = "\b"
      elseif escaped == "f" then output[#output + 1] = "\f"
      else output[#output + 1] = escaped end
      pos = pos + 2
    else
      output[#output + 1] = ch
      pos = pos + 1
    end
  end
  return nil, pos
end

local function json_string_field(line, key)
  local start_pos, end_pos = line:find('"' .. key .. '"%s*:%s*"')
  if not start_pos then return nil end
  return decode_json_string_at(line, end_pos + 1)
end

local function parse_jsonl_events(stdout)
  local events = {}
  local counts = { started = 0, completed = 0, failed = 0 }
  local final_answer = nil
  local failure = nil
  local run_completed = false

  for line in (stdout or ""):gmatch("[^\r\n]+") do
    local event_type = json_string_field(line, "type")
    if event_type then
      local event = { type = event_type }
      if event_type == "assistant.completed" then
        event.text = json_string_field(line, "text") or ""
        final_answer = event.text
      elseif event_type == "tool.started" then
        event.tool_name = json_string_field(line, "tool_name")
        counts.started = counts.started + 1
      elseif event_type == "tool.completed" then
        event.tool_name = json_string_field(line, "tool_name")
        event.status = json_string_field(line, "status")
        counts.completed = counts.completed + 1
      elseif event_type == "tool.failed" then
        event.tool_name = json_string_field(line, "tool_name")
        event.message = json_string_field(line, "message")
        counts.failed = counts.failed + 1
      elseif event_type == "run.completed" then
        event.status = json_string_field(line, "status") or "success"
        run_completed = true
      elseif event_type == "run.failed" then
        event.status = json_string_field(line, "status") or "failure"
        failure = {
          code = json_string_field(line, "code") or "run_failed",
          message = json_string_field(line, "message") or "child run failed",
        }
      end
      events[#events + 1] = event
    end
  end

  return {
    events = events,
    tool_counts = counts,
    final_answer = final_answer,
    failure = failure,
    run_completed = run_completed,
  }
end

local function create_temp_file(callback_ctx, uri, content)
  if callback_ctx.temp_output == nil or callback_ctx.temp_output.create == nil then
    return { ok = false, error = "temp output API unavailable" }
  end
  return callback_ctx.temp_output.create({ uri = uri, kind = "file", content = content })
end

local function write_prompt_files(callback_ctx, label, task, system_prompt)
  local prompt = create_temp_file(callback_ctx, unique_uri(label, "prompt.txt"), task)
  if not prompt.ok then fail(prompt.error or "failed to create child prompt temp output") end
  local system = create_temp_file(callback_ctx, unique_uri(label, "system-prompt.txt"), system_prompt)
  if not system.ok then fail(system.error or "failed to create child system prompt temp output") end
  return prompt, system
end

local function full_output(callback_ctx, label, stdout, stderr)
  local text = "stdout:\n" .. (stdout or "") .. "\nstderr:\n" .. (stderr or "")
  local created = create_temp_file(callback_ctx, unique_uri(label, "full-output.jsonl"), text)
  if created.ok then
    return { uri = created.uri, inline = nil }
  end
  return { uri = nil, inline = text }
end

local function compact_stderr(stderr)
  if type(stderr) ~= "string" or stderr == "" then return nil end
  local first_line = stderr:match("^([^\r\n]+)") or stderr
  if #first_line > 500 then return first_line:sub(1, 500) .. "..." end
  return first_line
end

local function compact_content(label, outcome, parsed)
  local lines = {
    "subagent " .. label .. ": " .. outcome,
    "tools: " .. tostring(parsed.tool_counts.started) .. " started, " .. tostring(parsed.tool_counts.completed) .. " completed, " .. tostring(parsed.tool_counts.failed) .. " failed",
    "",
  }
  if outcome == "failure" and parsed.failure then
    lines[#lines + 1] = parsed.failure.message
  elseif parsed.final_answer and parsed.final_answer ~= "" then
    lines[#lines + 1] = parsed.final_answer
  else
    lines[#lines + 1] = "(no final answer)"
  end
  return table.concat(lines, "\n")
end

local function run(callback_ctx)
  local input = callback_ctx.input or {}
  local task = require_string(input.task, "task")
  local label = input.label or "scout"
  if type(label) ~= "string" then fail("label must be a string") end
  local system_prompt = input.system_prompt or DEFAULT_SYSTEM_PROMPT
  if type(system_prompt) ~= "string" then fail("system_prompt must be a string") end
  local debug = input.debug or {}
  if type(debug) ~= "table" then fail("debug must be an object") end

  local policy = normalize_child(input)
  local prompt_file, system_file = write_prompt_files(callback_ctx, label, task, system_prompt)
  local argv = build_child_argv(policy, prompt_file.path, system_file.path)

  if callback_ctx.status then callback_ctx:status("running subagent " .. label) end
  local process = sage.execute({
    argv = argv,
    cwd = ".",
    capture_output_limit = 1048576,
    timeout_ms = policy.timeout_ms,
  })

  local parsed = parse_jsonl_events(process.stdout or "")
  if not parsed.failure and not process.ok then
    parsed.failure = { code = process.error or "process_failed", message = compact_stderr(process.stderr) or "child process failed" }
  end
  if not parsed.failure and not parsed.run_completed then
    parsed.failure = { code = "missing_run_completed", message = "child did not emit run.completed" }
  end

  local outcome = (process.ok and parsed.failure == nil and parsed.run_completed) and "success" or "failure"
  local stored_output = full_output(callback_ctx, label, process.stdout or "", process.stderr or "")

  local details = {
    outcome = outcome,
    final_answer = parsed.final_answer,
    failure = parsed.failure,
    tool_counts = parsed.tool_counts,
    child_policy = {
      provider = policy.provider,
      model = policy.model,
      tools = copy_array(policy.tools),
      extensions = { mode = policy.extensions.mode, dirs = copy_array(policy.extensions.dirs) or {} },
    },
    process = {
      ok = process.ok,
      exit_status = process.exit_status,
      error = process.error,
      stderr = process.stderr,
      timed_out = process.timed_out,
      cancelled = process.cancelled,
    },
    prompt_uri = prompt_file.uri,
    system_prompt_uri = system_file.uri,
  }
  if stored_output.uri then details.full_output_uri = stored_output.uri else details.full_output_inline = stored_output.inline end
  if debug.events == true then details.events = parsed.events end

  return {
    content = compact_content(label, outcome, parsed),
    details = details,
  }
end

return {
  run = run,
  _build_child_argv = build_child_argv,
  _parse_jsonl_events = parse_jsonl_events,
  _default_system_prompt = DEFAULT_SYSTEM_PROMPT,
}
