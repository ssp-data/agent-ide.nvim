-- Agent-IDE.nvim entry point.
local config = require('agent-ide.config')
local M = {}

local mapped = {} -- global keys this module mapped last: name -> lhs list

---@param opts? table
function M.setup(opts)
  local cfg = config.setup(opts)
  require('agent-ide.ui.highlights').setup()
  require('agent-ide.status').setup()
  require('agent-ide.hidden').load()
  require('agent-ide.session.commands').load()
  require('agent-ide.claude.models').load()
  require('agent-ide.prefs').load()
  local keep = type(cfg.trash) == 'table' and tonumber(cfg.trash.keep_days)
  if keep then require('agent-ide.trash').purge_older(keep) end
  require('agent-ide.ui.quit_guard').setup()
  require('agent-ide.sound').setup()
  require('agent-ide.keeper').refresh() -- Claude processes earlier Neovims left running
  require('agent-ide.ui.prompt_sections').register() -- before git: Saved prompts follow Sessions
  require('agent-ide.ui.git_sections').register()
  for name, list in pairs(mapped) do
    for _, lhs in ipairs(list) do pcall(vim.keymap.del, 'n', lhs) end
    mapped[name] = nil
  end
  local keys = type(cfg.keys) == 'table' and cfg.keys or {}
  local globals = {
    toggle = { M.toggle, 'toggle Agents tab' },
    next_waiting = { M.next_waiting, 'next session that needs you' },
    search = { function() M.search() end, 'search all sessions' },
    prompt_history = { function() M.prompt_history() end, 'prompt history' },
  }
  for name, g in pairs(globals) do
    local list = require('agent-ide.util.keys').list(keys[name])
    for _, lhs in ipairs(list) do vim.keymap.set('n', lhs, g[1], { desc = 'Agent-IDE: ' .. g[2] }) end
    mapped[name] = #list > 0 and list or nil
  end
end

function M.toggle()
  require('agent-ide.ui.highlights').setup()
  require('agent-ide.ui.drawer').toggle()
end

---Switch the scope: 'project' (the git repository of the working directory, resolved again on
---every call) or 'all'; opens the drawer when it is not on screen.
---@param kind 'all'|'project'
function M.scope(kind)
  if kind ~= 'all' and kind ~= 'project' then
    return vim.notify('Agent-IDE: scope is "project" or "all"', vim.log.levels.WARN)
  end
  require('agent-ide.ui.highlights').setup()
  local drawer = require('agent-ide.ui.drawer')
  drawer.set_scope(kind)
  local st = drawer.state()
  if not st.tab or vim.api.nvim_get_current_tabpage() ~= st.tab or not st.win then drawer.toggle() end
end

---Open the next session that needs you: waiting for an answer (oldest ask first), then a
---failed, then a finished turn you have not seen. Notifies when there is none.
function M.next_waiting()
  require('agent-ide.ui.highlights').setup()
  require('agent-ide.ui.waiting').next_waiting()
end

---Pick a prompt (saved prompts of the chat's project, the library, Claude's commands and
---skills) and put it into the current chat's prompt buffer.
function M.prompts() require('agent-ide.prompts.actions').pick() end

---Search titles, prompts and answers of every session (fuzzy with the helper).
---@param opts? { query?: string, kinds?: string[], scope?: 'all'|'project'|'session', project?: table, title?: string }
function M.search(opts) require('agent-ide.ui.search').open(opts) end

---Every prompt you sent, newest first; type to filter.
---@param opts? table as for `search`
function M.prompt_history(opts)
  M.search(vim.tbl_extend('force', { kinds = { 'prompt' }, title = 'Prompt history' }, opts or {}))
end

---Commit graph of the repository of the current context (the chat, diff, drawer row, file or
---working directory); `opts.root` / `opts.dir` pick one.
---@param opts? { root?: string, dir?: string, project?: table }
function M.graph(opts)
  local graph = require('agent-ide.ui.graph')
  if opts and (opts.root or opts.dir) then return graph.open(opts) end
  graph.open_context()
end

---@return string text for a statusline (percent signs doubled)
function M.statusline() return require('agent-ide.status').statusline() end

---@return string highlight group `AgentIdeLevel1..4`
function M.statusline_hl() return require('agent-ide.status').statusline_hl() end

---@return table lualine component
function M.lualine() return require('agent-ide.status').lualine() end

return M
