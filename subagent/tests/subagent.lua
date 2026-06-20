local t = sage.test
local h = ctx.pack.require("support.test_helpers")

local function cleanup()
  os.execute("rm -rf " .. h.q(t.path(".sage-tools-subagent-test")))
end

local function script_path(name)
  return t.path(".sage-tools-subagent-test/" .. name)
end

local function write_script(name, content)
  local path = script_path(name)
  h.write_fixture(path, content)
  os.execute("chmod +x " .. h.q(path))
  return path
end

local success_script = [[#!/bin/sh
args=" $* "
prompt_file=""
system_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prompt-file) shift; prompt_file="$1" ;;
    --system-prompt) shift; system_file="$1" ;;
  esac
  shift
done
case "$args" in *" --structured-output "*) ;; *) echo '{"type":"run.failed","status":"failure","error":{"code":"missing_structured","message":"missing structured output"}}'; exit 0 ;; esac
case "$args" in *" --prompt-file "*) ;; *) echo '{"type":"run.failed","status":"failure","error":{"code":"missing_prompt","message":"missing prompt file"}}'; exit 0 ;; esac
case "$args" in *" --system-prompt "*) ;; *) echo '{"type":"run.failed","status":"failure","error":{"code":"missing_system","message":"missing system prompt file"}}'; exit 0 ;; esac
case "$args" in *" --allow-tool read "*) ;; *) echo '{"type":"run.failed","status":"failure","error":{"code":"missing_read","message":"missing read allow-tool"}}'; exit 0 ;; esac
case "$args" in *" --no-extensions "*) ;; *) echo '{"type":"run.failed","status":"failure","error":{"code":"missing_no_extensions","message":"missing no extensions"}}'; exit 0 ;; esac
grep -q 'Inspect the code.' "$prompt_file" || { echo '{"type":"run.failed","status":"failure","error":{"code":"bad_prompt_file","message":"prompt file did not contain task"}}'; exit 0; }
grep -q 'read-only scout' "$system_file" || { echo '{"type":"run.failed","status":"failure","error":{"code":"bad_system_file","message":"system prompt file did not contain scout prompt"}}'; exit 0; }
echo '{"type":"tool.started","tool_name":"read"}'
echo '{"type":"tool.completed","tool_name":"read","status":"success"}'
echo '{"type":"assistant.completed","text":"scout answer"}'
echo '{"type":"run.completed","status":"success"}'
]]

local override_script = [[#!/bin/sh
args=" $* "
for needle in " --provider test-provider " " --model test-model " " --allow-tool read " " --allow-tool rg " " --extension-dir /tmp/sage-tools-subagent-ext "; do
  case "$args" in *"$needle"*) ;; *) echo '{"type":"run.failed","status":"failure","error":{"code":"missing_override","message":"missing override '${needle}'"}}'; exit 0 ;; esac
done
case "$args" in *" --no-extensions "*) echo '{"type":"run.failed","status":"failure","error":{"code":"unexpected_no_extensions","message":"unexpected no extensions"}}'; exit 0 ;; esac
echo '{"type":"assistant.completed","text":"override answer"}'
echo '{"type":"run.completed","status":"success"}'
]]

local failure_script = [[#!/bin/sh
echo '{"type":"tool.started","tool_name":"read"}'
echo '{"type":"tool.failed","tool_name":"read","message":"denied"}'
echo '{"type":"run.failed","status":"failure","error":{"code":"provider_error","message":"child exploded"}}'
printf 'child stderr line\n' >&2
exit 7
]]

local missing_run_completed_script = [[#!/bin/sh
echo '{"type":"assistant.completed","text":"unfinished answer"}'
]]

return {
  ["schema exposes hybrid task, child, and debug fields"] = function()
    local schema = t.schema("subagent")
    t.assert_equal("subagent", schema.name)
    t.assert_equal("sage-tools-subagent", schema.extension)
    t.assert_equal("task", schema.parameters.required[1])
    t.assert_equal("string", schema.parameters.properties.task.type)
    t.assert_equal("string", schema.parameters.properties.label.type)
    t.assert_equal("string", schema.parameters.properties.system_prompt.type)
    t.assert_equal("object", schema.parameters.properties.child.type)
    t.assert_equal("object", schema.parameters.properties.debug.type)
    t.assert_equal("array", schema.parameters.properties.child.properties.tools.type)
    t.assert_equal("object", schema.parameters.properties.child.properties.extensions.type)
  end,

  ["successful child run returns compact summary and final answer"] = function()
    cleanup()
    local child = write_script("success-child.sh", success_script)
    local result = t.call_tool("subagent", {
      task = "Inspect the code.",
      label = "scout",
      child = { sage_executable = child },
    })
    t.assert_tool_success(result)
    t.assert_contains(result.content, "subagent scout: success")
    t.assert_contains(result.content, "scout answer")
    t.assert_equal("success", result.details.outcome)
    t.assert_equal("scout answer", result.details.final_answer)
    t.assert_equal(1, result.details.tool_counts.started)
    t.assert_equal(1, result.details.tool_counts.completed)
    t.assert_equal(0, result.details.tool_counts.failed)
    t.assert_equal("read", result.details.child_policy.tools[1])
    t.assert_equal("none", result.details.child_policy.extensions.mode)
    if result.details.full_output_uri == nil then t.fail("expected full output temp URI") end
    t.assert_contains(result.details.full_output_uri, "temp://subagent/")
    cleanup()
  end,

  ["child failure returns failure details and stderr"] = function()
    cleanup()
    local child = write_script("failure-child.sh", failure_script)
    local result = t.call_tool("subagent", {
      task = "Inspect the code.",
      child = { sage_executable = child },
    })
    t.assert_tool_success(result)
    t.assert_contains(result.content, "subagent scout: failure")
    t.assert_contains(result.content, "child exploded")
    t.assert_equal("failure", result.details.outcome)
    t.assert_equal("provider_error", result.details.failure.code)
    t.assert_equal("child exploded", result.details.failure.message)
    t.assert_equal(7, result.details.process.exit_status)
    t.assert_contains(result.details.process.stderr, "child stderr line")
    t.assert_equal(1, result.details.tool_counts.failed)
    cleanup()
  end,

  ["policy overrides are passed to the child process"] = function()
    cleanup()
    local child = write_script("override-child.sh", override_script)
    local result = t.call_tool("subagent", {
      task = "Inspect the code.",
      child = {
        sage_executable = child,
        provider = "test-provider",
        model = "test-model",
        tools = { "read", "rg" },
        extensions = { mode = "dirs", dirs = { "/tmp/sage-tools-subagent-ext" } },
      },
    })
    t.assert_tool_success(result)
    t.assert_contains(result.content, "override answer")
    t.assert_equal("test-provider", result.details.child_policy.provider)
    t.assert_equal("test-model", result.details.child_policy.model)
    t.assert_equal("read", result.details.child_policy.tools[1])
    t.assert_equal("rg", result.details.child_policy.tools[2])
    t.assert_equal("dirs", result.details.child_policy.extensions.mode)
    t.assert_equal("/tmp/sage-tools-subagent-ext", result.details.child_policy.extensions.dirs[1])
    cleanup()
  end,

  ["debug events include parsed structured child events"] = function()
    cleanup()
    local child = write_script("debug-child.sh", success_script)
    local result = t.call_tool("subagent", {
      task = "Inspect the code.",
      debug = { events = true },
      child = { sage_executable = child },
    })
    t.assert_tool_success(result)
    if result.details.events == nil or #result.details.events == 0 then t.fail("expected debug events") end
    t.assert_equal("assistant.completed", result.details.events[#result.details.events - 1].type)
    t.assert_equal("run.completed", result.details.events[#result.details.events].type)
    cleanup()
  end,

  ["missing run.completed is reported as failure info"] = function()
    cleanup()
    local child = write_script("missing-run-completed-child.sh", missing_run_completed_script)
    local result = t.call_tool("subagent", {
      task = "Inspect the code.",
      child = { sage_executable = child },
    })
    t.assert_tool_success(result)
    t.assert_equal("failure", result.details.outcome)
    t.assert_equal("missing_run_completed", result.details.failure.code)
    t.assert_contains(result.content, "child did not emit run.completed")
    cleanup()
  end,

  ["fractional child timeout is rejected"] = function()
    cleanup()
    local child = write_script("timeout-child.sh", success_script)
    local result = t.call_tool("subagent", {
      task = "Inspect the code.",
      child = { sage_executable = child, timeout_ms = 1.5 },
    })
    t.assert_tool_failure(result, "child.timeout_ms must be a positive integer")
    cleanup()
  end,
}
