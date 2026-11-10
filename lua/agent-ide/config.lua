-- User options merged over defaults. Lists (e.g. `live.cmd`) are replaced, not merged.
local M = {}

local function defaults()
  return {
    projects_dir = vim.fn.expand('~/.claude/projects'),
    drawer = { width = 44, side = 'right' },
    live = { interval_ms = 5000, cmd = { 'claude', 'agents', '--json' } },
    helper = { enabled = true, path = nil }, -- nil: <plugin root>/helper/target/release/agent-ide-helper
    claude = { cmd = { 'claude' }, strip_api_key = true, model = nil },
    tcd = true,
    -- false disables a mapping
    keys = {
      toggle = '<leader>aa',
      -- chat view, buffer-local in the transcript and the prompt
      chat = { send = '<C-CR>', send_alt = '<leader><CR>', interrupt = '<C-c>', prompt = '<leader>ap', help = '?' },
    },
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
