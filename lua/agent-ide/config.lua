-- User options merged over defaults. Lists (e.g. `live.cmd`) are replaced, not merged.
local M = {}

local function defaults()
  return {
    projects_dir = vim.fn.expand('~/.claude/projects'),
    drawer = { width = 44, side = 'right' },
    live = { interval_ms = 5000, cmd = { 'claude', 'agents', '--json' } },
    helper = { enabled = true, path = nil }, -- nil: <plugin root>/helper/target/release/agent-ide-helper
    -- modes: what <S-Tab> cycles through (plugin names; `manual` is Claude's `default`);
    -- default_mode: where the cycle starts before Claude reports a mode (nil: as if manual)
    claude = { cmd = { 'claude' }, strip_api_key = true, model = nil,
      modes = { 'manual', 'acceptEdits', 'plan', 'auto' }, default_mode = nil,
      models = { 'fable', 'opus', 'sonnet', 'haiku' } },
    tcd = true,
    -- false disables a mapping
    keys = {
      toggle = '<leader>aa',
      next_waiting = '<leader>an', -- global: the next session that needs you
      search = '<leader>as', -- global: search all sessions (titles, prompts, answers)
      prompt_history = '<leader>aP', -- global: every prompt, newest first
      -- chat view, buffer-local in the transcript and the prompt
      chat = { send = '<C-CR>', send_alt = '<leader><CR>', interrupt = '<C-c>', prompt = '<leader>ap', help = '?',
        history_prev = '<C-p>', history_next = '<C-n>', attach = '<leader>af',
        answer_inner = 'ir', answer_outer = 'ar', mode = '<S-Tab>', model = '<leader>aM', answer = '<leader>ay' },
    },
    -- prompt buffer: `/` opens the command menu, `@` opens the file picker
    chat = { auto_slash = true, at_picker = true },
    icons = { open = '▾', closed = '▸', project = '', waiting = '◐', busy = '●', idle = '○', parked = '·',
      done = '✔', failed = '✖', new = '+' },
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
  return current
end

---@return table
function M.get() return current or M.setup() end

return M
