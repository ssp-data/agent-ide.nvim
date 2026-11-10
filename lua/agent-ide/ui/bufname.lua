-- Names of the plugin's buffers, so a tabline, a bufferline and `:ls` show something meaningful:
-- `agents://<project>/<title>` for a transcript, `… · prompt` and `… · raw` for its prompt
-- buffer and raw view, `agents://drawer`, `agents://help` and the like for the rest. A name is
-- set without autocommands (no BufFilePre/Post into user autocmds, no filetype detection, no URL
-- handler) and without touching the alternate file; the hidden buffer Neovim makes for the old
-- name is wiped at once. Two buffers that would get the same name get ` (2)`, ` (3)`, ….
-- Code never finds its buffers by name: it keeps them in tables or buffer variables.
local api = vim.api

local M = {}

M.MAX = 60 -- display cells of a title in a name

local tracked = {} -- buf -> { s = Session, suffix = string, project = fun(): table|nil }

---Text made fit for a buffer name: control characters (newlines too), `|`, `"`, `*`, `?`, `<`,
---`>` and backslashes become spaces, runs of spaces one, no space at either end; cut to `max`
---display cells with `…`. Empty: `fallback`.
---@param text any
---@param fallback string
---@param max? integer
---@return string
function M.clean(text, fallback, max)
  local t = tostring(text or ''):gsub('[%c|"*?<>\\]', ' '):gsub('%s+', ' ')
  t = vim.trim(t)
  if t == '' then return fallback end
  max = max or M.MAX
  if vim.fn.strdisplaywidth(t) <= max then return t end
  local out, w, n = {}, 0, vim.fn.strchars(t)
  for i = 0, n - 1 do
    local ch = vim.fn.strcharpart(t, i, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > max - 1 then break end
    out[#out + 1], w = ch, w + cw
  end
  return (table.concat(out):gsub('%s+$', '')) .. '…'
end

---`agents://<project>/<title>` (title cut, `new session` without one) plus `suffix`.
---@param project_name string|nil
---@param title string|nil
---@param suffix? string
---@return string
function M.session_name(project_name, title, suffix)
  return 'agents://' .. M.clean(project_name, '?') .. '/' .. M.clean(title, 'new session') .. (suffix or '')
end

local function holder(name, except)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if b ~= except and api.nvim_buf_get_name(b) == name then return b end
  end
end

---Name `buf` `name`, or `name (2)`, `name (3)`, … when another buffer has it. Nothing happens
---when `buf` already carries that name (or its numbered form). The wanted name is kept in
---`b:agent_ide_name_base`, the name given in `b:agent_ide_name`.
---@param buf integer
---@param name string
---@return string|nil given
function M.set(buf, name)
  if not api.nvim_buf_is_valid(buf) then return end
  if vim.b[buf].agent_ide_name_base == name and api.nvim_buf_get_name(buf) == vim.b[buf].agent_ide_name then
    return vim.b[buf].agent_ide_name
  end
  local given, n = name, 1
  while holder(given, buf) do
    n = n + 1
    given = ('%s (%d)'):format(name, n)
  end
  local old = api.nvim_buf_get_name(buf)
  vim.b[buf].agent_ide_name_base, vim.b[buf].agent_ide_name = name, given
  if old == given then return given end
  local ok = pcall(api.nvim_buf_call, buf, function()
    vim.cmd('keepalt noautocmd file ' .. vim.fn.fnameescape(given))
  end)
  if not ok then return end
  -- Neovim keeps the old name in a new hidden, unlisted buffer (the would-be alternate file)
  if old ~= '' then
    local ghost = holder(old, buf)
    if ghost and not api.nvim_buf_is_loaded(ghost) and not vim.bo[ghost].buflisted then
      local ei = vim.o.eventignore
      vim.o.eventignore = 'all'
      pcall(api.nvim_buf_delete, ghost, { force = true })
      vim.o.eventignore = ei
    end
  end
  return given
end

---Keep `buf` named after session `s`: `agents://<project>/<title><suffix>`, renamed by
---`M.refresh(s)` when the title changes. `project()` gives the project (its `name`).
---@param buf integer
---@param s table Session
---@param suffix string
---@param project fun(): table|nil
function M.track(buf, s, suffix, project)
  tracked[buf] = { s = s, suffix = suffix, project = project }
  api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function() tracked[buf] = nil end })
  local p = project()
  M.set(buf, M.session_name(p and p.name, s.title, suffix))
end

---Rename the buffers of session `s` after its current title (cheap when nothing changed).
---@param s table Session
function M.refresh(s)
  for buf, t in pairs(tracked) do
    if t.s == s then
      if api.nvim_buf_is_valid(buf) then
        local p = t.project()
        M.set(buf, M.session_name(p and p.name, s.title, t.suffix))
      else
        tracked[buf] = nil
      end
    end
  end
end

return M
