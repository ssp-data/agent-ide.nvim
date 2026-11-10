-- Keys of the search picker's query line, from `config.keys.search_picker`: each a key, a list
-- of keys, or false. All work in insert and normal mode except `close` (normal mode only: in
-- insert mode <Esc> leaves insert mode, as in any buffer) and the match steps, whose keys that
-- start with a typed character (`]n`) work in normal mode only, so typing stays free; special
-- keys (`<M-n>`) work in both. Keys left out keep their Vim meaning (<C-r> inserts a register,
-- <C-k> a digraph).
local config = require('agent-ide.config')

local M = {}

-- name, normal mode only (true, false, or 'typed': only keys that start with a typed character), help text
local ACTIONS = {
  { 'next', false, 'next hit' },
  { 'prev', false, 'previous hit' },
  { 'open', false, 'open the chat on the hit' },
  { 'copy', false, 'copy the full text' },
  { 'reuse', false, 'put the prompt into the chat prompt' },
  { 'scope', false, 'scope: all, project, session' },
  { 'kinds', false, 'what to search' },
  { 'next_match', 'typed', 'preview: next occurrence of the query' },
  { 'prev_match', 'typed', 'preview: previous occurrence of the query' },
  { 'close', true, 'close' },
}

local list = require('agent-ide.util.keys').list

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
      local normal = a[2] == true or (a[2] == 'typed' and lhs:sub(1, 1) ~= '<')
      vim.keymap.set(normal and 'n' or { 'i', 'n' }, lhs, fn, { buffer = buf, nowait = true, silent = true,
        desc = 'Agent-IDE search: ' .. a[3] })
    end
  end
end

---A short key hint for the picker's border, e.g. `]n/[n match · <CR> open · <C-y> copy`.
function M.hint()
  local keys, parts = M.keys(), {}
  local n, p = keys.next_match[1], keys.prev_match[1]
  if n or p then parts[1] = (n and p) and (n .. '/' .. p .. ' match') or ((n or p) .. ' match') end
  for _, name in ipairs({ 'open', 'copy', 'reuse', 'scope', 'kinds', 'close' }) do
    local k = keys[name][1]
    if k then parts[#parts + 1] = k .. ' ' .. name end
  end
  return table.concat(parts, ' · ')
end

return M
