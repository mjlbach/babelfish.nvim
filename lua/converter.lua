local tokens = require('tokens').tokens
local formatting = require('formatting')
local get_node_text = require('vim.treesitter.query').get_node_text

local converter = {}

local function recurse_links(parent_node, links)
  for node in parent_node:iter_children() do
    -- link or image
    if node:symbol() == 184 or node:symbol() == 185 then
      table.insert(links, node)
    end
    if node:child_count() > 0 then
      links = recurse_links(node, links)
    end
  end
  return links
end

converter.generic = function(node, content, _, _r)
  local text = get_node_text(node, content)
  local links = recurse_links(node, {})
  for _, lnode in ipairs(links) do
    local ltext = get_node_text(lnode, content):gsub('[%[%]%(%)%-]', function(x) return '%'..x end)
    local parsed = converter.link(lnode, content, _, { line_parts = {} })
    text = text:gsub(ltext, parsed[1])
  end
  vim.list_extend(_r.line_parts, {text})
  return _r.line_parts, false
end

converter.fenced_code_block = function(node, content, _, _r)
  for child_node in node:iter_children() do
    if child_node:type() == tokens.code_fence_content then
      node = child_node
    end
  end
  local codeblock_content = vim.split(get_node_text(node, content), "\n")
  codeblock_content = formatting.indent(codeblock_content, 4)
  vim.list_extend(_r.line_parts, {">"})
  vim.list_extend(_r.line_parts, codeblock_content)
  vim.list_extend(_r.line_parts, {"<"})
  return _r.line_parts, false
end

converter.heading = function(node, content, metadata, _r)
  local header_level = 1
  for child in node:iter_children() do
    -- atx_h1_marker = 11
    -- atx_h2_marker = 12
    -- atx_h3_marker = 13
    if child:symbol() == 12 then
      header_level = 2
    elseif child:symbol() == 13 then
      header_level = 3
    end
  end
  local text = get_node_text(node, content)
  text = string.gsub(text, "#+%s", "")
  local left
  local right
  local header_prefix = ''
  if metadata.header_count_lvl and header_level <= metadata.header_count_lvl then
    header_prefix = ("%d. "):format(_r.header_count)
    _r.header_count = _r.header_count + 1
  end
  if metadata.header_aliases and metadata.header_aliases[text] then
    left = string.format("%s%s", header_prefix, metadata.header_aliases[text][1])
    right = string.lower(string.gsub(metadata.header_aliases[text][2], "%s", "-"))
    right = string.format("*%s-%s*", metadata.project_name, right)
  else
    left = string.format("%s%s", header_prefix, string.upper(text))
    right = string.lower(string.gsub(text, "%s", "-"))
    right = string.format("*%s-%s*", metadata.project_name, right)
  end
  local padding = string.rep(" ", 78 - #left - #right)
  text = string.format("%s%s%s", left, padding, right)
  if not vim.tbl_isempty(_r.parsed_content) then
    vim.list_extend(_r.line_parts, {''})
  end
  vim.list_extend(_r.line_parts,
    {formatting.style_elements.header_break[header_level], text, ''})
  if header_level <= 2 then
    vim.list_extend(_r.line_parts, {''})
  end
  return _r.line_parts, false
end

converter.link = function(node, content, _, _r)
  local text, link_text, link_dest
  for child in node:iter_children() do
    -- link_text          = 234
    -- link_destination   = 190
    -- image_descripttion = 230
    if child:symbol() == 234 or child:symbol() == 230 then
      link_text = get_node_text(child, content)
      if _r.in_block_quote then
        link_text = link_text:gsub("[>\n]", "")
      end
    elseif child:symbol() == 190 then
      link_dest = get_node_text(child, content)
    end
  end
  text = ("%s <%s>"):format(link_text, link_dest)
  vim.list_extend(_r.line_parts, {text})
  return _r.line_parts, false
end

converter.table = function(node, content, _, _r)
  local text = get_node_text(node, content)
  vim.list_extend(_r.line_parts, {text})
  return _r.line_parts, false
end

local make_paragraph = function(line_parts, in_block_quote)
  local line = table.concat(line_parts):gsub("\n", "")
  local res = {}
  local words = vim.split(line, ' ')
  line = ''
  for _, word in ipairs(words) do
    if #word == 0 then goto continue end
    if string.match(word, "[.]") and #word == 1 then
      line =  line .. word
    elseif (#line + #word) > 78 then
      table.insert(res, line)
      line =  word
    elseif #line == 0 then
      line = word
    else
      line = line .. " " .. word
    end
    ::continue::
  end
  table.insert(res, line)
  if in_block_quote>0 then
    res = formatting.indent(res, 2)
  end
  -- adds newline after each paragraph
  vim.list_extend(res, {''})
  return res
end

converter.methods = {
  [tokens.link] = converter.link,
  [tokens.image] = converter.link,
  [tokens.table] = converter.table,
  [tokens.heading] = converter.heading,
  [tokens.list_item] = converter.generic,
  [tokens.fenced_code_block] = converter.fenced_code_block,
}

converter.recursive_parser = function(parent_node, content, metadata, _r)
  if not _r or vim.tbl_isempty(_r) then
    -- recursion stack data
    _r = {
      header_count = 1,
      in_paragraph = 0,
      in_block_quote = 0,
      line_parts = {},
      parsed_content = {},
    }
  end

  for node in parent_node:iter_children() do

    local node_symbol, node_type = node:symbol(), node:type()

    if converter.methods[node_type] == false then
      goto continue
    end

    -- paragraph, do not add to parsed_content
    -- avoids adding '\n' to each text
    if node_symbol == 124 then _r.in_paragraph = _r.in_paragraph+1 end
    if node_symbol == 154 then _r.in_block_quote = _r.in_block_quote+1 end

    local process_children = true
    if converter.methods[node_type] then
      _r.line_parts, process_children =
        converter.methods[node_type](node, content, metadata, _r)
    elseif node_symbol == 211 then
      -- node_type == 'text'
      local text = get_node_text(node, content)
      vim.list_extend(_r.line_parts, {text, ' '})
    end

    if process_children and node:child_count() > 0 then
      _r = converter.recursive_parser(node, content, metadata, _r)
    end

    if node_symbol == 124 then _r.in_paragraph = _r.in_paragraph-1 end

    -- print(_r.in_paragraph, node_symbol, node_type, get_node_text(node, content), "END")
    -- _G.dump(parsed)

    if _r.in_paragraph == 0 and not vim.tbl_isempty(_r.line_parts) then
      vim.list_extend(_r.parsed_content, not process_children and _r.line_parts
        or make_paragraph(_r.line_parts, _r.in_block_quote))
      _r.line_parts = {}
    end

    if node_symbol == 154 then _r.in_block_quote = _r.in_block_quote-1 end

    ::continue::
  end
  return _r
end

return converter
