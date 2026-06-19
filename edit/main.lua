local v = ctx.pack.require("support.validation")

local CONTEXT_LINES = 3
local fail = v.fail
local require_string = v.require_string
local validate_path = v.validate_path

local function directory_name(path)
  local index = path:match("^.*()[/\\]")
  if index == nil then return "." end
  if index == 1 then return path:sub(1, 1) end
  return path:sub(1, index - 1)
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    fail("cannot read " .. path .. ": " .. tostring(err))
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function write_file_atomic(path, content)
  local parent = directory_name(path)
  local tmp_path = parent .. "/.sage-edit-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000000)) .. ".tmp"
  local file, err = io.open(tmp_path, "wb")
  if not file then
    fail("cannot write temporary file for " .. path .. ": " .. tostring(err))
  end
  local ok, write_err = file:write(content)
  local close_ok, close_err = file:close()
  if not ok or not close_ok then
    os.remove(tmp_path)
    fail("cannot write " .. path .. ": " .. tostring(write_err or close_err))
  end
  local renamed, rename_err = os.rename(tmp_path, path)
  if not renamed then
    os.remove(tmp_path)
    fail("cannot replace " .. path .. ": " .. tostring(rename_err))
  end
end

local function count_occurrences(text, pattern)
  local count = 0
  local pos = 1
  while true do
    local start_pos, end_pos = text:find(pattern, pos, true)
    if not start_pos then break end
    count = count + 1
    pos = end_pos + 1
  end
  return count
end

local function normalize_edits(input)
  local edits = input.edits
  if type(edits) ~= "table" or edits[1] == nil then
    fail("edits must contain at least one edit")
  end

  local normalized = {}
  local index = 1
  while edits[index] ~= nil do
    local edit = edits[index]
    if type(edit) ~= "table" then
      fail("edit #" .. tostring(index) .. " must be an object")
    end
    normalized[index] = {
      old_text = require_string(edit.old_text, "edit #" .. tostring(index) .. ": old_text"),
      new_text = require_string(edit.new_text, "edit #" .. tostring(index) .. ": new_text"),
    }
    index = index + 1
  end
  return normalized
end

local function validate_edits(original, edits)
  local validated = {}
  for index, edit in ipairs(edits) do
    if edit.old_text == "" then
      fail("edit #" .. tostring(index) .. ": old_text must not be empty")
    end
    local matches = count_occurrences(original, edit.old_text)
    if matches == 0 then
      fail("edit #" .. tostring(index) .. ": old_text did not match")
    end
    if matches > 1 then
      fail("edit #" .. tostring(index) .. ": old_text matched " .. tostring(matches) .. " times; expected exactly one")
    end
    local start_pos, end_pos = original:find(edit.old_text, 1, true)
    validated[index] = {
      old_text = edit.old_text,
      new_text = edit.new_text,
      start_pos = start_pos,
      end_pos = end_pos,
      index = index,
    }
  end

  table.sort(validated, function(left, right) return left.start_pos < right.start_pos end)
  local previous = nil
  for _, edit in ipairs(validated) do
    if previous and edit.start_pos <= previous.end_pos then
      fail("edit #" .. tostring(edit.index) .. ": old_text overlaps edit #" .. tostring(previous.index))
    end
    previous = edit
  end
  return validated
end

local function apply_edits(original, edits)
  local updated = original
  for index = #edits, 1, -1 do
    local edit = edits[index]
    updated = updated:sub(1, edit.start_pos - 1) .. edit.new_text .. updated:sub(edit.end_pos + 1)
  end
  return updated
end

local function split_lines(text)
  local lines = {}
  local pos = 1
  while pos <= #text do
    local next_newline = text:find("\n", pos, true)
    if next_newline then
      lines[#lines + 1] = text:sub(pos, next_newline - 1)
      pos = next_newline + 1
    else
      lines[#lines + 1] = text:sub(pos)
      pos = #text + 1
    end
  end
  if #text == 0 then return {} end
  if text:sub(#text, #text) == "\n" then
    lines[#lines + 1] = ""
  end
  return lines
end

local function append_prefixed(output, prefix, lines, first_index, last_index)
  for index = first_index, last_index do
    if lines[index] ~= nil and not (index == #lines and lines[index] == "") then
      output[#output + 1] = prefix .. lines[index]
    end
  end
end

local function build_unified_diff(path, original, updated)
  if original == updated then return "" end

  local old_lines = split_lines(original)
  local new_lines = split_lines(updated)
  local prefix = 0
  while old_lines[prefix + 1] ~= nil and new_lines[prefix + 1] ~= nil and old_lines[prefix + 1] == new_lines[prefix + 1] do
    prefix = prefix + 1
  end

  local old_suffix = #old_lines
  local new_suffix = #new_lines
  while old_suffix > prefix and new_suffix > prefix and old_lines[old_suffix] == new_lines[new_suffix] do
    old_suffix = old_suffix - 1
    new_suffix = new_suffix - 1
  end

  local context_start = math.max(1, prefix - CONTEXT_LINES + 1)
  local old_context_end = math.min(#old_lines, old_suffix + CONTEXT_LINES)
  local new_context_end = math.min(#new_lines, new_suffix + CONTEXT_LINES)

  local old_hunk_count = old_context_end - context_start + 1
  local new_hunk_count = new_context_end - context_start + 1
  local output = {
    "--- a/" .. path,
    "+++ b/" .. path,
    string.format("@@ -%d,%d +%d,%d @@", context_start, old_hunk_count, context_start, new_hunk_count),
  }

  append_prefixed(output, " ", old_lines, context_start, prefix)
  append_prefixed(output, "-", old_lines, prefix + 1, old_suffix)
  append_prefixed(output, "+", new_lines, prefix + 1, new_suffix)
  append_prefixed(output, " ", old_lines, old_suffix + 1, old_context_end)

  return table.concat(output, "\n") .. "\n"
end

sage.register_tool({
  name = "edit",
  description = "Apply one or more exact-text replacements atomically to a single project file. Each old_text must match exactly one non-overlapping region in the original file; the file is unchanged if any edit is invalid.",
  parameters = {
    properties = {
      path = {
        type = "string",
        description = "File path to edit. Relative, parent-relative, and absolute paths are allowed.",
      },
      edits = {
        type = "array",
        description = "One or more exact-text replacements to apply to the file.",
        items = {
          type = "object",
          description = "One exact-text replacement.",
          properties = {
            old_text = {
              type = "string",
              description = "Exact text that must occur once in the original file.",
            },
            new_text = {
              type = "string",
              description = "Replacement text written in place of old_text.",
            },
          },
          required = { "old_text", "new_text" },
        },
      },
    },
    required = { "path", "edits" },
  },
  handler = function(callback_ctx)
    local path = validate_path(require_string(callback_ctx.input.path, "path"))
    local edits = normalize_edits(callback_ctx.input)

    if callback_ctx.status then callback_ctx:status("editing " .. path) end
    local original = read_file(path)
    local validated = validate_edits(original, edits)
    local updated = apply_edits(original, validated)
    local diff = build_unified_diff(path, original, updated)
    write_file_atomic(path, updated)

    return {
      content = diff,
      details = {
        path = path,
        edit_count = #edits,
      },
    }
  end,
})
