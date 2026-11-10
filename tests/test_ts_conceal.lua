-- A long transcript with 'conceallevel' 3 must stay fast: the treesitter highlighter's per-row
-- conceal-line check is switched off for transcript buffers (util/ts_conceal.lua).
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function big(n)
  local lines = {}
  for i = 1, n / 10 do
    vim.list_extend(lines, { '## Turn ' .. i, '', 'Some **bold** text with `code` and a [link](http://x.y).', '',
      '```lua', 'local x = ' .. i, 'print(x)', '```', '', '- item' })
  end
  return lines
end

local function has_parser()
  return pcall(vim.treesitter.language.inspect, 'markdown') and pcall(vim.treesitter.language.inspect, 'markdown_inline')
end

local function open(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.cmd('tabnew')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  return buf, win
end

T['off: without a highlighter it does nothing'] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  eq(require('agent-ide.util.ts_conceal').off(buf), false)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T['a transcript buffer keeps the per-row conceal check off, also after new injected languages'] = function()
  if not has_parser() then return MiniTest.skip('no markdown parsers') end
  local history = require('agent-ide.ui.history')
  local buf, win = open()
  history.setup_buf(buf)
  history.set_lines(buf, big(200))
  vim.treesitter.start(buf, 'markdown')
  history.set_lines(buf, big(200)) -- the plugin's own writes re-check
  local hl = vim.treesitter.highlighter.active[buf]
  eq(hl ~= nil, true)
  eq(hl._conceal_line, nil)
  vim.treesitter.get_parser(buf):parse(true) -- injected languages arrive: the flag would come back
  eq(hl._conceal_line, nil)
  hl._conceal_line = true
  eq(hl._conceal_line, nil)
  -- other fields still work
  hl.redraw_count = 7
  eq(hl.redraw_count, 7)
  eq(vim.treesitter.highlighter.active[buf], hl)
  vim.wo[win].conceallevel = 3
  vim.cmd('redraw')
  vim.cmd('tabclose')
end

T['budget: text height of a 20 000-line transcript with conceallevel 3 under 500 ms'] = function()
  if not has_parser() then return MiniTest.skip('no markdown parsers') end
  local history = require('agent-ide.ui.history')
  local buf, win = open()
  history.setup_buf(buf)
  vim.treesitter.start(buf, 'markdown')
  history.set_lines(buf, big(20000))
  vim.wo[win].conceallevel = 3
  vim.wo[win].wrap = true
  local t = vim.uv.hrtime()
  local h = vim.api.nvim_win_text_height(win, {}).all
  vim.api.nvim_win_set_cursor(win, { 20000, 0 })
  vim.cmd('redraw')
  local ms = (vim.uv.hrtime() - t) / 1e6
  MiniTest.add_note(('20 000 lines, conceallevel 3: %.0f ms (budget 500 ms)'):format(ms))
  eq(h >= 20000, true)
  eq(ms < 500, true)
  vim.cmd('tabclose')
end

return T
