if vim.g.loaded_agent_ide then return end
vim.g.loaded_agent_ide = true

vim.api.nvim_create_user_command('Agents', function(o)
  if o.args == '' then return require('agent-ide').toggle() end
  require('agent-ide').scope(o.args)
end, { nargs = '?', desc = 'Agent-IDE: toggle the Agents tab; `project` / `all` switch the scope',
  complete = function(lead)
    return vim.tbl_filter(function(w) return vim.startswith(w, lead) end, { 'project', 'all' })
  end })

vim.api.nvim_create_user_command('AgentsSearch', function(o)
  require('agent-ide').search({ query = o.args })
end, { nargs = '*', desc = 'Agent-IDE: search all sessions' })

vim.api.nvim_create_user_command('AgentsGraph', function() require('agent-ide').graph() end,
  { desc = 'Agent-IDE: commit graph of the current project' })

-- In project scope only that project's sessions; `!` means every project.
vim.api.nvim_create_user_command('AgentsCloseIdle', function(o) require('agent-ide.ui.tmux_close').command(o.bang) end,
  { bang = true, desc = 'Agent-IDE: close every Claude idle in a tmux pane (asks first; ! for all projects)' })

vim.api.nvim_create_user_command('AgentsTrash', function(o)
  require('agent-ide.ui.delete').command(o.args)
end, { nargs = '?', complete = function() return { 'empty' } end, desc = 'Agent-IDE: restore or purge deleted sessions' })

-- AGENT_IDE_WATCHDOG=1 nvim: log where Lua is when Neovim freezes (util/watchdog.lua)
if vim.env.AGENT_IDE_WATCHDOG and vim.env.AGENT_IDE_WATCHDOG ~= '' and vim.env.AGENT_IDE_WATCHDOG ~= '0' then
  require('agent-ide.util.watchdog').start(tonumber(vim.env.AGENT_IDE_WATCHDOG) or 5)
end
