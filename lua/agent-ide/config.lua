-- User options merged over defaults. Lists (e.g. `live.cmd`) are replaced, not merged.
local M = {}

local defaults

---The defaults (a fresh table).
---@return table
function M.defaults() return defaults() end

defaults = function()
  return {
    projects_dir = vim.fn.expand('~/.claude/projects'),
    drawer = { width = 44, side = 'right', legend = true }, -- legend: the state marks at the bottom (gL)
    live = { interval_ms = 5000, cmd = { 'claude', 'agents', '--json' } },
    helper = { enabled = true, path = nil }, -- nil: <plugin root>/helper/target/release/agent-ide-helper
    -- modes: what <S-Tab> cycles through (plugin names; `manual` is Claude's `default`; plan has
    -- its own key, keys.chat.plan); default_mode: where the cycle starts before Claude reports a
    -- mode (nil: as if manual)
    claude = { cmd = { 'claude' }, strip_api_key = true, model = nil, version_check = true,
      modes = { 'manual', 'acceptEdits', 'auto' }, default_mode = nil,
      -- nil: the models Claude Code offers; a list of strings: exactly those
      models = nil },
    tcd = true,
    -- 'all' (every project) or 'project' (the git repository of Neovim's working directory):
    -- what the drawer, search, <leader>an and the footer show at start; `:Agents all|project`
    -- and `<S-Tab>` in the drawer switch it
    scope = 'all',
    -- false disables a mapping
    keys = {
      toggle = '<leader>aa',
      next_waiting = '<leader>an', -- global: the next session that needs you
      search = '<leader>as', -- global: search all sessions (titles, prompts, answers)
      prompt_history = '<leader>aP', -- global: every prompt, newest first
      -- the search picker's query line; each a key, a list of keys, or false (close: normal mode)
      search_picker = { next = { '<C-n>', '<Down>' }, prev = { '<C-p>', '<Up>' }, open = '<CR>', copy = '<C-y>',
        reuse = '<C-e>', scope = '<Tab>', kinds = '<C-f>', close = { '<Esc>', 'q' },
        -- the preview's next / previous occurrence of the query (]n / [n in normal mode only,
        -- <M-n> / <M-p> also in insert mode); after <CR>, the same step through the transcript
        next_match = { ']n', '<M-n>' }, prev_match = { '[n', '<M-p>' } },
      -- chat view, buffer-local in the transcript and the prompt
      chat = { send = '<C-CR>', send_alt = '<leader><CR>', interrupt = '<C-c>', prompt = '<leader>ap', help = 'g?',
        history_prev = '<C-p>', history_next = '<C-n>', attach = '<leader>af',
        answer_inner = 'ir', answer_outer = 'ar', mode = '<S-Tab>', plan = '<leader>am', model = { '<leader>aM', '<leader>M' },
        answer = '<leader>ay', raw = 'gr', raw_event = 'gR',
        -- continue the session in native Claude in a tmux pane (a typed key such as gT only in the
        -- transcript: the prompt buffer is where you edit text, gT stays Vim's there)
        native = { 'gT', '<leader>aT' },
        park = '<leader>ax', -- park: stop the session's Claude process (the next send resumes)
        compact = '<leader>aC', -- send /compact: Claude summarizes the conversation
        diff = { 'gd', '<leader>gd' },
        save_library = '<leader>W', -- prompt: save the prompt to the library (asks for a name)
        queue = { 'Q', '<leader>aQ' }, -- show or hide the queue panel (Q: Ex mode, which the prompt does not need)
        -- next / previous session of the project, in the drawer's order (also in the drawer;
        -- in the prompt buffer this takes over Vim's ]s / [s spelling motions)
        next_session = ']s', prev_session = '[s',
        prompts = '<leader>al' }, -- pick a prompt (skills, commands, library, saved)
      -- diff view, buffer-local on both sides; a one-character key (q, ?, R) only on the plugin's
      -- side, since the right side is your own file (there: macro, search, Replace stay yours).
      -- ]c / [c are Neovim's hunk motions. Each value is a key, a list of keys, or false
      diff = { next_file = { ']f', '<leader>gj' }, prev_file = { '[f', '<leader>gk' }, flip = { 'gb', '<leader>gt' },
        branch = { 'gB', '<leader>gB' }, close = { 'q', '<leader>gq' }, help = { '?', 'g?' },
        refresh = { 'R', '<leader>gR' }, lazygit = 'glg' },
      -- the drawer's own keys; each a key, a list of keys, or false. On a row that has its own
      -- handler for a key (a prompt row's keys below) that handler runs instead
      drawer = { open = { '<CR>', 'o' }, fold = 'za', collapse_all = 'z0', expand_all = 'z9', refresh = 'R',
        tmux = { 'gT', '<leader>aT' }, -- jump to the session's tmux pane, or continue it in native Claude there
        search = { 'S', '<leader>ff', '<leader>S' }, park = 'sP', hide = 'H', delete = 'D', yank = 'y',
        rename = 'r', -- a name of your own for the session (prompt rows: keys.prompts.rename)
        lazygit = 'glg', close = 'q', help = { '?', 'g?' }, graph = 'G', full_diff = 'gd', scope = '<S-Tab>',
        legend = { 'gL', '<leader>aL' }, close_tmux = 'X',
        next_session = ']s', prev_session = '[s' }, -- open the next / previous session of the project
      -- drawer, on prompt rows (elsewhere these keys keep their normal meaning)
      prompts = { edit = 'e', rename = 'r', delete = 'D', yank = 'y', to_library = 'sL' },
      -- commit graph view, buffer-local; each a key, a list of keys, or false
      graph = { open = '<CR>', next_commit = ']]', prev_commit = '[[', full_diff = 'gd', all = 'a', refresh = 'R', more = 'L',
        yank = 'y', lazygit = 'glg', close = 'q', help = 'g?' },
      -- full diff view (every change of a branch in one buffer), buffer-local; each a key, a list
      -- of keys, or false
      full_diff = { open = '<CR>', next_file = ']f', prev_file = '[f', next_hunk = ']c', prev_hunk = '[c', fold = 'za',
        collapse_all = 'z0', expand_all = 'z9', refresh = 'R', yank = 'y', lazygit = 'glg', close = 'q', help = 'g?' },
    },
    -- graph_limit: commits the commit graph loads at first (and L loads more of). delta: the
    -- full diff's colours through delta (https://github.com/dandavison/delta): 'auto' when it is
    -- installed, false never, or a command list of your own
    git = { graph_limit = 300, delta = 'auto' },
    -- Prompts: Claude's commands and skills (read only), the library of templates and per-project
    -- saved prompts. nil dirs: stdpath('data') .. '/agent-ide/library' and '/agent-ide/prompts'
    prompts = { library_dir = nil, saved_dir = nil, command_dirs = { '~/.claude/commands' },
      skill_dirs = { '~/.claude/skills' }, project_dirs = true },
    -- footer quota: `file` (nil: off) is a JSON file another tool writes,
    -- { "limits": [ { "label", "percent" (fraction used), "resetsAt" } ], "updatedAt" }; when it is
    -- readable and fresh (30 min) the footer shows those limits instead of its own
    quota = { file = nil },
    -- deleted sessions (`D` in the drawer) stay in stdpath('data')/agent-ide/trash until
    -- `:AgentsTrash empty`; keep_days (nil: keep) purges older ones at setup
    trash = { keep_days = nil },
    -- prompt buffer: `/` opens the command menu, `@` opens the file picker; prompt_label: a dim
    -- `↑ title · model` on the prompt window's winbar naming the session it sends to
    chat = { auto_slash = true, at_picker = true, prompt_label = true },
    -- context: the size of a session's conversation (the input tokens of its last request; the
    -- chat's winbar shows it as `~123k`). From `threshold` tokens on (false: never) the plugin
    -- asks before a send that resumes a session without a process (Send / Compact first /
    -- Cancel: the resume reads the whole conversation again) and, on park, offers to compact
    -- first; confirm_resume and compact_before_park turn either question off. From `large`
    -- tokens on (false: never) the queue panel marks the session `▲ large`
    context = { threshold = 50000, confirm_resume = true, compact_before_park = true, large = 200000 },
    -- a soft chime when a session needs you (waiting); chime: two, soft, bell, rising or pop
    -- (`:AgentsChime <name>` plays one); cmd: the player (nil: pw-play, paplay, aplay or afplay,
    -- whichever exists), the chime's WAV path is appended
    sound = { waiting = true, chime = 'two', cmd = nil },
    -- keeper: Claude runs under a small detached process of the plugin's, so quitting Neovim
    -- leaves it running and a new Neovim reattaches; idle_minutes: an idle Claude with no Neovim
    -- attached is closed after that long (false: never). enabled = false: a child of Neovim
    keeper = { enabled = true, idle_minutes = 30 },
    -- 'nerd' (needs a Nerd Font in the terminal) or 'plain'; `icons` overrides single entries
    -- of that set (see ui/icons.lua for the keys); an empty string hides an icon
    icons_style = 'nerd',
    icons = {},
  }
end

local function is_map(t) return type(t) == 'table' and (next(t) == nil or not vim.islist(t)) end

local function merge(base, over)
  for k, v in pairs(over) do
    if is_map(v) and is_map(base[k]) then
      merge(base[k], v)
    else
      base[k] = vim.deepcopy(v)
    end
  end
  return base
end

local current

---@param opts? table
---@return table
function M.setup(opts)
  current = merge(defaults(), opts or {})
  current.icons = require('agent-ide.ui.icons').resolve(current.icons_style, current.icons)
  return current
end

---@return table
function M.get() return current or M.setup() end

return M
