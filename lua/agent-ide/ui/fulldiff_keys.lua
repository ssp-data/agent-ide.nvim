-- Keys of the full diff view (`keys.full_diff`, buffer-local) and their help float.
local config = require('agent-ide.config')
local keys = require('agent-ide.util.keys')

local M = {}

-- action name (the `keys.full_diff` option) and what it does
M.HELP = {
  { 'open', 'side-by-side diff of the file under the cursor, on this line; q there comes back' },
  { 'next_file', 'next file' },
  { 'prev_file', 'previous file' },
  { 'next_hunk', 'next hunk' },
  { 'prev_hunk', 'previous hunk' },
  { 'fold', 'fold or unfold the file under the cursor' },
  { 'collapse_all', 'fold every file' },
  { 'expand_all', 'unfold every file' },
  { 'refresh', 'refresh' },
  { 'yank', 'yank the path of the file under the cursor' },
  { 'lazygit', 'lazygit for this repository' },
  { 'close', 'close, back to what was shown before' },
  { 'help', 'this help' },
}

---`config.keys.full_diff` (name -> key, list of keys, or false).
function M.keys()
  local k = config.get().keys
  return type(k) == 'table' and type(k.full_diff) == 'table' and k.full_diff or {}
end

function M.help()
  local k, rows = M.keys(), {}
  for _, h in ipairs(M.HELP) do
    local label = keys.label(k[h[1]])
    if label then rows[#rows + 1] = { key = label, desc = h[2] } end
  end
  rows[#rows + 1] = { key = '/', desc = 'search (built-in); Vim motions, zM / zR and the other fold keys work' }
  require('agent-ide.ui.help').open('Agent-IDE full diff', rows)
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
        if not ok then vim.notify('Agent-IDE: full diff: ' .. tostring(err), vim.log.levels.ERROR) end
      end, { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: ' .. h[2] })
    end
  end
end

return M
