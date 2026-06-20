local subagent = ctx.pack.require("support.subagent")

sage.register_tool({
  name = "subagent",
  description = "Run one blocking child Sage prompt as a read-only scout by default and return a compact summary plus the final child answer.",
  parameters = {
    properties = {
      task = {
        type = "string",
        description = "Task for the child Sage scout prompt.",
      },
      label = {
        type = "string",
        description = "Short label used in summaries and temp-output names. Defaults to scout.",
      },
      system_prompt = {
        type = "string",
        description = "Optional child system prompt. Defaults to a read-only scout role.",
      },
      child = {
        type = "object",
        description = "Child Sage runtime and policy overrides.",
        properties = {
          sage_executable = {
            type = "string",
            description = "Child Sage executable path or command. Defaults to sage.",
          },
          provider = {
            type = "string",
            description = "Optional child provider id passed with --provider.",
          },
          model = {
            type = "string",
            description = "Optional child model id or provider/model ref passed with --model, for example provider/model.",
          },
          tools = {
            type = "array",
            description = "Allowed child tools passed as repeated --allow-tool flags. Defaults to read.",
            items = { type = "string" },
          },
          timeout_ms = {
            type = "integer",
            description = "Child process timeout in milliseconds. Defaults to 120000.",
            minimum = 1,
          },
          extensions = {
            type = "object",
            description = "Child extension loading policy. Defaults to mode none.",
            properties = {
              mode = {
                type = "string",
                description = "Extension mode: none, default, or dirs.",
              },
              dirs = {
                type = "array",
                description = "Extension directories for mode dirs, passed as repeated --extension-dir flags.",
                items = { type = "string" },
              },
            },
          },
        },
      },
      debug = {
        type = "object",
        description = "Debug output options.",
        properties = {
          events = {
            type = "boolean",
            description = "When true, include parsed structured child events in details.events.",
          },
        },
      },
    },
    required = { "task" },
  },
  handler = function(callback_ctx)
    return subagent.run(callback_ctx)
  end,
})
