-- Saving from the prompt buffer (the buffer itself is never 'modified'):
--   :w, :wq, :x, ZZ  a fresh prompt goes to the project's Saved prompts (file name from its first
--                    line, `-2`, `-3` ... when taken); a loaded template or saved prompt is
--                    updated in place (asked first when the file changed on disk since).
--   <leader>W        save to the library under a name (`group/name` makes folders).
-- `:wqa` and `:xa` save nothing (the buffer is never 'modified'), so `:qa` with a draft quits.
local api = vim.api
local cache = require('agent-ide.prompts.cache')
local store = require('agent-ide.prompts.store')

local M = {}

local group = api.nvim_create_augroup('agent-ide.prompts.save', { clear = true })
local last_cmd ---@type string|nil the ex command line being executed (cleared on the next tick)

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end

local function lines_of(buf) return api.nvim_buf_get_lines(buf, 0, -1, false) end

local function has_text(lines)
  for _, l in ipairs(lines) do
    if l:find('%S') then return true end
  end
  return false
end

-- The text as typed; a final newline added.
local function text_of(lines) return table.concat(lines, '\n') .. '\n' end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local t = f:read('a')
  f:close()
  return t
end

---Short name for notices: `Library/<rel>` or `Saved prompts/<project>/<name>`, without `.md`.
---@param kind string
---@param path string
---@param project_name? string
function M.short(kind, path, project_name)
  local name = path:gsub('%.md$', '')
  if kind == 'template' then
    local lib = cache.dirs().library
    if vim.startswith(name, lib .. '/') then return 'Library/' .. name:sub(#lib + 2) end
    return 'Library/' .. vim.fs.basename(name)
  end
  return 'Saved prompts/' .. (project_name or vim.fs.basename(vim.fs.dirname(name))) .. '/' .. vim.fs.basename(name)
end

local function project_of(buf)
  local chat = require('agent-ide.ui.chat')
  local s = chat.session_of(buf)
  return s and chat.project_of(s) or nil
end

local function saved(buf, kind, path, project_name, already)
  store.set_origin(buf, { kind = kind, path = path })
  notify((already and 'already saved → ' or 'saved → ') .. M.short(kind, path, project_name))
  cache.invalidate()
end

local function failed(err) notify('could not save: ' .. tostring(err), vim.log.levels.WARN) end

-- A new file `<base>.md` (or the next free name) in `dir`; one with the same text is reused.
local function save_new(buf, kind, dir, base, text, project_name)
  for _ = 1, 1000 do
    local rel = store.free_name(dir, base)
    -- an earlier copy of exactly this text: no duplicate
    for n = 1, 50 do
      local cand = dir .. '/' .. (n == 1 and base or (base .. '-' .. n)) .. '.md'
      if not vim.uv.fs_stat(cand) then break end
      if read(cand) == text then return saved(buf, kind, cand, project_name, true) end
    end
    local path = dir .. '/' .. rel .. '.md'
    local ok, err = store.write_new(path, text)
    if ok then return saved(buf, kind, path, project_name) end
    if err ~= 'exists' then return failed(err) end -- else: taken meanwhile, try the next name
  end
  failed('no free file name')
end

local function save_fresh(buf, lines)
  local project = project_of(buf)
  if not project then return failed('this prompt has no project') end
  local dir = cache.dirs().saved .. '/' .. cache.folder(project)
  save_new(buf, 'saved', dir, store.slug(lines), text_of(lines), project.name)
end

local CHANGED = '%s changed on disk since it was loaded. Overwrite, save as new, or cancel?'

local function save_origin(buf, o, lines)
  local text = text_of(lines)
  local function write()
    local ok, err = store.replace(o.path, store.frontmatter_of(o.path) .. text)
    if not ok then return failed(err) end
    saved(buf, o.kind, o.path)
  end
  if store.stamp(o.path) == o.stamp then return write() end
  vim.ui.select({ 'Overwrite', 'Save as new', 'Cancel' }, { prompt = CHANGED:format(M.short(o.kind, o.path)) }, function(_, idx)
    if not api.nvim_buf_is_valid(buf) then return end
    if idx == 1 then
      write()
    elseif idx == 2 then
      local dir = vim.fs.dirname(o.path)
      save_new(buf, o.kind, dir, vim.fs.basename(o.path):gsub('%.md$', ''), text)
    end
  end)
end

---Save prompt buffer `buf` (`:w` and friends). `quiet`: an empty prompt says nothing (ZZ, :x).
---@param buf integer
---@param quiet? boolean
function M.save(buf, quiet)
  local lines = lines_of(buf)
  if not has_text(lines) then
    if not quiet then notify('nothing to save') end
    return
  end
  local o = store.origin(buf)
  -- a prompt shown from the history is not the loaded file's text
  if o and not require('agent-ide.ui.prompt').browsing(buf) then return save_origin(buf, o, lines) end
  save_fresh(buf, lines)
end

---Ask for a library name and save `buf` there (`<leader>W`). Bad or taken names ask again.
---@param buf integer
function M.save_to_library(buf)
  local lines = lines_of(buf)
  if not has_text(lines) then return notify('nothing to save') end
  local lib = cache.dirs().library
  local function ask(default)
    vim.ui.input({ prompt = 'Save to library as: ', default = default }, function(typed)
      if not typed or vim.trim(typed) == '' or not api.nvim_buf_is_valid(buf) then return end
      local rel, why = store.clean_name(typed)
      if not rel then
        notify('name not allowed: ' .. why, vim.log.levels.WARN)
        return ask(typed)
      end
      local path = lib .. '/' .. rel .. '.md'
      local ok, err = store.write_new(path, text_of(lines))
      if ok then return saved(buf, 'template', path) end
      if err ~= 'exists' then return failed(err) end
      notify(M.short('template', path) .. ' already exists; pick another name', vim.log.levels.WARN)
      local dir, base = vim.fs.dirname(rel), vim.fs.basename(rel)
      local free = store.free_name(vim.fs.dirname(path), base)
      ask(dir ~= '.' and (dir .. '/' .. free) or free)
    end)
  end
  ask(store.slug(lines))
end

-- `:x`, `:xit`, `:exit` (not `:xa`): they write only a 'modified' buffer, so they save here.
local function is_exit(cmd)
  for part in (cmd or ''):gmatch('[^|]+') do
    local word = part:match("^[%s:%d,;%.%$%%'<>%+%-]*(%a+)")
    if word == 'x' or word == 'xi' or word == 'xit' or word == 'exi' or word == 'exit' then return true end
  end
  return false
end

local function keys()
  local k = require('agent-ide.config').get().keys
  return type(k) == 'table' and type(k.chat) == 'table' and k.chat or {}
end

---Saving for prompt buffer `buf`: `:w` / `:wq` (BufWriteCmd), `:x` (QuitPre), `ZZ` and the
---library key (normal mode).
---@param buf integer
function M.attach(buf)
  api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function(ev)
    vim.bo[ev.buf].modified = false
    if ev.file ~= '' and ev.file ~= api.nvim_buf_get_name(ev.buf) then
      return notify('the prompt is saved with :w (no file name); see ? for the keys', vim.log.levels.WARN)
    end
    local ok, err = pcall(M.save, ev.buf, is_exit(last_cmd))
    if not ok then failed(err) end
  end })
  api.nvim_create_autocmd('QuitPre', { buffer = buf, callback = function(ev)
    if not is_exit(last_cmd) or api.nvim_get_current_buf() ~= ev.buf then return end
    local ok, err = pcall(M.save, ev.buf, true)
    if not ok then failed(err) end
  end })
  vim.keymap.set('n', 'ZZ', function()
    local ok, err = pcall(M.save, buf, true)
    if not ok then failed(err) end
    vim.cmd('normal! ZZ')
  end, { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: save the prompt and hide it' })
  for _, lhs in ipairs(require('agent-ide.ui.diff_buf').keys(keys().save_library)) do
    vim.keymap.set('n', lhs, function() M.save_to_library(buf) end,
      { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: save the prompt to the library' })
  end
end

api.nvim_create_autocmd('CmdlineLeave', { group = group, pattern = ':', callback = function()
  if vim.v.event.abort then return end
  last_cmd = vim.fn.getcmdline()
  vim.schedule(function() last_cmd = nil end)
end })

M._is_exit = is_exit

return M
