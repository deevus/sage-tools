local v = ctx.pack.require("support.validation")
local p = ctx.pack.require("support.paths")
local r = ctx.pack.require("support.rg_process")
local o = ctx.pack.require("support.output")

local function validate_query(value, label)
  v.require_string(value, label)
  if value == "" then v.fail(label .. " must not be empty") end
  if value:find("\0", 1, true) then v.fail(label .. " must not contain NUL bytes") end
  if value:find("\n", 1, true) or value:find("\r", 1, true) then
    v.fail(label .. " must not contain newlines")
  end
  return value
end

local function selected_query(input)
  local has_identifier = input.identifier ~= nil
  local has_text = input.text ~= nil
  if has_identifier == has_text then
    v.fail("find_references requires exactly one of identifier or text")
  end
  if has_identifier then
    return "identifier", validate_query(input.identifier, "identifier")
  end
  return "text", validate_query(input.text, "text")
end

return {
  name = "find_references",
  description = "Find exact text or identifier references in the active project with compact, limited match rows. Searches are project-root confined, avoid arbitrary regex input, and follow ripgrep ignore rules. Use identifier for literal word-boundary matching, or text for exact literal text including punctuation and member references.",
  parameters = {
    properties = {
      identifier = { type = "string", description = "Exact text to find with ripgrep word-boundary matching. Not a regex; use text for punctuation-heavy member references." },
      text = { type = "string", description = "Exact literal text to find. Not a regex." },
      paths = { type = "array", description = "Project-relative files or directories to search. Defaults to the project root.", items = { type = "string", description = "Project-relative file or directory path." } },
      include_globs = { type = "array", description = "Additional ripgrep --glob include patterns.", items = { type = "string", description = "Ripgrep glob pattern to include." } },
      exclude_globs = { type = "array", description = "Additional ripgrep --glob exclude patterns.", items = { type = "string", description = "Ripgrep glob pattern to exclude." } },
      case_sensitive = { type = "boolean", description = "When false, pass --ignore-case. Defaults to case-sensitive behavior." },
      context_lines = { type = "integer", description = "Context lines before and after each match. Capped at 3.", minimum = 0 },
      max_results = { type = "integer", description = "Maximum rows to return. Capped at 500.", minimum = 1 },
      max_output_bytes = { type = "integer", description = "Maximum total bytes of row summaries returned in details/content. Capped at 65536.", minimum = 1 },
      timeout_ms = { type = "integer", description = "Ripgrep timeout in milliseconds. Capped at 10000.", minimum = 1 },
      rg_executable = { type = "string", description = "Optional ripgrep executable name for testing or custom PATH installs. Defaults to rg; path separators are rejected." },
    },
  },
  handler = function(callback_ctx)
    local input = callback_ctx.input
    local mode, query = selected_query(input)
    local paths_validated = p.validate_paths(input)
    local include_globs = v.array_of_strings(input.include_globs, "include_globs")
    local exclude_globs = v.array_of_strings(input.exclude_globs, "exclude_globs")

    local search = r.search_matches(input, paths_validated, query, {
      include_globs = include_globs,
      exclude_globs = exclude_globs,
      fixed_strings = true,
      word_regexp = mode == "identifier",
      match_kind = "reference",
    })
    local rows = search.rows
    local meta = r.match_meta(search)
    meta.mode = mode
    meta.query = query

    local content_lines = {}
    content_lines[#content_lines + 1] = mode .. ': "' .. query .. '"'
    if mode == "identifier" then
      content_lines[#content_lines + 1] = "mode: identifier (fixed string, word-boundary)"
    else
      content_lines[#content_lines + 1] = "mode: text (fixed string)"
    end
    if paths_validated and #paths_validated > 0 then
      content_lines[#content_lines + 1] = "paths: " .. table.concat(paths_validated, ", ")
    end
    content_lines[#content_lines + 1] = ""
    if #rows == 0 then
      content_lines[#content_lines + 1] = "no matches"
    else
      content_lines[#content_lines + 1] = o.pluralize(#rows, "row")
      for _, row in ipairs(rows) do
        local line_str = row.path .. ":" .. tostring(row.line)
        if row.column then
          line_str = line_str .. ":" .. tostring(row.column)
        end
        line_str = line_str .. ": " .. (row.summary or "")
        content_lines[#content_lines + 1] = line_str
      end
    end
    if meta.truncated then
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
}
