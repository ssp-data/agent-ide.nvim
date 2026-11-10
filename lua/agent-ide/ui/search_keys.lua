-- Keys of the search picker's query line, from `config.keys.search_picker`: each a key, a list
-- of keys, or false. All work in insert and normal mode except `close` (normal mode only: in
-- insert mode <Esc> leaves insert mode, as in any buffer). Keys left out keep their Vim meaning
-- (<C-r> inserts a register, <C-k> a digraph).
local config = require('agent-ide.config')

local M = {}

-- name, normal mode only, help text
local ACTIONS = {
  { 'next', false, 'next hit' },
  { 'prev', false, 'previous hit' },
  { 'open', false, 'open the chat on the hit' },
  { 'copy', false, 'copy the full text' },
  { 'reuse', false, 'put the prompt into the chat prompt' },
  { 'scope', false, 'scope: all, project, session' },
  { 'kinds', false, 'what to search' },
  { 'close', true, 'close' },
}

local function list(v)
  if type(v) == 'string' then return { v } end
  if type(v) == 'table' then return v end
  return {}
end

---@return table<string, string[]> action -> keys
function M.keys()
  local all = config.get().keys
  local t = type(all) == 'table' and type(all.search_picker) == 'table' and all.search_picker or {}
  local out = {}
  for _, a in ipairs(ACTIONS) do out[a[1]] = list(t[a[1]]) end
  return out
end

---Map the keys in `buf`; `fns[action]` runs them.
function M.map(buf, fns)
  local keys = M.keys()
  for _, a in ipairs(ACTIONS) do
    local fn = fns[a[1]]
    for _, lhs in ipairs(keys[a[1]]) do
      vim.keymap.set(a[2] and 'n' or { 'i', 'n' }, lhs, fn, { buffer = buf, nowait = true, silent = true,
        desc = 'Agent-IDE search: ' .. a[3] })
    end
  end
end

---A short key hint for the picker's border, e.g. `<CR> open · <C-y> copy`.
function M.hint()
  local keys, parts = M.keys(), {}
  for _, name in ipairs({ 'open', 'copy', 'reuse', 'scope', 'kinds', 'close' }) do
    local k = keys[name][1]
    if k then parts[#parts + 1] = k .. ' ' .. name end
  end
  return table.concat(parts, ' · ')
end

return M
