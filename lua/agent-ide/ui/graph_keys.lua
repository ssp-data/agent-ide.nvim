-- Keys of the commit graph view (`keys.graph`, buffer-local) and their help float.
local config = require('agent-ide.config')
local keys = require('agent-ide.util.keys')

local M = {}

-- action name (the `keys.graph` option) and what it does
M.HELP = {
  { 'open', 'commit: show / hide its files; file: diff of this commit only; last line: load more' },
  { 'next_commit', 'next commit' },
  { 'prev_commit', 'previous commit' },
  { 'all', 'all branches <-> current branch only' },
  { 'refresh', 'refresh' },
  { 'more', 'load more commits' },
  { 'yank', 'yank the full hash of the commit' },
  { 'lazygit', 'lazygit for this repository' },
  { 'close', 'close, back to what was shown before' },
  { 'help', 'this help' },
}

---`config.keys.graph` (name -> key, list of keys, or false).
function M.keys()
  local k = config.get().keys
  return type(k) == 'table' and type(k.graph) == 'table' and k.graph or {}
end

function M.help()
  local k, rows = M.keys(), {}
  for _, h in ipairs(M.HELP) do
    local label = keys.label(k[h[1]])
    if label then rows[#rows + 1] = { key = label, desc = h[2] } end
  end
  rows[#rows + 1] = { key = '/', desc = 'search (built-in); Vim motions work' }
  require('agent-ide.ui.help').open('Agent-IDE graph', rows)
end

---Map the keys on `buf`; `actions[name]` runs for each (errors become a notice).
---@param buf integer
---@param actions table<string, fun()>
function M.map(buf, actions)
  local k = M.keys()
  for _, h in ipairs(M.HELP) do
    local fn = h[1] == 'help' and M.help or actions[h[1]]
    for _, lhs in ipairs(keys.list(k[h[1]])) do
      vim.keymap.set('n', lhs, function()
        local ok, err = pcall(fn)
        if not ok then vim.notify('Agent-IDE: graph: ' .. tostring(err), vim.log.levels.ERROR) end
      end, { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: ' .. h[2] })
    end
  end
end

return M
