if vim.g.loaded_agent_ide then return end
vim.g.loaded_agent_ide = true

vim.api.nvim_create_user_command('Agents', function() require('agent-ide').toggle() end,
  { desc = 'Agent-IDE: toggle the Agents tab' })
