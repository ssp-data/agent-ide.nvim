-- Using prompts: insert a command or skill, load a template or saved prompt into the chat's
-- prompt buffer (asking before a draft is replaced), edit the file, and the picker.
local api = vim.api
local cache = require('agent-ide.prompts.cache')
local sources = require('agent-ide.prompts.sources')
local store = require('agent-ide.prompts.store')

local M = {}

local NO_CHAT = 'Agent-IDE: open or start a session first, then pick a prompt'
local CLAUDE_FILE = "Agent-IDE: this file belongs to Claude's folders; opened read-only"
local DRAFT_Q = 'Replace the draft, insert above it, or cancel?'
local DRAFT_CHOICES = { 'Replace the draft', 'Insert above it', 'Cancel' }

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO) end

local function chat() return require('agent-ide.ui.chat') end

---Lines of a text as the prompt buffer holds them: a final newline is implied by the buffer.
---@param text string
---@return string[]
function M.to_lines(text)
  local lines = vim.split(text, '\n', { plain = true })
  if #lines > 1 and lines[#lines] == '' then lines[#lines] = nil end
  return lines
end

---True when the lines hold any non-blank character (the prompt buffer is never 'modified').
---@param lines string[]
---@return boolean
function M.has_text(lines)
  for _, l in ipairs(lines) do
    if l:find('%S') then return true end
  end
  return false
end

-- Session to put the prompt into: the current chat, else (project known) a new session for it.
local function target(project)
  local s = chat().current()
  if s then return s end
  if not project then return nil end
  local dir = project.root or project.key
  if not dir or dir:sub(1, 1) ~= '/' or vim.fn.isdirectory(dir) ~= 1 then return nil end
  s = require('agent-ide.session').open({ cwd = dir })
  require('agent-ide.ui.drawer_model').add_unsaved(s.id, project.key)
  chat().open(s, project)
  return s
end

-- The prompt buffer of `s`, its window shown and focused (normal mode).
local function prompt_of(s)
  chat().focus_prompt(s, false)
  local _, pbuf = chat().buffers(s)
  return pbuf
end

local function set_lines(buf, lines)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
end

local function insert_command(s, e)
  local buf = prompt_of(s)
  if not buf then return end
  local cur = api.nvim_buf_get_lines(buf, 0, -1, false)
  local line = e.insert .. ' '
  if #cur == 1 and cur[1] == '' then
    set_lines(buf, { line })
  else
    api.nvim_buf_set_lines(buf, 0, 0, false, { line })
    vim.bo[buf].modified = false
  end
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) == buf then api.nvim_win_set_cursor(win, { 1, #line }) end
  vim.cmd('startinsert!')
end

local function load_text(s, e, text)
  local buf = prompt_of(s)
  if not buf then return end
  local lines = M.to_lines(text)
  local function done(mode)
    if mode == 'replace' then
      set_lines(buf, lines)
      store.set_origin(buf, e)
    else -- above the draft, a blank line between; the mix is a new prompt, not that file
      local cur = api.nvim_buf_get_lines(buf, 0, -1, false)
      local all = vim.list_extend(vim.list_extend({}, lines), { '' })
      set_lines(buf, vim.list_extend(all, cur))
      store.set_origin(buf, nil)
    end
    local win = api.nvim_get_current_win()
    if api.nvim_win_get_buf(win) == buf then api.nvim_win_set_cursor(win, { 1, 0 }) end
  end
  if not M.has_text(api.nvim_buf_get_lines(buf, 0, -1, false)) then return done('replace') end
  vim.ui.select(DRAFT_CHOICES, { prompt = DRAFT_Q }, function(_, idx)
    if not api.nvim_buf_is_valid(buf) then return end
    if idx == 1 then
      done('replace')
    elseif idx == 2 then
      done('above')
    end
  end)
end

---Use a prompt entry (Enter on its row, a picker choice). `opts.project`: the project of the
---row (a Saved prompt row), used to start a session when no chat is open.
---@param e table PromptEntry
---@param opts? { project?: table }
function M.use(e, opts)
  opts = opts or {}
  local s = target(opts.project)
  if not s then return notify(NO_CHAT) end
  if e.insert then return insert_command(s, e) end
  sources.read(e, function(text, err)
    if not text then
      notify(('Agent-IDE: cannot load %s: %s'):format(e.title, err), vim.log.levels.WARN)
      return cache.invalidate()
    end
    load_text(s, e, text)
  end)
end

---Open an entry's file in the Agents tab's main window; Claude's own files read-only.
---@param e table PromptEntry
function M.edit(e)
  if not vim.uv.fs_stat(e.path) then
    cache.invalidate()
    return notify('Agent-IDE: file not found: ' .. vim.fn.fnamemodify(e.path, ':~'), vim.log.levels.WARN)
  end
  local win = require('agent-ide.ui.drawer').main_win()
  if win then api.nvim_set_current_win(win) end
  vim.cmd.edit(vim.fn.fnameescape(e.path))
  if e.insert then
    vim.bo.readonly = true
    vim.bo.modifiable = false
    notify(CLAUDE_FILE)
  end
end

-- Picker -------------------------------------------------------------------------------------

local function label(e)
  local name = e.insert or ((e.group and (e.group .. '/') or '') .. e.title)
  local text = e.kind .. ' · ' .. name
  if e.description then text = text .. ' — ' .. e.description end
  return (text:gsub('[\r\n]', ' '))
end

---Pick a prompt with `vim.ui.select` (saved prompts of the chat's project, the library,
---Claude's commands and skills); the choice is used as on Enter. `insert`: called from insert
---mode, which is resumed when nothing was inserted.
---@param opts? { insert?: boolean, win?: integer, pos?: integer[] } (win, pos: where typing was)
function M.pick(opts)
  opts = opts or {}
  local s = chat().current()
  local win, pos = opts.win, opts.pos
  local function resume()
    if not (opts.insert and win and api.nvim_win_is_valid(win)) then return end
    api.nvim_set_current_win(win)
    local line = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), pos[1] - 1, pos[1], false)[1] or ''
    pcall(api.nvim_win_set_cursor, win, pos)
    vim.cmd(pos[2] >= #line and 'startinsert!' or 'startinsert')
  end
  local saved_list = {}
  local function show(all)
    local items = vim.list_extend({}, saved_list)
    local cmds = {}
    for _, e in ipairs(all) do
      if e.insert then cmds[#cmds + 1] = e else items[#items + 1] = e end
    end
    vim.list_extend(items, cmds)
    if #items == 0 then
      resume()
      return notify('Agent-IDE: no prompts yet')
    end
    vim.ui.select(items, { prompt = 'Prompt', format_item = label, kind = 'agent-ide.prompt' }, function(e)
      if not e then return resume() end
      M.use(e)
    end)
  end
  if s then
    sources.scan({ saved_dir = cache.dirs().saved, project_name = cache.folder(chat().project_of(s)) }, function(list)
      saved_list = list
      cache.when_global(show)
    end)
  else
    cache.when_global(show)
  end
end

---Map the chat's prompt keys in `buf` (`config.keys.chat.prompts`; insert mode in the prompt
---buffer only for a key that does not start with a printable character, so typing never
---triggers it).
---@param buf integer
---@param is_transcript boolean
---@param keys table config.keys.chat
function M.map_chat(buf, is_transcript, keys)
  for _, lhs in ipairs(require('agent-ide.ui.diff_buf').keys(keys.prompts)) do
    vim.keymap.set('n', lhs, function() M.pick() end, { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: pick a prompt' })
    local first = vim.keycode(lhs):byte(1)
    if not is_transcript and first and (first < 0x20 or first == 0x7f or first == 0x80) then
      vim.keymap.set('i', lhs, function()
        local w, p = api.nvim_get_current_win(), api.nvim_win_get_cursor(0)
        vim.cmd('stopinsert')
        vim.schedule(function() M.pick({ insert = true, win = w, pos = p }) end)
      end, { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: pick a prompt' })
    end
  end
end

---A drawer row key on a prompt row (see ui/prompt_sections.lua).
---@param name string 'edit'|'rename'|'delete'|'yank'|'to_library'
---@param node table
function M.row_key(name, node)
  local e = node.entry
  if name == 'edit' then return M.edit(e) end
  return require('agent-ide.prompts.manage')[name](e, node)
end

return M
