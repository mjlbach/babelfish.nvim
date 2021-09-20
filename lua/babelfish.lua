local converter = require('converter')
local docgen = {}

docgen.parse_markdown = function (parser, contents, metadata)
  local tstree = parser:parse()[1]
  local parent_node = tstree:root()

  local formatted_file = converter.recursive_parser(parent_node, contents, metadata, {}).parsed_content
  table.insert(formatted_file, "\nvim:tw=78:ts=8:ft=help:norl:")

  local final_text = table.concat(formatted_file, "\n")
  return final_text
end

docgen.generate_readme = function(metadata)
  local fp = assert(io.open(metadata.input_file))
  local contents = fp:read("*all")
  fp:close()

  converter.methods = vim.tbl_extend('force', converter.methods, metadata.methods)

  local parser = vim.treesitter.get_string_parser(contents, "markdown")
  local readme_data = docgen.parse_markdown(parser, contents, metadata)

  local writer = io.open(metadata.output_file, "w")
  writer:write(readme_data)
  writer:close()
end

return docgen
