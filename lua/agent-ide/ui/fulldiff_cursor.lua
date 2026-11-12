-- Where the cursor and the folds of the full diff are, and putting them back after a redraw:
-- a cursor is remembered as its file, the `@@` line above it and the rows below that; the
-- user's fold state is read by path before every redraw.
local api = vim.api

local M = {}

---The user's fold state by path, read from window `w` showing render `t` (nil without one).
---@param w integer|nil
---@param t table|nil
---@return table<string, boolean>|nil
function M.read_closed(w, t)
  if not (t and w) then return nil end
  local closed = {}
  api.nvim_win_call(w, function()
    for _, f in ipairs(t.folds) do closed[f.path] = vim.fn.foldclosed(f.first) ~= -1 end
  end)
  return closed
end

---Where the cursor of `w` is in render `t`: the file's path, the `@@` line at or above it in
---that file and the rows below it.
---@param w integer
---@param t table|nil
---@return { path?: string, hunk?: string, offset?: integer, row: integer }
function M.key(w, t)
  local row = api.nvim_win_get_cursor(w)[1]
  local node = t and t.nodes[row]
  if not node then return { row = row } end
  local file = t.files[node.file]
  local key = { path = file.path, row = row }
  if node.header then return key end
  for i = row, file.line + 1, -1 do
    if t.lines[i]:sub(1, 2) == '@@' then
      key.hunk, key.offset = t.lines[i], row - i
      break
    end
  end
  return key
end

---The row `key` names in render `t`, else nil.
---@param t table
---@param key table
---@return integer|nil
function M.find(t, key)
  if not key.path then return nil end
  for k, f in ipairs(t.files) do
    if f.path == key.path then
      if not key.hunk then return f.line end
      local last = t.folds[k].last
      for i = f.line + 1, last do
        if t.lines[i] == key.hunk then return math.min(i + (key.offset or 0), last) end
      end
      return f.line
    end
  end
end

---Create the folds of render `t` in window `w` (manual folds; `closed` ones closed).
---@param w integer
---@param t table
function M.apply_folds(w, t)
  api.nvim_win_call(w, function()
    vim.cmd('silent! normal! zE')
    for _, f in ipairs(t.folds) do vim.cmd(('%d,%dfold'):format(f.first, f.last)) end
    vim.cmd('silent! normal! zR')
    for _, f in ipairs(t.folds) do
      if f.closed then vim.cmd(('%dfoldclose'):format(f.first)) end
    end
  end)
end

return M
