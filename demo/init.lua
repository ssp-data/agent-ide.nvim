-- The demo Neovim (`make demo`, scripts/demo.sh): the plugin on synthetic sessions, repositories and
-- prompts under /tmp/agent-ide-demo. Only the plugin is loaded; the user's own config is not.
-- AGENT_IDE_DEMO_SHOT: `live` (default: the drawer and the running sessions, then you drive), `chat`
-- (the README screenshot: drawer, Library, changes, a chat with a draft) or `graph`.
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local root = '/tmp/agent-ide-demo' -- built by scripts/demo.sh
local shot = os.getenv('AGENT_IDE_DEMO_SHOT') or 'live'

-- The plugin's options come from the demo only: the user's spec (its prompt library and quota file) is
-- replaced by this one, so none of the user's prompts or usage numbers reach the screenshot.
local demo_opts = {
  projects_dir = root .. '/projects',
  claude = { cmd = { repo .. '/demo/fake-claude' }, version_check = false },
  live = { cmd = { 'cat', root .. '/live.json' } },
  prompts = {
    library_dir = root .. '/prompts/library',
    saved_dir = root .. '/prompts/saved',
    command_dirs = { root .. '/prompts/commands' },
    skill_dirs = { root .. '/prompts/skills' },
  },
  quota = { file = root .. '/quota.json' },
  scope = 'all',
  sound = { waiting = false },
}
vim.opt.runtimepath:prepend(repo)
local agent_ide = require('agent-ide')
local user_setup = agent_ide.setup
agent_ide.setup = function() return user_setup(demo_opts) end

-- The user's config loads (lazy, lualine, colorscheme, keys) as in a real session; its agent-ide spec
-- calls setup, which now applies demo_opts only.
dofile(vim.fn.stdpath('config') .. '/init.lua')
require('lazy').load({ plugins = { 'agent-ide.nvim' } })

-- The colours of an Omarchy theme (AGENT_IDE_DEMO_THEME, default pics-costa-rica-sunset), from its colors.toml.
local theme = os.getenv('AGENT_IDE_DEMO_THEME') or 'pics-costa-rica-sunset'
local file = io.open(os.getenv('HOME') .. '/.config/omarchy/themes/' .. theme .. '/colors.toml')
local c = {}
if file then
  for key, hex in file:read('*a'):gmatch('\n(%w+)%s*=%s*"(#%x+)"') do c[key] = hex end
  file:close()
end
if c.background then
  local function hl(group, o) vim.api.nvim_set_hl(0, group, o) end
  hl('Normal', { fg = c.foreground, bg = c.background })
  hl('NormalFloat', { fg = c.foreground, bg = c.dark_background })
  hl('CursorLine', { bg = c.lighter_background })
  hl('Visual', { bg = c.selection })
  hl('LineNr', { fg = c.muted })
  -- the line above the prompt is the status line of the transcript window; it has to stand out
  hl('WinSeparator', { fg = c.accent, bg = c.background })
  hl('StatusLine', { fg = c.foreground, bg = c.selection })
  hl('StatusLineNC', { fg = c.muted, bg = c.dark_background })
  hl('Pmenu', { fg = c.foreground, bg = c.dark_background })
  hl('Title', { fg = c.accent, bold = true })
  hl('Comment', { fg = c.muted })
  hl('Keyword', { fg = c.magenta })
  hl('Statement', { fg = c.magenta })
  hl('String', { fg = c.green })
  hl('Function', { fg = c.blue })
  hl('Type', { fg = c.yellow })
  hl('Constant', { fg = c.orange })
  hl('Special', { fg = c.cyan })
  hl('Identifier', { fg = c.foreground })
  hl('Error', { fg = c.red })
  hl('WarningMsg', { fg = c.yellow })
  hl('DiffAdd', { fg = c.green })
  hl('DiffDelete', { fg = c.red })
  hl('Search', { bg = c.selection, fg = c.bright_foreground })
end

local repo_dir = root .. '/git/dataflow'
local project = { key = repo_dir, root = repo_dir, name = 'dataflow' }
local chat_id = '65085f48-95b0-4fc3-8835-e692449e439d'

-- The drawer's rows and keys: find a row by its text, move there and press a key.
local function drawer_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find('agents://drawer', 1, true) then return w end
  end
end
local function press_on(text, keys, anchor)
  local win = drawer_win()
  if not win then return end
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  local from = 1
  if anchor then
    for i, l in ipairs(lines) do
      if l:find(anchor, 1, true) then from = i; break end
    end
  end
  for i = from, #lines do
    local l = lines[i]
    -- only a closed row (▸) is opened; a row that is open already is left as it is
    if l:find(text, 1, true) and l:find('▸', 1, true) then
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
      return true
    end
  end
end

-- Sessions that run the scenarios of demo/scenarios: permission, done (unread), failed, and one that
-- keeps running with prompts queued behind its turn (the queue panel, `Q`).
local function run_scenarios()
  local runs = {
    { id = '2042fade-b41d-4f9a-b527-9a1f633fdd24', title = 'Backfill 2025 partitions', dir = repo_dir, prompts = { 'Backfill the 2025 partitions into orders.' } },
    { id = '5392a4f0-0939-436f-9d18-fb627d96ceb0', title = 'Fix flaky dbt test on customers', dir = repo_dir, prompts = { 'Fix the flaky freshness test on customers.' } },
    { id = 'afced7c9-3cf0-4a51-8d77-02865b03c0b0', title = 'Migrate config to TOML', dir = root .. '/git/neomd', prompts = { 'Migrate config.yaml to TOML.' } },
    { id = '4cc9c6cb-e2e5-4c3c-87e9-90a1d01fde20', title = 'Document lineage for the docs site', dir = root .. '/git/dataflow-docs', prompts = {
      'Add the orders and customers models to docs/lineage.md as a mermaid diagram.',
      'Link each model in the diagram to its SQL file.',
      'Add a short section on how the incremental load of orders works.',
      'Check the docs build and fix any broken links.',
    } },
  }
  for _, r in ipairs(runs) do
    local path = root .. '/projects/' .. (r.dir:gsub('[/.]', '-')) .. '/' .. r.id .. '.jsonl'
    local s = require('agent-ide.session').open({ id = r.id, cwd = r.dir, path = path, title = r.title })
    for _, p in ipairs(r.prompts) do s:send(p) end
  end
end

-- A prompt that was typed and not sent yet: the prompt buffer of the chat brings it back.
local function write_draft()
  local dir = root .. '/xdg/state/nvim/agent-ide/drafts'
  vim.fn.mkdir(dir, 'p')
  local f = io.open(dir .. '/' .. chat_id .. '.md', 'w')
  f:write('---\nagent-ide: draft\nsession: ' .. chat_id .. '\ncwd: ' .. repo_dir .. '\n---\n'
    .. '[attach] models/schema.yml\n\nRun the full dbt build and summarise what changed in the docs.\n')
  f:close()
end

local function open_chat()
  local s = require('agent-ide.session').open({ id = chat_id, cwd = repo_dir,
    path = root .. '/projects/' .. (repo_dir:gsub('[/.]', '-')) .. '/' .. chat_id .. '.jsonl',
    title = 'Incremental load for the orders model' })
  require('agent-ide.ui.chat').open(s, project)
  -- the transcript from its first prompt, not from its last line (after the chat has settled)
  vim.defer_fn(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
      if name:find('Incremental load', 1, true) and not name:find('prompt', 1, true) then
        vim.api.nvim_win_call(w, function() vim.cmd('normal! gg') end)
      end
    end
  end, 1500)
end

vim.schedule(function()
  if shot == 'graph' then
    return require('agent-ide.ui.graph').open({ root = repo_dir, project = project })
  end
  require('agent-ide').toggle()
  if shot == 'live' then
    -- the data and the running sessions only; every view is yours to open (see demo/README.md)
    return vim.defer_fn(run_scenarios, 300)
  end
  vim.defer_fn(function()
    if drawer_win() then vim.api.nvim_set_current_win(drawer_win()) end
    vim.api.nvim_feedkeys('z9', 'x', false)
    run_scenarios()
    -- the Library, the changes and the branch of the dataflow project, open as in the screenshot
    local project_row = 'dataflow feat/'
    local steps = { { 'Prompts', nil }, { 'Library (', nil }, { 'Changes vs HEAD', project_row },
      { 'Changes vs main', project_row }, { 'Commits on branch', project_row }, { 'uncommitted (', project_row } }
    for i, step in ipairs(steps) do
      vim.defer_fn(function() press_on(step[1], '<CR>', step[2]) end, 800 * i)
    end
    -- the Library again: the first press can land before the Prompts node has been drawn
    vim.defer_fn(function() press_on('Library (', '<CR>') end, 800 * (#steps + 1))
    vim.defer_fn(function()
      write_draft()
      open_chat()
    end, 800 * (#steps + 3))
  end, 300)
end)
