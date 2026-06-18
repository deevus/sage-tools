local t = sage.test

local function q(value)
  return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

local function cleanup()
  local test_dir = t.path(".sage-tools-rg-test")
  os.execute("rm -rf " .. q(test_dir))
end

local function dirname(path)
  return path:match("^(.+)/[^/]+$") or "."
end

local function write_fixture(path, content)
  os.execute("mkdir -p " .. q(dirname(path)))
  local handle = assert(io.open(path, "w"))
  handle:write(content)
  handle:close()
end

local function fixture_path(relative)
  return t.path(".sage-tools-rg-test/" .. relative)
end

return {
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
    t.assert_contains(result.content, "rg: 1 rows")
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
    t.assert_contains(result.content, "rg: no matches")
    cleanup()
  end,

  ["default excludes hide node_modules matches"] = function()
    -- Create fixtures directly in extension root so glob '!node_modules/**' matches.
    -- Use narrow search paths to avoid matching test files.
    local ext_root = t.path(".")
    write_fixture(ext_root .. "/node_modules/sage_rg_exclude_test.txt", "sage-rg-exclude-target")
    write_fixture(ext_root .. "/src/sage_rg_exclude_test.txt", "sage-rg-exclude-target")
    local result = t.call_tool("rg", {
      pattern = "sage-rg-exclude-target",
      paths = { "node_modules", "src" },
    })
    -- Clean up before assertions
    os.execute("rm -rf " .. q(ext_root .. "/node_modules"))
    os.execute("rm -rf " .. q(ext_root .. "/src"))
    t.assert_tool_success(result)
    -- 'node_modules/' should be excluded by default; only 'src/' match should appear
    t.assert_equal(1, result.details.meta.row_count)
    t.assert_equal(1, #result.details.rows)
    t.assert_contains(result.details.rows[1].path, "src/sage_rg_exclude_test.txt")
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
    t.assert_contains(result.content, "rg: results truncated")
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

  ["meta includes pattern, searched_paths, and default_excludes"] = function()
    cleanup()
    write_fixture(fixture_path("meta/hello.txt"), "meta test pattern\n")
    local result = t.call_tool("rg", {
      pattern = "meta test",
      paths = { ".sage-tools-rg-test/meta" },
    })
    t.assert_tool_success(result)
    t.assert_equal("meta test", result.details.meta.pattern)
    t.assert_equal(".sage-tools-rg-test/meta", result.details.meta.searched_paths[1])
    if result.details.meta.default_excludes == nil or #result.details.meta.default_excludes == 0 then
      t.fail("expected default_excludes to be present and non-empty")
    end
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
