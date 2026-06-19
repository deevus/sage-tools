local M = {
  label = "sage-tools-test-helper",
}

function M.q(value)
  return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

function M.dirname(path)
  return path:match("^(.+)/[^/]+$") or "."
end

function M.write_fixture(path, content)
  os.execute("mkdir -p " .. M.q(M.dirname(path)))
  local handle = assert(io.open(path, "w"))
  handle:write(content)
  handle:close()
end

function M.read_file(path)
  local handle = assert(io.open(path, "r"))
  local content = handle:read("*a")
  handle:close()
  return content
end

function M.current_dir()
  local handle = assert(io.popen("pwd"))
  local path = assert(handle:read("*l"))
  handle:close()
  return path
end

function M.assert_not_contains(t, haystack, needle, message)
  if string.find(tostring(haystack), tostring(needle), 1, true) then
    t.fail(message or "expected content to not contain " .. tostring(needle))
  end
end

return M
