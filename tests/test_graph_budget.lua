-- Speed budget of the commit graph (synthetic `git log --graph` text, best of 5): parsing and
-- rendering 300 commits on four lanes, with refs and multi-byte subjects, into a buffer with its
-- highlights under 20 ms.
local parse = require('agent-ide.git_parse')
local render = require('agent-ide.ui.graph_render')
local eq = MiniTest.expect.equality

local RUNS = 5
local T = MiniTest.new_set()

-- 300 commits on four lanes; every 10th commit a merge (fork line below), joins in between.
local function synthetic()
  local out = {}
  local subjects = { 'feat: retry loop', 'Übersetzung prüfen für Bäume', '日本語のコミット', 'fix: a rather long subject line '
    .. string.rep('that goes on ', 8) }
  for i = 1, 300 do
    local lane = i % 4
    local cells = {}
    for k = 0, 3 do cells[#cells + 1] = k == lane and '*' or '|' end
    local graph = table.concat(cells, ' ') .. ' '
    local refs = i % 25 == 0 and 'refs/heads/feat/x' .. i .. ', refs/remotes/origin/feat/x' .. i .. ', tag: refs/tags/v' .. i or ''
    local hash = ('%040x'):format(i)
    out[#out + 1] = table.concat({ graph .. '\30' .. hash, hash:sub(-7), refs, tostring(1767225600 - i * 600), 'Ana Ölmez',
      hash, subjects[i % 4 + 1] }, '\31')
    if i % 10 == 0 then
      out[#out + 1] = '| |\\ \\ \\'
    elseif i % 10 == 5 then
      out[#out + 1] = '| | |/ /'
    end
  end
  return table.concat(out, '\n') .. '\n'
end

T['parse and render 300 commits into a buffer under 20 ms'] = function()
  local text = synthetic()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace('agent-ide.graph.budget')
  local best, lines = math.huge, 0
  for _ = 1, RUNS do
    local t0 = vim.uv.hrtime()
    local rows = parse.graph(text, 300)
    local t = render.build(rows, { width = 120, now = 1767225600, open = {} })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, t.lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(t.hl) do
      vim.api.nvim_buf_set_extmark(buf, ns, h.line - 1, h.col_start, { end_col = h.col_end, hl_group = h.group })
    end
    best = math.min(best, (vim.uv.hrtime() - t0) / 1e6)
    lines = #t.lines
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(lines, 300 + 60)
  if best >= 20 then error(('graph, 300 commits: %.2f ms, budget < 20 ms'):format(best), 0) end
  MiniTest.add_note(('graph, 300 commits: %.2f ms (budget 20 ms)'):format(best))
end

return T
