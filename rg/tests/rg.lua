local t = sage.test

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
}