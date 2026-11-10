-- Switch the tmux client to the pane running a given process. Read-only otherwise.
local M = {}

---@param tty string  with or without the /dev/ prefix
---@param list_panes_output string  lines of `<pane_tty> <pane_id>` (pane ids like `%3` never hold spaces)
---@return string|nil
function M.match_pane(tty, list_panes_output)
  local want = tty:gsub('^/dev/', '')
  for line in vim.gsplit(list_panes_output or '', '\n', { plain = true }) do
    local pane_tty, target = line:match('^(%S+)%s+(%S+)$')
    if pane_tty and pane_tty:gsub('^/dev/', '') == want then return target end
  end
  return nil
end

---@param pid integer
---@param cb fun(ok: boolean, reason: string|nil)
function M.jump_to_pid(pid, cb)
  if not vim.env.TMUX or vim.env.TMUX == '' then
    vim.schedule(function() cb(false, 'not in tmux') end)
    return
  end
  local function run(cmd, on_done)
    local ok = pcall(vim.system, cmd, { text = true }, function(res) vim.schedule(function() on_done(res) end) end)
    if not ok then vim.schedule(function() on_done({ code = 127, stdout = '' }) end) end
  end
  run({ 'ps', '-o', 'tty=', '-p', tostring(pid) }, function(ps)
    local tty = vim.trim(ps.stdout or '')
    if ps.code ~= 0 or tty == '' or tty == '?' or tty == '??' then return cb(false, 'process not found') end
    run({ 'tmux', 'list-panes', '-a', '-F', '#{pane_tty} #{pane_id}' }, function(lp)
      local target = lp.code == 0 and M.match_pane(tty, lp.stdout) or nil
      if not target then return cb(false, 'pane not found') end
      run({ 'tmux', 'switch-client', '-t', target }, function(sw)
        if sw.code == 0 then cb(true) else cb(false, 'pane not found') end
      end)
    end)
  end)
end

return M
