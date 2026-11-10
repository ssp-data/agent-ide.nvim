-- The prompt entries the drawer and the picker show, scanned lazily (on first use) and again on
-- `R`, after a save, rename or delete, and when the drawer is entered (debounced; the drawer is
-- only redrawn when something changed).
local config = require('agent-ide.config')
local sources = require('agent-ide.prompts.sources')

local M = {}

local G = { entries = nil, loading = false, again = false, root = nil, sig = nil, waiters = {} }
local saved = {} -- saved folder -> { entries|nil, loading, again, sig }
local listeners = {}
local focus_timer

local function opts()
  local p = config.get().prompts
  return type(p) == 'table' and p or {}
end

local function data(sub) return vim.fn.stdpath('data') .. '/agent-ide/' .. sub end

---Library and saved-prompt folders (absolute, `~` expanded).
---@return { library: string, saved: string }
function M.dirs()
  local o = opts()
  return { library = vim.fs.normalize(o.library_dir or data('library')), saved = vim.fs.normalize(o.saved_dir or data('prompts')) }
end

---Folder of a project's saved prompts below the saved dir: its folder name and a short hash of
---its key, so two projects with the same name never share their prompts.
---@param project table
---@return string
local folders = {} -- project key -> folder (the drawer asks on every render)
function M.folder(project)
  local key = project.key or project.root or project.name or '?'
  if folders[key] then return folders[key] end
  local base = vim.fs.basename(key):gsub('[^%w%-_.]', '-'):gsub('^%.+', '')
  if base == '' then base = 'project' end
  folders[key] = base .. '-' .. vim.fn.sha256(key):sub(1, 8)
  return folders[key]
end

local function notify_all()
  for _, fn in ipairs(listeners) do pcall(fn) end
end

local function signature(entries)
  local parts = {}
  for i, e in ipairs(entries) do parts[i] = e.path .. '|' .. e.stamp .. '|' .. (e.insert or '') end
  return table.concat(parts, '\n')
end

---Root of the project whose `.claude` commands and skills are listed: the chat shown in the
---Agents tab's transcript window.
---@return string|nil
function M.project_root()
  local chat = package.loaded['agent-ide.ui.chat']
  if not chat then return nil end
  local w = require('agent-ide.ui.chat_win').get().transcript
  local s = w and chat.session_of(vim.api.nvim_win_get_buf(w))
  if not s then return nil end
  local p = chat.project_of(s)
  local root = p and (p.root or p.key)
  return (root and root:sub(1, 1) == '/') and root or nil
end

local function scan_global()
  if G.loading then
    G.again = true
    return
  end
  G.loading, G.again = true, false
  local o, d = opts(), M.dirs()
  local root = G.root
  sources.scan({ command_dirs = o.command_dirs, skill_dirs = o.skill_dirs, library_dir = d.library,
    project_root = root, project_dirs = o.project_dirs }, function(entries)
    G.loading = false
    if G.again then return scan_global() end
    local sig = signature(entries)
    local changed = sig ~= G.sig or G.entries == nil
    G.entries, G.sig = entries, sig
    local waiters = G.waiters
    G.waiters = {}
    for _, fn in ipairs(waiters) do pcall(fn, entries) end
    if changed then notify_all() end
  end)
end

---Commands, skills and templates; nil until the first scan finished (which this starts).
---@return table[]|nil
function M.global()
  local root = M.project_root()
  if root ~= G.root then
    G.root = root
    if G.entries or G.loading then scan_global() end
  end
  if not G.entries and not G.loading then scan_global() end
  return G.entries
end

---Call `fn(entries)` with the commands, skills and templates once they are known.
---@param fn fun(entries: table[])
function M.when_global(fn)
  local e = M.global()
  if e and not G.loading then return fn(e) end
  G.waiters[#G.waiters + 1] = fn
end

local function scan_saved(folder)
  local st = saved[folder]
  if st.loading then
    st.again = true
    return
  end
  st.loading, st.again = true, false
  sources.scan({ saved_dir = M.dirs().saved, project_name = folder }, function(entries)
    st.loading = false
    if st.again then return scan_saved(folder) end
    local sig = signature(entries)
    local changed = sig ~= st.sig
    st.entries, st.sig = entries, sig
    if changed then notify_all() end
  end)
end

---Saved prompts of `project`; nil until its first scan finished (which this starts).
---@param project table
---@return table[]|nil
function M.saved(project)
  local folder = M.folder(project)
  local st = saved[folder]
  if not st then
    st = {}
    saved[folder] = st
    scan_saved(folder)
  end
  return st.entries
end

---Scan again what was scanned before (`R`, after a save, rename or delete).
function M.invalidate()
  if G.entries or G.loading then scan_global() end
  for folder in pairs(saved) do scan_saved(folder) end
end

---The drawer was entered: scan again after a short pause, quietly.
function M.focus()
  if not focus_timer then focus_timer = vim.uv.new_timer() end
  focus_timer:stop()
  focus_timer:start(300, 0, vim.schedule_wrap(M.invalidate))
end

---@param fn fun() called after a scan found something new
function M.on_update(fn)
  for _, f in ipairs(listeners) do
    if f == fn then return end
  end
  listeners[#listeners + 1] = fn
end

---Test only: forget everything.
function M._reset()
  G = { entries = nil, loading = false, again = false, root = nil, sig = nil, waiters = {} }
  saved = {}
end

return M
