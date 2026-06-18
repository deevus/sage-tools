local t = sage.test

local function q(value)
  return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

local function cleanup()
  os.execute("rm -rf " .. q(".sage-tools-edit-test"))
  os.execute("rm -rf " .. q("../.sage-tools-edit-parent-test"))
end

local function dirname(path)
  return path:match("^(.+)/[^/]+$") or "."
end

local function current_dir()
  local handle = assert(io.popen("pwd"))
  local path = assert(handle:read("*l"))
  handle:close()
  return path
end

local function write_fixture(path, content)
  os.execute("mkdir -p " .. q(dirname(path)))
  local handle = assert(io.open(path, "w"))
  handle:write(content)
  handle:close()
end

local function read_file(path)
  local handle = assert(io.open(path, "r"))
  local content = handle:read("*a")
  handle:close()
  return content
end

return {
  ["schema supports snake_case multi edits for one file"] = function()
    local schema = t.schema("edit")
    t.assert_equal("edit", schema.name)
    t.assert_equal("sage-tools-edit", schema.extension)
    t.assert_equal("edit", schema.display_name)
    t.assert_contains(schema.description, "exact-text replacements")
    t.assert_equal("path", schema.parameters.required[1])
    t.assert_equal("edits", schema.parameters.required[2])
    t.assert_equal("string", schema.parameters.properties.path.type)
    t.assert_equal("array", schema.parameters.properties.edits.type)
    local item = schema.parameters.properties.edits.items
    t.assert_equal("object", item.type)
    t.assert_equal("old_text", item.required[1])
    t.assert_equal("new_text", item.required[2])
    t.assert_equal("string", item.properties.old_text.type)
    t.assert_equal("string", item.properties.new_text.type)
  end,

  ["applies multiple exact replacements atomically to one file"] = function()
    cleanup()
    write_fixture(".sage-tools-edit-test/tmp/edit.txt", "alpha\nbravo\ncharlie\ndelta\n")
    local result = t.call_tool("edit", {
      path = ".sage-tools-edit-test/tmp/edit.txt",
      edits = {
        { old_text = "bravo\n", new_text = "BETA\n" },
        { old_text = "delta\n", new_text = "DELTA\n" },
      },
    })
    t.assert_tool_success(result)
    t.assert_contains(result.content, "--- a/.sage-tools-edit-test/tmp/edit.txt")
    t.assert_contains(result.content, "+++ b/.sage-tools-edit-test/tmp/edit.txt")
    t.assert_contains(result.content, "-bravo")
    t.assert_contains(result.content, "+BETA")
    t.assert_contains(result.content, "-delta")
    t.assert_contains(result.content, "+DELTA")
    t.assert_equal("alpha\nBETA\ncharlie\nDELTA\n", read_file(".sage-tools-edit-test/tmp/edit.txt"))
    t.assert_equal(".sage-tools-edit-test/tmp/edit.txt", result.details.path)
    t.assert_equal(2, result.details.edit_count)
    cleanup()
  end,

  ["missing old_text fails without changing the file"] = function()
    cleanup()
    write_fixture(".sage-tools-edit-test/tmp/missing.txt", "one\ntwo\n")
    local result = t.call_tool("edit", {
      path = ".sage-tools-edit-test/tmp/missing.txt",
      edits = { { old_text = "three", new_text = "THREE" } },
    })
    t.assert_tool_failure(result, "old_text did not match")
    t.assert_equal("one\ntwo\n", read_file(".sage-tools-edit-test/tmp/missing.txt"))
    cleanup()
  end,

  ["ambiguous old_text fails without changing the file"] = function()
    cleanup()
    write_fixture(".sage-tools-edit-test/tmp/ambiguous.txt", "same\nother\nsame\n")
    local result = t.call_tool("edit", {
      path = ".sage-tools-edit-test/tmp/ambiguous.txt",
      edits = { { old_text = "same", new_text = "changed" } },
    })
    t.assert_tool_failure(result, "old_text matched 2 times")
    t.assert_equal("same\nother\nsame\n", read_file(".sage-tools-edit-test/tmp/ambiguous.txt"))
    cleanup()
  end,

  ["later invalid edit prevents earlier valid edit from being written"] = function()
    cleanup()
    write_fixture(".sage-tools-edit-test/tmp/atomic.txt", "one\ntwo\n")
    local result = t.call_tool("edit", {
      path = ".sage-tools-edit-test/tmp/atomic.txt",
      edits = {
        { old_text = "one", new_text = "ONE" },
        { old_text = "missing", new_text = "MISSING" },
      },
    })
    t.assert_tool_failure(result, "old_text did not match")
    t.assert_equal("one\ntwo\n", read_file(".sage-tools-edit-test/tmp/atomic.txt"))
    cleanup()
  end,

  ["absolute paths are editable"] = function()
    cleanup()
    local absolute_path = current_dir() .. "/.sage-tools-edit-test/tmp/absolute.txt"
    write_fixture(absolute_path, "keep\n")
    local result = t.call_tool("edit", {
      path = absolute_path,
      edits = { { old_text = "keep", new_text = "changed" } },
    })
    t.assert_tool_success(result)
    t.assert_contains(result.content, "--- a/" .. absolute_path)
    t.assert_equal("changed\n", read_file(absolute_path))
    cleanup()
  end,

  ["parent-relative paths are editable"] = function()
    cleanup()
    local path = "../.sage-tools-edit-parent-test/parent.txt"
    write_fixture(path, "before\n")
    local result = t.call_tool("edit", {
      path = path,
      edits = { { old_text = "before", new_text = "after" } },
    })
    t.assert_tool_success(result)
    t.assert_equal("after\n", read_file(path))
    cleanup()
  end,

  ["empty edits fail"] = function()
    cleanup()
    write_fixture(".sage-tools-edit-test/tmp/empty.txt", "keep\n")
    local result = t.call_tool("edit", { path = ".sage-tools-edit-test/tmp/empty.txt", edits = {} })
    t.assert_tool_failure(result, "edits must contain at least one edit")
    t.assert_equal("keep\n", read_file(".sage-tools-edit-test/tmp/empty.txt"))
    cleanup()
  end,
}
