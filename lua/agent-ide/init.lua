-- Agent-IDE.nvim entry point.
local config = require('agent-ide.config')
local M = {}

local mapped = {} -- global keys this module mapped last: name -> lhs

---@param opts? table
function M.setup(opts)
  local cfg = config.setup(opts)
  require('agent-ide.ui.highlights').setup()
  require('agent-ide.status').setup()
  require('agent-ide.ui.quit_guard').setup()
  require('agent-ide.ui.git_sections').register()
  for name, lhs in pairs(mapped) do
    pcall(vim.keymap.del, 'n', lhs)
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
    if keys[name] then
      vim.keymap.set('n', keys[name], g[1], { desc = 'Agent-IDE: ' .. g[2] })
      mapped[name] = keys[name]
    end
  end
end

function M.toggle()
  require('agent-ide.ui.highlights').setup()
  require('agent-ide.ui.drawer').toggle()
end

---Open the next session that needs you: waiting for an answer (oldest ask first), then a
---failed, then a finished turn you have not seen. Notifies when there is none.
function M.next_waiting()
  require('agent-ide.ui.highlights').setup()
  require('agent-ide.ui.waiting').next_waiting()
end

---Search titles, prompts and answers of every session (fuzzy with the helper).
---@param opts? { query?: string, kinds?: string[], scope?: 'all'|'project'|'session', project?: table, title?: string }
function M.search(opts) require('agent-ide.ui.search').open(opts) end

---Every prompt you sent, newest first; type to filter.
---@param opts? table as for `search`
function M.prompt_history(opts)
  M.search(vim.tbl_extend('force', { kinds = { 'prompt' }, title = 'Prompt history' }, opts or {}))
end

---@return string text for a statusline (percent signs doubled)
function M.statusline() return require('agent-ide.status').statusline() end

---@return string highlight group `AgentIdeLevel1..4`
function M.statusline_hl() return require('agent-ide.status').statusline_hl() end

---@return table lualine component
function M.lualine() return require('agent-ide.status').lualine() end

return M
