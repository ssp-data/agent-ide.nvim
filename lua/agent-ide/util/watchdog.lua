-- Debug aid for a frozen Neovim: when one stretch of Lua keeps the main loop busy for more than
-- `secs` seconds, write where it is (a Lua traceback) to `stdpath('state')/agent-ide/stuck.log`.
-- A frozen loop runs no timers, so this uses a count hook; hooks only fire in interpreted code,
-- so the JIT is switched off while the watchdog is on. Slower: for finding a freeze only.
-- Enabled by starting Neovim with AGENT_IDE_WATCHDOG=1 (optionally =<seconds>).
local M = {}

function M.start(secs)
  secs = tonumber(secs) or 5
  if secs < 2 then secs = 5 end -- `=1` just switches it on
  local dir = vim.fn.stdpath('state') .. '/agent-ide'
  vim.fn.mkdir(dir, 'p', tonumber('700', 8))
  local path = dir .. '/stuck.log'
  local last, dumps = os.clock(), 0
  -- the loop is alive whenever this timer runs
  M.timer = vim.uv.new_timer()
  M.timer:start(0, 250, function() last = os.clock() end)
  if jit then jit.off() end
  debug.sethook(function()
    if os.clock() - last < secs or dumps >= 5 then return end
    dumps = dumps + 1
    last = os.clock()
    local f = io.open(path, 'a')
    if not f then return end
    f:write(('--- %s  busy for more than %d s (dump %d of 5)\n'):format(os.date('%Y-%m-%d %H:%M:%S'), secs, dumps),
      debug.traceback('', 2), '\n\n')
    f:close()
  end, '', 1e6)
  return path
end

return M
