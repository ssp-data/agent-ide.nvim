if vim.g.loaded_agent_ide then return end
vim.g.loaded_agent_ide = true

vim.api.nvim_create_user_command('Agents', function() require('agent-ide').toggle() end,
  { desc = 'Agent-IDE: toggle the Agents tab' })

vim.api.nvim_create_user_command('AgentsSearch', function(o)
  require('agent-ide').search({ query = o.args })
end, { nargs = '*', desc = 'Agent-IDE: search all sessions' })

vim.api.nvim_create_user_command('AgentsGraph', function() require('agent-ide').graph() end,
  { desc = 'Agent-IDE: commit graph of the current project' })
