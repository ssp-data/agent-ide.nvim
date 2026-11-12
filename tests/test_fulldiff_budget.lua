-- Speed budget of the full diff (synthetic patch, best of 5): splitting 50 000 patch lines
-- (500 files of 100 lines, renames and multi-byte lines among them) into blocks, rendering them
-- and putting lines, highlights and folds into a buffer shown in a window, under 60 ms.
local parse = require('agent-ide.git_parse')
local render = require('agent-ide.ui.fulldiff_render')
local eq = MiniTest.expect.equality

local RUNS = 5
local FILES, PER_FILE = 500, 100
local T = MiniTest.new_set()

local function synthetic()
  local out, files = {}, {}
  for i = 1, FILES do
    local path = ('src/mod%03d/file%03d.lua'):format(i % 37, i)
    local old = i % 10 == 0 and ('src/old%03d.lua'):format(i) or nil
    files[#files + 1] = { status = old and 'R' or 'M', path = path, old_path = old, added = 50, removed = 48,
      binary = false, submodule = false }
    out[#out + 1] = ('diff --git a/%s b/%s'):format(old or path, path)
    if old then
      out[#out + 1] = 'similarity index 80%'
      out[#out + 1] = 'rename from ' .. old
      out[#out + 1] = 'rename to ' .. path
    end
    out[#out + 1] = 'index 1111111..2222222 100644'
    out[#out + 1] = '--- a/' .. (old or path)
    out[#out + 1] = '+++ b/' .. path
    out[#out + 1] = ('@@ -1,%d +1,%d @@ local function f()'):format(PER_FILE - 2, PER_FILE - 2)
    for j = 1, PER_FILE - 1 do
      local text = i % 7 == 0 and ('Übersetzung 日本語 %d'):format(j) or ('local v%d = compute(%d)'):format(j, j)
      local c = j % 4 == 0 and '+' or j % 4 == 1 and '-' or ' '
      out[#out + 1] = c .. text
    end
  end
  return table.concat(out, '\n') .. '\n', files
end

T['parse and render 50 000 patch lines into a buffer with folds under 60 ms'] = function()
  local text, files = synthetic()
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, { relative = 'editor', row = 0, col = 0, width = 120, height = 40 })
  vim.wo[win].foldmethod = 'manual'
  local ns = vim.api.nvim_create_namespace('agent-ide.fulldiff.budget')
  local best, lines = math.huge, 0
  for _ = 1, RUNS do
    local t0 = vim.uv.hrtime()
    local blocks = {}
    for _, b in ipairs(parse.patch(text)) do blocks[b.path] = b end
    local t = render.build(files, blocks, { icons = { open = '▾', closed = '▸' }, width = 120, fold_over = 500 })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, t.lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(t.hl) do
      vim.api.nvim_buf_set_extmark(buf, ns, h.line - 1, h.col_start,
        { end_row = (h.end_line or h.line) - 1, end_col = h.col_end, hl_group = h.group })
    end
    vim.api.nvim_win_call(win, function()
      vim.cmd('silent! normal! zE')
      for _, f in ipairs(t.folds) do vim.cmd(('%d,%dfold'):format(f.first, f.last)) end
    end)
    best = math.min(best, (vim.uv.hrtime() - t0) / 1e6)
    lines = #t.lines
  end
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(lines, FILES * (PER_FILE + 2))
  if best >= 60 then error(('full diff, 50 000 lines: %.2f ms, budget < 60 ms'):format(best), 0) end
  MiniTest.add_note(('full diff, 50 000 lines: %.2f ms (budget 60 ms)'):format(best))
end

return T
