local t = sage.test
local h = ctx.pack.require("support.test_helpers")

local function cleanup()
  local test_dir = t.path(".sage-tools-rg-test")
  os.execute("rm -rf " .. h.q(test_dir))
end

local write_fixture = h.write_fixture

local function fixture_path(relative)
  return t.path(".sage-tools-rg-test/" .. relative)
end

local function assert_not_contains(haystack, needle, message)
  h.assert_not_contains(t, haystack, needle, message)
end

return {
  ["schema exposes find_references tool with guided exact lookup parameters"] = function()
    local schema = t.schema("find_references")
    t.assert_equal("find_references", schema.name)
    t.assert_equal("sage-tools-rg", schema.extension)
    t.assert_equal("find_references", schema.display_name)
    t.assert_equal("string", schema.parameters.properties.identifier.type)
    t.assert_equal("string", schema.parameters.properties.text.type)
    t.assert_equal("array", schema.parameters.properties.paths.type)
    t.assert_equal("array", schema.parameters.properties.include_globs.type)
    t.assert_equal("array", schema.parameters.properties.exclude_globs.type)
    t.assert_equal("boolean", schema.parameters.properties.case_sensitive.type)
    t.assert_equal("integer", schema.parameters.properties.context_lines.type)
    t.assert_equal("integer", schema.parameters.properties.max_results.type)
    t.assert_equal("integer", schema.parameters.properties.max_output_bytes.type)
    t.assert_equal("integer", schema.parameters.properties.timeout_ms.type)
    t.assert_equal("string", schema.parameters.properties.rg_executable.type)
  end,

  ["identifier lookup is exact and word-boundary limited"] = function()
    cleanup()
    write_fixture(fixture_path("refs/alpha.lua"), "local foo = 1\nlocal foobar = 2\nreturn foo\n")
    local result = t.call_tool("find_references", {
      identifier = "foo",
      paths = { ".sage-tools-rg-test/refs" },
    })
    t.assert_tool_success(result)
    t.assert_equal(2, result.details.meta.row_count)
    t.assert_equal("identifier", result.details.meta.mode)
    t.assert_equal("foo", result.details.meta.query)
    t.assert_equal(".sage-tools-rg-test/refs", result.details.meta.searched_paths[1])
    for _, row in ipairs(result.details.rows) do
      t.assert_equal("reference", row.kind)
      t.assert_contains(row.path, "alpha.lua")
      assert_not_contains(row.summary, "foobar", "identifier lookup must not return foobar-only lines")
    end
    t.assert_contains(result.content, 'identifier: "foo"')
    t.assert_contains(result.content, "paths:")
    t.assert_contains(result.content, "2 rows")
    cleanup()
  end,

  ["text lookup is literal and can include punctuation"] = function()
    cleanup()
    write_fixture(fixture_path("text/member.lua"), "ctx.pack.require('support.output')\nctxXpackXrequire\n")
    local result = t.call_tool("find_references", {
      text = "ctx.pack.require",
      paths = { ".sage-tools-rg-test/text" },
    })
    t.assert_tool_success(result)
    t.assert_equal(1, result.details.meta.row_count)
    t.assert_equal("text", result.details.meta.mode)
    t.assert_equal("ctx.pack.require", result.details.meta.query)
    t.assert_contains(result.details.rows[1].summary, "ctx.pack.require")
    t.assert_contains(result.content, 'text: "ctx.pack.require"')
    cleanup()
  end,

  ["include_globs and exclude_globs filter reference results"] = function()
    cleanup()
    write_fixture(fixture_path("filters/keep.lua"), "filter_token\n")
    write_fixture(fixture_path("filters/drop.lua"), "filter_token\n")
    write_fixture(fixture_path("filters/keep.md"), "filter_token\n")
    local result = t.call_tool("find_references", {
      identifier = "filter_token",
      paths = { ".sage-tools-rg-test/filters" },
      include_globs = { "*.lua" },
      exclude_globs = { "drop.lua" },
    })
    t.assert_tool_success(result)
    t.assert_equal(1, result.details.meta.row_count)
    t.assert_contains(result.details.rows[1].path, "keep.lua")
    assert_not_contains(result.details.rows[1].path, "drop.lua")
    assert_not_contains(result.details.rows[1].path, "keep.md")
    cleanup()
  end,

  ["max_results limits returned reference rows"] = function()
    cleanup()
    write_fixture(fixture_path("limit/a.lua"), "limit_token\n")
    write_fixture(fixture_path("limit/b.lua"), "limit_token\n")
    local result = t.call_tool("find_references", {
      identifier = "limit_token",
      paths = { ".sage-tools-rg-test/limit" },
      max_results = 1,
    })
    t.assert_tool_success(result)
    t.assert_equal(1, result.details.meta.row_count)
    t.assert_equal(true, result.details.meta.truncated_by_results)
    t.assert_contains(result.content, "1 row")
    t.assert_contains(result.content, "results truncated")
    assert_not_contains(result.content, "1 rows", "singular must be '1 row', not '1 rows'")
    cleanup()
  end,

  ["no-match succeeds with zero reference rows"] = function()
    cleanup()
    write_fixture(fixture_path("nomatch/plain.lua"), "local present = true\n")
    local result = t.call_tool("find_references", {
      text = "missing-token",
      paths = { ".sage-tools-rg-test/nomatch" },
    })
    t.assert_tool_success(result)
    t.assert_equal(0, result.details.meta.row_count)
    t.assert_equal(0, #result.details.rows)
    t.assert_equal("text", result.details.meta.mode)
    t.assert_contains(result.content, 'text: "missing-token"')
    t.assert_contains(result.content, "no matches")
    cleanup()
  end,

  ["max_output_bytes limits reference row summaries"] = function()
    cleanup()
    write_fixture(fixture_path("bytes/long.lua"), "the byte_limit_token line has a long summary\n")
    local result = t.call_tool("find_references", {
      identifier = "byte_limit_token",
      paths = { ".sage-tools-rg-test/bytes" },
      max_output_bytes = 5,
    })
    t.assert_tool_success(result)
    t.assert_equal(0, result.details.meta.row_count)
    t.assert_equal(true, result.details.meta.truncated_by_output_bytes)
    t.assert_contains(result.content, "results truncated")
    cleanup()
  end,

  ["requires exactly one of identifier or text"] = function()
    local neither = t.call_tool("find_references", {})
    t.assert_tool_failure(neither, "exactly one of identifier or text")

    local both = t.call_tool("find_references", {
      identifier = "foo",
      text = "foo",
    })
    t.assert_tool_failure(both, "exactly one of identifier or text")
  end,

  ["rejects empty and multiline reference queries"] = function()
    local empty = t.call_tool("find_references", { text = "" })
    t.assert_tool_failure(empty, "must not be empty")

    local multiline = t.call_tool("find_references", { text = "foo\nbar" })
    t.assert_tool_failure(multiline, "must not contain newlines")

    local nul = t.call_tool("find_references", { text = "foo\0bar" })
    t.assert_tool_failure(nul, "NUL")
  end,

  ["context_lines is capped and context rows are returned"] = function()
    cleanup()
    write_fixture(fixture_path("ctx/a.lua"), "before\nneedle\nafter\n")
    local result = t.call_tool("find_references", {
      text = "needle",
      paths = { ".sage-tools-rg-test/ctx" },
      context_lines = 99,
    })
    t.assert_tool_success(result)
    t.assert_equal(3, result.details.meta.context_lines)
    t.assert_equal(true, result.details.meta.context_lines_capped)
    t.assert_equal(3, result.details.meta.row_count)
    cleanup()
  end,
}
