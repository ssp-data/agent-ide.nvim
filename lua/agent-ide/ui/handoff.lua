-- Hand a chat session over to native Claude in a tmux pane, and take it back when that Claude
-- exits: park the session here, run `claude --resume <id>` in a split, wait (asynchronously)
-- on a tmux channel the pane signals when Claude ends; the chat then reloads it from disk.
-- Outside tmux the session is parked and the command to run by hand is shown.
local M = {}

local away = {} -- session id -> true while native Claude in a tmux pane has the session

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end

local function run(cmd, cb)
  local ok = pcall(vim.system, cmd, { text = true }, function(res) vim.schedule(function() cb(res) end) end)
  if not ok then vim.schedule(function() cb({ code = 127 }) end) end
end

---Shell command the pane runs: the configured Claude (without the API key unless the user
---allows it), then the signal that brings the session back.
---@param s table Session
---@param channel string
---@return string
function M.pane_command(s, channel)
  local cfg = require('agent-ide.config').get().claude
  local argv = vim.deepcopy(cfg.cmd)
  vim.list_extend(argv, { '--resume', s.id })
  local words = vim.tbl_map(vim.fn.shellescape, argv)
  local prefix = cfg.strip_api_key and 'env -u ANTHROPIC_API_KEY ' or ''
  return prefix .. table.concat(words, ' ') .. '; tmux wait-for -S ' .. channel
end

---True while native Claude in a tmux pane has session `s`.
---@param s table Session
---@return boolean
function M.away(s) return away[s.id] == true end

---Park `s` (asks first when it is working) and continue it in native Claude.
---@param s table Session
---@param on { away: fun(s: table), back: fun(s: table) } `away` once the session is handed
---  over, `back` after native Claude exited (the caller reloads the session from disk)
function M.start(s, on)
  if away[s.id] then return notify('this session is already open in native Claude (tmux pane)') end
  local in_tmux = vim.env.TMUX ~= nil and vim.env.TMUX ~= ''
  s:park(function(parked)
    if not parked then return end
    if not in_tmux then
      return notify(('parked; not in tmux, so continue it by hand: cd %s && claude --resume %s')
        :format(vim.fn.shellescape(s.cwd or '.'), s.id))
    end
    away[s.id] = true
    on.away(s)
    local channel = 'agent-ide-' .. s.id
    -- wait first, so the signal cannot come before anyone listens
    run({ 'tmux', 'wait-for', channel }, function()
      away[s.id] = nil
      on.back(s)
    end)
    run({ 'tmux', 'split-window', '-h', '-c', s.cwd, M.pane_command(s, channel) }, function(res)
      if res.code == 0 then return end
      notify(('cannot open a tmux pane; continue by hand: cd %s && claude --resume %s')
        :format(vim.fn.shellescape(s.cwd or '.'), s.id), vim.log.levels.WARN)
      run({ 'tmux', 'wait-for', '-S', channel }, function() end) -- releases our own wait
    end)
  end)
end

function M._reset() away = {} end

return M
