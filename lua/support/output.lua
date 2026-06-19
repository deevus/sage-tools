local constants = ctx.pack.require("support.constants")

local function shorten(text)
  -- Trim trailing newlines/carriage returns
  local trimmed = text:gsub("[\r\n]+$", "")
  if #trimmed > constants.MAX_SUMMARY_CHARS then
    return trimmed:sub(1, constants.MAX_SUMMARY_CHARS) .. "..."
  end
  return trimmed
end

-- Parse one line of rg output
local function parse_rg_line(line)
  -- Tab-separated: path\tline\t[column]\tsummary
  -- Context lines may lack column: path\tline\t\tsummary or path\tline\tcontext_summary
  local parts = {}
  for part in line:gmatch("([^\t]*)") do
    parts[#parts + 1] = part
  end

  -- Handle trailing empty fields from trailing tabs
  -- Count actual tabs in the line to determine field count
  local tab_count = select(2, line:gsub("\t", ""))

  if tab_count >= 3 and #parts >= 4 then
    -- Match row: path, line, column, summary
    local path = parts[1]
    local line_num = tonumber(parts[2])
    local column = tonumber(parts[3])
    local summary = parts[4]
    -- Rejoin remaining parts if there were more than 4 tab-delimited fields
    if #parts > 4 then
      local rest = {}
      for i = 4, #parts do
        rest[#rest + 1] = parts[i]
      end
      summary = table.concat(rest, "\t")
    end
    return {
      path = path,
      line = line_num or 0,
      column = column or 0,
      kind = "match",
      summary = shorten(summary),
    }
  end

  -- Context row or fallback
  -- Format: path\tline\t\tsummary (column empty) or path\tline\tsummary
  local path = parts[1] or ""
  local line_num = tonumber(parts[2])
  local summary = parts[3] or ""
  if #parts > 3 then
    local rest = {}
    for i = 3, #parts do
      rest[#rest + 1] = parts[i]
    end
    summary = table.concat(rest, "\t")
  end
  return {
    path = path,
    line = line_num or 0,
    kind = "context",
    summary = shorten(summary),
  }
end

-- Parse rg stdout into rows
local function parse_output(stdout, max_results, max_output_bytes)
  local rows = {}
  local total_bytes = 0
  local truncated_by_results = false
  local truncated_by_output_bytes = false

  -- Split by newlines
  local pos = 1
  while pos <= #stdout do
    local next_newline = stdout:find("\n", pos, true)
    local line
    if next_newline then
      line = stdout:sub(pos, next_newline - 1)
      pos = next_newline + 1
    else
      line = stdout:sub(pos)
      pos = #stdout + 1
    end

    -- Skip empty lines and separator lines (-- separator between file groups)
    if line == "" or line == "--" then
      -- pass
    else
      local parsed = parse_rg_line(line)

      -- Check limits
      if #rows >= max_results then
        truncated_by_results = true
        break
      end

      -- Track byte count for summary fields
      local summary_bytes = #(parsed.summary or "")
      if total_bytes + summary_bytes > max_output_bytes then
        truncated_by_output_bytes = true
        break
      end
      total_bytes = total_bytes + summary_bytes

      rows[#rows + 1] = parsed
    end
  end

  return rows, truncated_by_results, truncated_by_output_bytes, total_bytes
end

local function append_limited_row(rows, row, state, max_results, max_output_bytes)
  if #rows >= max_results then
    state.truncated_by_results = true
    return false
  end
  local summary_bytes = #(row.summary or "")
  if state.total_summary_bytes + summary_bytes > max_output_bytes then
    state.truncated_by_output_bytes = true
    return false
  end
  state.total_summary_bytes = state.total_summary_bytes + summary_bytes
  rows[#rows + 1] = row
  return true
end

return {
  shorten = shorten,
  parse_output = parse_output,
  append_limited_row = append_limited_row,
}
