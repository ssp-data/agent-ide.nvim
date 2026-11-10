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

-- Pane labels of processes for the drawer --------------------------------------------------

local labels = {} -- pid -> '<window>.<pane>'
local pending = false -- a refresh is running

local function in_tmux() return vim.env.TMUX ~= nil and vim.env.TMUX ~= '' end

---`<window>.<pane>` of the tmux pane running `pid`, from the last refresh; nil when unknown.
---@param pid integer
---@return string|nil
function M.pane_label(pid) return labels[pid] end

---@param out string lines of `ps -o pid=,tty=`
---@return table<integer, string> pid -> tty
function M.parse_ps(out)
  local ttys = {}
  for line in vim.gsplit(out or '', '\n', { plain = true }) do
    local pid, tty = line:match('^%s*(%d+)%s+(%S+)')
    if pid and tty ~= '?' and tty ~= '??' then ttys[tonumber(pid)] = tty end
  end
  return ttys
end

---Look up the panes of `pids` asynchronously (one `ps` and one `tmux list-panes`, never
---blocking); `on_change()` runs when a label changed. Outside tmux there are no labels.
---@param pids integer[]
---@param on_change fun()
function M.refresh_labels(pids, on_change)
  if not in_tmux() or #pids == 0 then
    if next(labels) ~= nil then
      labels = {}
      on_change()
    end
    return
  end
  if pending then return end
  pending = true
  local function run(cmd, cb)
    local ok = pcall(vim.system, cmd, { text = true, timeout = 2000 }, function(res) vim.schedule(function() cb(res) end) end)
    if not ok then vim.schedule(function() cb({ code = 127, stdout = '' }) end) end
  end
  local list = vim.tbl_map(tostring, pids)
  run({ 'ps', '-o', 'pid=,tty=', '-p', table.concat(list, ',') }, function(ps)
    local ttys = M.parse_ps(ps.stdout)
    run({ 'tmux', 'list-panes', '-a', '-F', '#{pane_tty} #{window_index}.#{pane_index}' }, function(lp)
      pending = false
      local new = {}
      if lp.code == 0 then
        for pid, tty in pairs(ttys) do new[pid] = M.match_pane(tty, lp.stdout) end
      end
      if not vim.deep_equal(new, labels) then
        labels = new
        on_change()
      end
    end)
  end)
end

---Test only: forget the labels.
function M._reset_labels() labels, pending = {}, false end

return M
