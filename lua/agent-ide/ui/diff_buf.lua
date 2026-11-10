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

local function local_map(buf, lhs)
  return api.nvim_buf_call(buf, function()
    local m = vim.fn.maparg(lhs, 'n', false, true)
    return (type(m) == 'table' and m.buffer == 1) and m or nil
  end)
end

---Keys of a config value: a key, a list of keys, or false/nil (none).
---@param v string|string[]|false|nil
---@return string[]
function M.keys(v) return require('agent-ide.util.keys').list(v) end

---Map `lhs` (a key or a list of keys) in normal mode on `buf`, remembering buffer-local
---mappings they replace.
function M.map(buf, lhs, fn, desc)
  if type(lhs) ~= 'string' then
    for _, k in ipairs(M.keys(lhs)) do M.map(buf, k, fn, desc) end
    return
  end
  if lhs == '' then return end
  if not ours[buf] then
    saved[buf] = saved[buf] or {}
    if saved[buf][lhs] == nil then
      -- read from `buf`, not the current buffer: the current window may show another one
      local m = local_map(buf, lhs)
      local ours_already = m and type(m.desc) == 'string' and vim.startswith(m.desc, 'Agent-IDE:')
      saved[buf][lhs] = (m and not ours_already) and m or false
    end
  end
  vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: ' .. desc })
end

---Remove the keys mapped by `map` from `buf` and restore what they replaced. A key another
---plugin mapped meanwhile (its description does not start with `Agent-IDE:`) is left alone.
function M.unmap(buf)
  local s = saved[buf]
  saved[buf] = nil
  if not s or not api.nvim_buf_is_valid(buf) then return end
  for lhs, m in pairs(s) do
    local cur = local_map(buf, lhs)
    if cur and type(cur.desc) == 'string' and vim.startswith(cur.desc, 'Agent-IDE:') then
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
      cur = nil
    end
    if m and not cur then api.nvim_buf_call(buf, function() vim.fn.mapset('n', false, m) end) end
  end
end

---The user's buffer of `path`, loaded. A swap file of another editor opens it read-only instead
---of asking; an unchanged loaded buffer is checked against the disk (an agent may have written
---the file) when 'autoread' allows a silent reload.
function M.real(path)
  local buf = vim.fn.bufadd(path)
  if not api.nvim_buf_is_loaded(buf) then
    local swapped = false
    local au = api.nvim_create_autocmd('SwapExists', { once = true, callback = function()
      vim.v.swapchoice = 'o'
      swapped = true
    end })
    pcall(vim.fn.bufload, buf)
    pcall(api.nvim_del_autocmd, au)
    if swapped then
      vim.notify('Agent-IDE: ' .. vim.fn.fnamemodify(path, ':~:.') .. ' opened read-only: it has a swap file (open elsewhere?)',
        vim.log.levels.WARN)
    end
  elseif not vim.bo[buf].modified and vim.o.autoread then
    pcall(vim.cmd, 'checktime ' .. buf)
  end
  vim.bo[buf].buflisted = true
  return buf
end

---Lines of file content; true for binary content (a NUL byte), nil for nil.
function M.lines_of(content)
  if content == nil then return nil end
  if content:find('\0', 1, true) then return true end -- binary
  local lines = vim.split(content, '\n', { plain = true })
  if lines[#lines] == '' then lines[#lines] = nil end
  return lines
end

return M
