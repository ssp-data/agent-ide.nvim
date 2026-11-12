-- Speed budgets of the full diff (synthetic patches, best of 5): splitting 50 000 patch lines
-- (500 files of 100 lines, renames and multi-byte lines among them) into blocks, rendering them,
-- indexing the colours by line and putting lines and folds into a buffer shown in a window,
-- under 60 ms; the same lines coloured by delta (a span per word) under 150 ms. The colours
-- themselves are drawn per visible line by the view's decoration provider, not here.
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

-- The same lines as delta colours them (a background per changed line, syntax colours on every
-- word, an erase code at the end): the codes become spans.
local function colorize(text)
  local E = '\27['
  local out = {}
  for line in text:gmatch('([^\n]*)\n') do
    local c = line:sub(1, 1)
    if c == '+' or c == '-' then
      local bg = c == '+' and '48;2;0;40;0' or '48;2;63;0;1'
      local words = line:sub(2):gsub('(%S+)', E .. '38;2;248;248;242m%1' .. E .. '0m')
      out[#out + 1] = E .. bg .. 'm' .. c .. words .. E .. '0m' .. E .. bg .. 'm' .. E .. '0K' .. E .. '0m'
    elseif c == ' ' then
      out[#out + 1] = (line:gsub('(%S+)', E .. '38;2;248;248;242m%1' .. E .. '0m'))
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, '\n') .. '\n'
end

-- One timed pass: parse, render, index, lines into the buffer, folds in the window.
local function pass(text, files, colored, buf, win)
  local t0 = vim.uv.hrtime()
  local blocks = {}
  for _, b in ipairs(parse.patch(text)) do
    b.colored = colored
    blocks[b.path] = b
  end
  local t = render.build(files, blocks, { icons = { open = '▾', closed = '▸' }, width = 120, fold_over = 500 })
  local by_line = render.index(t.hl)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, t.lines)
  vim.api.nvim_win_call(win, function()
    vim.cmd('silent! normal! zE')
    for _, f in ipairs(t.folds) do vim.cmd(('%d,%dfold'):format(f.first, f.last)) end
    vim.cmd('silent! normal! zR')
  end)
  return (vim.uv.hrtime() - t0) / 1e6, t, by_line
end

local function measure(text, files, colored)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, { relative = 'editor', row = 0, col = 0, width = 120, height = 40 })
  vim.wo[win].foldmethod = 'manual'
  local best, t, by_line = math.huge, nil, nil
  for _ = 1, RUNS do
    local ms, t1, b1 = pass(text, files, colored, buf, win)
    best, t, by_line = math.min(best, ms), t1, b1
  end
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  return best, t, by_line
end

T['parse, render and index 50 000 patch lines into a buffer with folds under 60 ms'] = function()
  local text, files = synthetic()
  local best, t, by_line = measure(text, files, false)
  eq(#t.lines, FILES * (PER_FILE + 2))
  eq({ t.line_group[2], by_line[1] ~= nil }, { 'AgentIdeDiffHunk', true })
  if best >= 60 then error(('full diff, 50 000 lines: %.2f ms, budget < 60 ms'):format(best), 0) end
  MiniTest.add_note(('full diff, 50 000 lines, %d ranges: %.2f ms (budget 60 ms)'):format(#t.hl, best))
end

-- delta is used for patches up to git_patch.DELTA_MAX_LINES lines (20 000): that size, coloured.
T['parse, render and index 20 000 coloured (delta) patch lines under 100 ms'] = function()
  local text, files = synthetic()
  local limit = require('agent-ide.git_patch').DELTA_MAX_LINES
  eq(limit, 20000)
  local n = math.floor(limit / (PER_FILE + 6)) -- files that fit: 100 hunk lines and 6 header lines each
  local cut = {}
  for line in text:gmatch('([^\n]*)\n') do
    if line:sub(1, 11) == 'diff --git ' then
      n = n - 1
      if n < 0 then break end
    end
    cut[#cut + 1] = line
  end
  text = table.concat(cut, '\n') .. '\n'
  files = vim.list_slice(files, 1, math.floor(limit / (PER_FILE + 6)))
  local best, t = measure(colorize(text), files, true)
  eq(#t.lines, #files * (PER_FILE + 2))
  eq(t.lines[3]:find('\27', 1, true), nil)
  if best >= 100 then error(('full diff, %d coloured lines: %.2f ms, budget < 100 ms'):format(#cut, best), 0) end
  MiniTest.add_note(('full diff, %d coloured lines, %d raw: %.2f ms (budget 100 ms)'):format(#cut, vim.tbl_count(t.raw), best))
end

return T
