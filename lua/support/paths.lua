local validation = ctx.pack.require("support.validation")

local function append_paths(argv, paths_validated)
  if paths_validated and #paths_validated > 0 then
    for _, p in ipairs(paths_validated) do
      argv[#argv + 1] = p
    end
  else
    argv[#argv + 1] = "."
  end
end

local function validate_paths(input)
  local paths_raw = validation.array_of_strings(input.paths, "paths")
  local paths_validated = {}
  if paths_raw then
    for _, p in ipairs(paths_raw) do
      validation.validate_project_relative_path(p)
      paths_validated[#paths_validated + 1] = p
    end
  end
  return paths_validated
end

local function searched_paths_for(paths_validated)
  if paths_validated and #paths_validated > 0 then
    local searched_paths = {}
    for _, p in ipairs(paths_validated) do
      searched_paths[#searched_paths + 1] = p
    end
    return searched_paths
  end
  return { "." }
end

return {
  append_paths = append_paths,
  validate_paths = validate_paths,
  searched_paths_for = searched_paths_for,
}
