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
  ["pack-level test helper is available to rg tests"] = function()
    t.assert_equal("sage-tools-test-helper", h.label)
  end,

  ["schema exposes rg tool with correct metadata and parameter types"] = function()
    local schema = t.schema("rg")
    t.assert_equal("rg", schema.name)
    t.assert_equal("sage-tools-rg", schema.extension)
    t.assert_equal("rg", schema.display_name)
    t.assert_equal("pattern", schema.parameters.required[1])
    t.assert_equal("string", schema.parameters.properties.pattern.type)
    t.assert_equal("array", schema.parameters.properties.paths.type)
    t.assert_equal("integer", schema.parameters.properties.max_results.type)
  end,

  ["search returns match rows with path, line, column, and summary"] = function()
    cleanup()
    write_fixture(fixture_path("src/alpha.txt"), "alpha bravo charlie\ndelta echo foxtrot\n")
    local result = t.call_tool("rg", {
      pattern = "alpha",
      paths = { ".sage-tools-rg-test/src" },
    })
    t.assert_tool_success(result)
    t.assert_equal(1, result.details.meta.row_count)
    t.assert_equal(1, #result.details.rows)
    local row = result.details.rows[1]
    t.assert_contains(row.path, ".sage-tools-rg-test/src/alpha.txt")
    t.assert_equal(1, row.line)
    t.assert_equal(1, row.column)
    t.assert_equal("match", row.kind)
    t.assert_contains(row.summary, "alpha")
    -- Content begins with pattern line
    t.assert_contains(result.content, 'pattern: "alpha"')
    -- Content includes paths line (non-default paths)
    t.assert_contains(result.content, "paths:")
    -- Content uses unprefixed count
    t.assert_contains(result.content, "1 row")
    assert_not_contains(result.content, "1 rows", "singular must be '1 row', not '1 rows'")
    -- Content must NOT contain old "rg:" prefix
    assert_not_contains(result.content, "rg: 1")
    cleanup()
  end,

  ["no match returns success with zero rows"] = function()
    cleanup()
    write_fixture(fixture_path("nomatch/delta.txt"), "epsilon zeta eta\n")
    local result = t.call_tool("rg", {
      pattern = "zzz_nonexistent_zzz",
      paths = { ".sage-tools-rg-test/nomatch" },
    })
    t.assert_tool_success(result)
    t.assert_equal(0, result.details.meta.row_count)
    t.assert_equal(0, #result.details.rows)
    t.assert_contains(result.content, 'pattern: "zzz_nonexistent_zzz"')
    t.assert_contains(result.content, "paths:")
    t.assert_contains(result.content, "no matches")
    assert_not_contains(result.content, "rg: no matches")
    cleanup()
  end,

  ["tool does not impose default exclude globs; caller can exclude with exclude_globs"] = function()
    -- Without a .gitignore or caller exclude_globs, sage-tools applies no excludes
    -- of its own, so both fixture files match. Only caller-provided exclude_globs filters them.
    cleanup()
    write_fixture(fixture_path("excl/hidden.txt"), "exclude-me-please")
    write_fixture(fixture_path("excl/visible.txt"), "exclude-me-please")
    -- Search without excludes: both files match
    local result_none = t.call_tool("rg", {
      pattern = "exclude-me-please",
      paths = { ".sage-tools-rg-test/excl" },
    })
    t.assert_tool_success(result_none)
    t.assert_equal(2, result_none.details.meta.row_count)
    -- Search with caller exclude_globs: hidden.txt excluded
    local result_exclude = t.call_tool("rg", {
      pattern = "exclude-me-please",
      paths = { ".sage-tools-rg-test/excl" },
      exclude_globs = { "hidden.txt" },
    })
    t.assert_tool_success(result_exclude)
    t.assert_equal(1, result_exclude.details.meta.row_count)
    t.assert_contains(result_exclude.details.rows[1].path, "visible.txt")
    cleanup()
  end,

  ["parent-traversal path is rejected"] = function()
    local result = t.call_tool("rg", {
      pattern = "test",
      paths = { "../sage-tools" },
    })
    t.assert_tool_failure(result, "must not contain parent traversal")
  end,

  ["context_lines is capped at max"] = function()
    cleanup()
    write_fixture(fixture_path("ctx/cap.txt"), "line1\nline2\nline3\nline4\nline5\n")
    local result = t.call_tool("rg", {
      pattern = "line3",
      paths = { ".sage-tools-rg-test/ctx" },
      context_lines = 99,
    })
    t.assert_tool_success(result)
    t.assert_equal(3, result.details.meta.context_lines)
    t.assert_equal(true, result.details.meta.context_lines_capped)
    cleanup()
  end,

  ["max_results limits returned rows"] = function()
    cleanup()
    write_fixture(fixture_path("limit/multi.txt"), "aaa\nbbb\nccc\nddd\neee\n")
    local result = t.call_tool("rg", {
      pattern = "[a-e]",
      paths = { ".sage-tools-rg-test/limit" },
      max_results = 1,
    })
    t.assert_tool_success(result)
    t.assert_equal(1, result.details.meta.row_count)
    t.assert_equal(1, #result.details.rows)
    t.assert_equal(true, result.details.meta.truncated_by_results)
    t.assert_contains(result.content, "results truncated")
    assert_not_contains(result.content, "rg: results truncated")
    cleanup()
  end,

  ["max_output_bytes truncates long summaries"] = function()
    cleanup()
    -- Each match line summary is ~36 bytes; with max_output_bytes=30, the first
    -- row's summary bytes exceed the limit so 0 rows are returned.
    write_fixture(fixture_path("bytes/long.txt"), "the matching line has some content\n")
    local result = t.call_tool("rg", {
      pattern = "matching",
      paths = { ".sage-tools-rg-test/bytes" },
      max_output_bytes = 30,
    })
    t.assert_tool_success(result)
    t.assert_equal(0, result.details.meta.row_count)
    t.assert_equal(true, result.details.meta.truncated_by_output_bytes)
    -- results truncated must appear even with 0 rows
    t.assert_contains(result.content, "results truncated")
    assert_not_contains(result.content, "rg: results truncated")
    cleanup()
  end,

  ["missing rg executables fail with install guidance"] = function()
    local result = t.call_tool("rg", {
      pattern = "test",
      rg_executable = "rg-missing-for-sage-tools-test",
    })
    t.assert_tool_failure(result, "ripgrep")
    t.assert_tool_failure(result, "install")
  end,

  ["absolute paths are rejected"] = function()
    local result = t.call_tool("rg", {
      pattern = "test",
      paths = { "/tmp/somewhere" },
    })
    t.assert_tool_failure(result, "must not be absolute")
  end,

  ["glob exclude is applied correctly"] = function()
    cleanup()
    write_fixture(fixture_path("globs/hide_me.txt"), "hidden-glob-match")
    write_fixture(fixture_path("globs/show_me.txt"), "visible-glob-match")
    local result = t.call_tool("rg", {
      pattern = "glob-match",
      paths = { ".sage-tools-rg-test/globs" },
      exclude_globs = { "hide_me.txt" },
    })
    t.assert_tool_success(result)
    t.assert_equal(1, result.details.meta.row_count)
    t.assert_contains(result.details.rows[1].path, "show_me.txt")
    cleanup()
  end,

  ["NUL byte in path is rejected"] = function()
    local result = t.call_tool("rg", {
      pattern = "test",
      paths = { ".sage-tools-rg-test/\0bad" },
    })
    t.assert_tool_failure(result, "NUL")
  end,

  ["meta includes pattern and searched_paths; no default_excludes field"] = function()
    cleanup()
    write_fixture(fixture_path("meta/hello.txt"), "meta test pattern\n")
    local result = t.call_tool("rg", {
      pattern = "meta test",
      paths = { ".sage-tools-rg-test/meta" },
    })
    t.assert_tool_success(result)
    t.assert_equal("meta test", result.details.meta.pattern)
    t.assert_equal(".sage-tools-rg-test/meta", result.details.meta.searched_paths[1])
    -- default_excludes field should not be present after removal of tool-level defaults
    if result.details.meta.default_excludes ~= nil then
      t.fail("default_excludes must not be present in meta")
    end
    cleanup()
  end,

  ["content format includes pattern, paths, and unprefixed count and truncation"] = function()
    cleanup()
    write_fixture(fixture_path("fmt/a.txt"), "apple\nbanana\ncherry\n")
    write_fixture(fixture_path("fmt/b.txt"), "apple\ndate\nelderberry\n")
    local result = t.call_tool("rg", {
      pattern = "apple",
      paths = { ".sage-tools-rg-test/fmt" },
      max_results = 1,
    })
    t.assert_tool_success(result)
    -- Pattern line
    t.assert_contains(result.content, 'pattern: "apple"')
    -- Paths line (non-default paths)
    t.assert_contains(result.content, "paths:")
    -- Count line (unprefixed)
    t.assert_contains(result.content, "1 row")
    assert_not_contains(result.content, "1 rows", "singular must be '1 row', not '1 rows'")
    -- Truncation line (unprefixed)
    t.assert_contains(result.content, "results truncated")
    -- No "rg:" prefix anywhere
    assert_not_contains(result.content, "rg: 1")
    assert_not_contains(result.content, "rg: results truncated")
    -- Content is the first line (pattern line), not blank
    t.assert_contains(result.content, 'pattern: "apple"')
    -- Verify structure: pattern line, paths line, blank line, count line
    local blank_separator = string.find(result.content, "\n\n")
    local paths_pos = string.find(result.content, "paths:")
    if blank_separator == nil then t.fail("must have blank line separator") end
    if paths_pos == nil then t.fail("must have paths line") end
    if not (paths_pos < blank_separator) then t.fail("paths must appear before blank separator") end
    cleanup()
  end,

  ["content format omits mode and paths when not applicable"] = function()
    cleanup()
    write_fixture(fixture_path("fmt_default/a.txt"), "default search content\n")
    local result = t.call_tool("rg", {
      pattern = "default search",
      -- No paths, defaults to .
    })
    t.assert_tool_success(result)
    -- Pattern line present
    t.assert_contains(result.content, 'pattern: "default search"')
    -- Mode line absent (no fixed_strings)
    assert_not_contains(result.content, "mode:")
    -- Paths line absent (defaults to .)
    assert_not_contains(result.content, "paths:")
    cleanup()
  end,

  ["content format uses plural N rows for multiple results"] = function()
    cleanup()
    write_fixture(fixture_path("plural/a.txt"), "plurals-test\n")
    write_fixture(fixture_path("plural/b.txt"), "plurals-test\n")
    local result = t.call_tool("rg", {
      pattern = "plurals-test",
      paths = { ".sage-tools-rg-test/plural" },
    })
    t.assert_tool_success(result)
    t.assert_equal(2, result.details.meta.row_count)
    t.assert_contains(result.content, "2 rows")
    cleanup()
  end,

  ["content format includes mode when fixed_strings is true"] = function()
    cleanup()
    write_fixture(fixture_path("fmt_fixed/a.txt"), "fixed.strings content\n")
    local result = t.call_tool("rg", {
      pattern = "fixed.strings",
      fixed_strings = true,
      paths = { ".sage-tools-rg-test/fmt_fixed" },
    })
    t.assert_tool_success(result)
    t.assert_contains(result.content, 'pattern: "fixed.strings"')
    t.assert_contains(result.content, "mode: fixed string")
    t.assert_contains(result.content, "1 row")
    assert_not_contains(result.content, "1 rows", "singular must be '1 row', not '1 rows'")
    cleanup()
  end,

  ["include_globs filters results"] = function()
    cleanup()
    write_fixture(fixture_path("include/a.txt"), "include test content")
    write_fixture(fixture_path("include/b.md"), "include test content")
    local result = t.call_tool("rg", {
      pattern = "include test",
      paths = { ".sage-tools-rg-test/include" },
      include_globs = { "*.txt" },
    })
    t.assert_tool_success(result)
    t.assert_equal(1, result.details.meta.row_count)
    t.assert_contains(result.details.rows[1].path, "a.txt")
    cleanup()
  end,

  ["max_results rejects zero"] = function()
    local result = t.call_tool("rg", {
      pattern = "test",
      max_results = 0,
    })
    t.assert_tool_failure(result, "must be at least 1")
  end,

  ["max_output_bytes rejects zero"] = function()
    local result = t.call_tool("rg", {
      pattern = "test",
      max_output_bytes = 0,
    })
    t.assert_tool_failure(result, "must be at least 1")
  end,

  ["timeout_ms rejects zero"] = function()
    local result = t.call_tool("rg", {
      pattern = "test",
      timeout_ms = 0,
    })
    t.assert_tool_failure(result, "must be at least 1")
  end,
}
