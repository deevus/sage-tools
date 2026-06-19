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

local function assert_not_contains(haystack, needle, message)
  if string.find(tostring(haystack), tostring(needle), 1, true) then
    t.fail(message or "expected content to not contain " .. tostring(needle))
  end
end

return {
  ["schema exposes find_files tool with guided discovery parameters"] = function()
    local schema = t.schema("find_files")
    t.assert_equal("find_files", schema.name)
    t.assert_equal("sage-tools-rg", schema.extension)
    t.assert_equal("find_files", schema.display_name)
    t.assert_equal("array", schema.parameters.properties.filename_hints.type)
    t.assert_equal("array", schema.parameters.properties.content_hints.type)
    t.assert_equal("array", schema.parameters.properties.paths.type)
    t.assert_equal("array", schema.parameters.properties.include_globs.type)
    t.assert_equal("array", schema.parameters.properties.exclude_globs.type)
    t.assert_equal("integer", schema.parameters.properties.max_results.type)
    if schema.parameters.required ~= nil and #schema.parameters.required > 0 then
      t.fail("find_files must not require filename_hints or content_hints; no-hint calls return no matches")
    end
  end,

  ["find_files searches by filename hints"] = function()
    cleanup()
    write_fixture(fixture_path("discover/auth_user.lua"), "local auth = true\n")
    write_fixture(fixture_path("discover/payment.lua"), "local payment = true\n")
    local result = t.call_tool("find_files", {
      filename_hints = { "auth" },
      paths = { ".sage-tools-rg-test/discover" },
    })
    t.assert_tool_success(result)
    t.assert_equal(1, result.details.meta.row_count)
    t.assert_equal(1, #result.details.rows)
    t.assert_contains(result.details.rows[1].path, "auth_user.lua")
    t.assert_equal("filename", result.details.rows[1].kind)
    t.assert_contains(result.details.rows[1].summary, "filename matched")
    t.assert_contains(result.content, "filename_hints: auth")
    t.assert_contains(result.content, "1 row")
    cleanup()
  end,

  ["find_files searches by content hints with line numbers"] = function()
    cleanup()
    write_fixture(fixture_path("content/tool.lua"), "sage.register_tool({ name = 'demo' })\n")
    write_fixture(fixture_path("content/readme.md"), "nothing relevant\n")
    local result = t.call_tool("find_files", {
      content_hints = { "register_tool" },
      paths = { ".sage-tools-rg-test/content" },
      fixed_strings = true,
    })
    t.assert_tool_success(result)
    t.assert_equal(1, result.details.meta.row_count)
    t.assert_equal(1, #result.details.rows)
    local row = result.details.rows[1]
    t.assert_contains(row.path, "tool.lua")
    t.assert_equal(1, row.line)
    t.assert_equal("content", row.kind)
    t.assert_contains(row.summary, "register_tool")
    t.assert_contains(result.content, "content_hints: register_tool")
    cleanup()
  end,

  ["find_files applies include_globs and exclude_globs"] = function()
    cleanup()
    write_fixture(fixture_path("filters/keep_auth.lua"), "filter-token\n")
    write_fixture(fixture_path("filters/drop_auth.lua"), "filter-token\n")
    write_fixture(fixture_path("filters/keep_auth.md"), "filter-token\n")
    local result = t.call_tool("find_files", {
      filename_hints = { "auth" },
      content_hints = { "filter-token" },
      paths = { ".sage-tools-rg-test/filters" },
      include_globs = { "*.lua" },
      exclude_globs = { "drop_*" },
      fixed_strings = true,
    })
    t.assert_tool_success(result)
    t.assert_equal(2, result.details.meta.row_count)
    for _, row in ipairs(result.details.rows) do
      t.assert_contains(row.path, "keep_auth.lua")
      assert_not_contains(row.path, "drop_auth.lua")
      assert_not_contains(row.path, "keep_auth.md")
    end
    cleanup()
  end,

  ["find_files follows rg default exclude behavior and only applies caller excludes"] = function()
    cleanup()
    write_fixture(fixture_path("defaults/generated_vendor/pkg/auth.js"), "default-exclude-token\n")
    write_fixture(fixture_path("defaults/src/auth.js"), "default-exclude-token\n")
    local result_none = t.call_tool("find_files", {
      filename_hints = { "auth" },
      content_hints = { "default-exclude-token" },
      paths = { ".sage-tools-rg-test/defaults" },
      fixed_strings = true,
    })
    t.assert_tool_success(result_none)
    t.assert_equal(4, result_none.details.meta.row_count)
    if result_none.details.meta.default_excludes ~= nil then
      t.fail("find_files must not report sage-tools-level default_excludes")
    end
    local result_exclude = t.call_tool("find_files", {
      filename_hints = { "auth" },
      content_hints = { "default-exclude-token" },
      paths = { ".sage-tools-rg-test/defaults" },
      exclude_globs = { "**/generated_vendor/**" },
      fixed_strings = true,
    })
    t.assert_tool_success(result_exclude)
    t.assert_equal(2, result_exclude.details.meta.row_count)
    for _, row in ipairs(result_exclude.details.rows) do
      assert_not_contains(row.path, "generated_vendor")
    end
    cleanup()
  end,

  ["find_files max_results limits combined filename and content rows"] = function()
    cleanup()
    write_fixture(fixture_path("limits/auth_one.lua"), "limit-token\n")
    write_fixture(fixture_path("limits/auth_two.lua"), "limit-token\n")
    local result = t.call_tool("find_files", {
      filename_hints = { "auth" },
      content_hints = { "limit-token" },
      paths = { ".sage-tools-rg-test/limits" },
      max_results = 1,
      fixed_strings = true,
    })
    t.assert_tool_success(result)
    t.assert_equal(1, result.details.meta.row_count)
    t.assert_equal(1, #result.details.rows)
    t.assert_equal(true, result.details.meta.truncated_by_results)
    t.assert_contains(result.content, "results truncated")
    cleanup()
  end,

  ["find_files max_output_bytes limits row summaries"] = function()
    cleanup()
    write_fixture(fixture_path("bytes/auth_long_filename_component.lua"), "byte-token\n")
    local result = t.call_tool("find_files", {
      filename_hints = { "auth" },
      paths = { ".sage-tools-rg-test/bytes" },
      max_output_bytes = 5,
    })
    t.assert_tool_success(result)
    t.assert_equal(0, result.details.meta.row_count)
    t.assert_equal(true, result.details.meta.truncated_by_output_bytes)
    t.assert_contains(result.content, "results truncated")
    cleanup()
  end,

  ["find_files no-match succeeds with zero rows"] = function()
    cleanup()
    write_fixture(fixture_path("nomatch/plain.txt"), "plain content\n")
    local result = t.call_tool("find_files", {
      filename_hints = { "missing" },
      content_hints = { "absent-token" },
      paths = { ".sage-tools-rg-test/nomatch" },
      fixed_strings = true,
    })
    t.assert_tool_success(result)
    t.assert_equal(0, result.details.meta.row_count)
    t.assert_equal(0, #result.details.rows)
    t.assert_contains(result.content, "no matches")
    cleanup()
  end,

  ["find_files rejects parent traversal paths"] = function()
    local result = t.call_tool("find_files", {
      filename_hints = { "anything" },
      paths = { "../sage-tools" },
    })
    t.assert_tool_failure(result, "must not contain parent traversal")
  end,
}
