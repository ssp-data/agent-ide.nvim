-- Buffers of the diff view: read-only scratch sides named `agent-ide://git/<rev>/<path>`, and
-- buffer-local keys that are put back the way they were when the user's own buffer leaves.
local api = vim.api

local M = {}

local ours = {} -- scratch buffers made here

local function find(name)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if ours[b] and api.nvim_buf_is_valid(b) and api.nvim_buf_get_name(b) == name then return b end
  end
end

---A read-only scratch buffer named `agent-ide://git/<rev>/<path>` holding `lines`, its
---filetype taken from `path`. An existing one of the same name is reused.
---@param rev string
---@param path string
---@param lines string[]
---@return integer buf
function M.get(rev, path, lines)
  local name = 'agent-ide://git/' .. rev .. '/' .. path
  local buf = find(name)
  if not buf then
    buf = api.nvim_create_buf(false, true)
    ours[buf] = true
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    api.nvim_buf_set_name(buf, name)
    api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function() ours[buf] = nil end })
  end
  vim.bo[buf].modifiable = true
  local old = api.nvim_buf_get_lines(buf, 0, -1, false)
  if not vim.deep_equal(old, lines) then api.nvim_buf_set_lines(buf, 0, -1, false, lines) end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  local ft = vim.filetype.match({ filename = path, buf = buf }) or ''
  if vim.bo[buf].filetype ~= ft then vim.bo[buf].filetype = ft end
  return buf
end

---An empty scratch buffer, wiped when hidden.
function M.empty()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  return buf
end

---@param buf integer
---@return boolean made here
function M.is_ours(buf) return ours[buf] == true end

local saved = {} -- buf -> { [lhs] = maparg dict|false }

---Map `lhs` in normal mode on `buf`, remembering a buffer-local mapping it replaces.
function M.map(buf, lhs, fn, desc)
  if not lhs then return end
  if not ours[buf] then
    saved[buf] = saved[buf] or {}
    if saved[buf][lhs] == nil then
      local m = vim.fn.maparg(lhs, 'n', false, true)
      saved[buf][lhs] = (type(m) == 'table' and m.buffer == 1) and m or false
    end
  end
  vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: ' .. desc })
end

---Remove the keys mapped by `map` from `buf` and restore what they replaced.
function M.unmap(buf)
  local s = saved[buf]
  saved[buf] = nil
  if not s or not api.nvim_buf_is_valid(buf) then return end
  for lhs, m in pairs(s) do
    pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
    if m then api.nvim_buf_call(buf, function() vim.fn.mapset('n', false, m) end) end
  end
end

return M
