-- The Claude Code versions this plugin was tested with, and the one found installed. The
-- version is asked once per Neovim session, at the first process start, without blocking.
local M = {}

---Versions whose output the plugin was tested against.
M.tested = { '2.1.306' }

local TIMEOUT_MS = 10000

local found, checked = nil, false

---@param text string|nil output of `claude --version`
---@return string|nil the first x.y.z in it
function M.parse(text)
  return type(text) == 'string' and text:match('%d+%.%d+%.%d+') or nil
end

---@param v string
---@return boolean
function M.is_tested(v)
  return vim.tbl_contains(M.tested, v)
end

---The version found by the check, nil before it finished, when it failed or when it printed none.
---@return string|nil
function M.found() return found end

---Run `<claude.cmd> --version` (once per Neovim session) and tell the user, once, when the
---version is not a tested one. Silent when the command fails or prints no version.
function M.check()
  local cfg = require('agent-ide.config').get().claude
  if checked or cfg.version_check == false then return end
  checked = true
  local argv = vim.deepcopy(cfg.cmd)
  argv[#argv + 1] = '--version'
  local env = require('agent-ide.claude.process').child_env()
  pcall(vim.system, argv, { text = true, env = env, clear_env = env ~= nil, timeout = TIMEOUT_MS },
    vim.schedule_wrap(function(obj)
      local v = obj.code == 0 and M.parse((obj.stdout or '') .. ' ' .. (obj.stderr or '')) or nil
      if not v then return end
      found = v
      if not M.is_tested(v) then
        vim.notify(('Agent-IDE: tested with Claude Code %s, found %s; unknown output will show as folds')
          :format(table.concat(M.tested, ', '), v), vim.log.levels.INFO)
      end
    end))
end

---Forget the check (tests only).
function M._reset() found, checked = nil, false end

return M
