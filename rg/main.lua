sage.register_tool({
  name = "rg",
  description = "Search the active project with ripgrep and return compact, limited match rows. This is the raw ripgrep escape hatch for unsupported patterns; searches are project-root confined and use safety limits/default excludes.",
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
    -- implemented in Task 3
    return {
      content = "rg skeleton",
      details = {},
    }
  end,
})