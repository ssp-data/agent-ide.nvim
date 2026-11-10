-- Before keys are typed into a tmux pane to close a Claude (ui/tmux_close.lua): is that Claude
-- really what the pane shows, in its foreground, ready for keys? One `ps` and one
-- `tmux list-panes`, asynchronously. Every condition must hold; anything that cannot be checked
-- counts as a failed check:
-- - the process runs, is a Claude (`comm` is `claude`, or `node` for an npm install), and sits
--   on a terminal;
-- - a tmux pane has that terminal;
-- - the process's group is the terminal's foreground group (not suspended with Ctrl-Z behind
--   another program, not a background job; a Claude started by another Neovim, `claude -p` or
--   in its `:terminal`, is never the foreground of the pane's own terminal);
-- - the pane is not in copy mode or another mode, and its window does not synchronize panes.
local M = {}

M.COMMS = { claude = true, node = true }

M.PS = { 'ps', '-A', '-o', 'pid=,ppid=,pgid=,tpgid=,tty=,comm=' }
M.PANES = { 'tmux', 'list-panes', '-a', '-F',
  '#{pane_id} #{pane_pid} #{pane_tty} #{pane_in_mode} #{pane_synchronized} #{window_index}.#{pane_index}' }

local function run(cmd, cb)
  local ok = pcall(vim.system, cmd, { text = true, timeout = 2000 }, function(res) vim.schedule(function() cb(res) end) end)
  if not ok then vim.schedule(function() cb({ code = 127, stdout = '' }) end) end
end

local function no_dev(tty) return (tty:gsub('^/dev/', '')) end

---@param out string lines of `ps -A -o pid=,ppid=,pgid=,tpgid=,tty=,comm=`
---@return table<integer, { pgid: integer, tpgid: integer, tty: string, comm: string }>
function M.parse_ps(out)
  local procs = {}
  for line in vim.gsplit(out or '', '\n', { plain = true }) do
    local pid, _, pgid, tpgid, tty, comm = line:match('^%s*(%d+)%s+(%d+)%s+(%d+)%s+(%-?%d+)%s+(%S+)%s+(.-)%s*$')
    if pid then
      procs[tonumber(pid)] = { pgid = tonumber(pgid), tpgid = tonumber(tpgid), tty = no_dev(tty), comm = comm }
    end
  end
  return procs
end

---@param out string lines of `M.PANES`
---@return { id: string, pid: integer, tty: string, in_mode: boolean, sync: boolean, label: string }[]
function M.parse_panes(out)
  local panes = {}
  for line in vim.gsplit(out or '', '\n', { plain = true }) do
    local id, pid, tty, mode, sync, label = line:match('^(%%%d+)%s+(%d+)%s+(%S+)%s+(%d+)%s+(%d*)%s*(%S+)$')
    if id then
      panes[#panes + 1] = { id = id, pid = tonumber(pid), tty = no_dev(tty), in_mode = mode ~= '0', sync = sync == '1',
        label = label }
    end
  end
  return panes
end

---The pane to type into for Claude `pid`, or nil and why not (a few words).
---@param pid integer
---@param procs table from `parse_ps`
---@param panes table[] from `parse_panes`
---@return table|nil pane, string|nil reason
function M.verify(pid, procs, panes)
  local p = procs[pid]
  if not p then return nil, 'it no longer runs' end
  local base = p.comm:match('([^/]+)$') or p.comm
  if not M.COMMS[base] then return nil, 'that process is not Claude' end
  if p.tty == '?' or p.tty == '??' or p.tty == '' then return nil, 'it has no terminal' end
  local pane
  for _, x in ipairs(panes) do
    if x.tty == p.tty then pane = x end
  end
  if not pane then return nil, 'no tmux pane shows it' end
  if p.pgid ~= p.tpgid then return nil, 'it is not in the foreground of its pane' end
  if pane.in_mode then return nil, 'its pane is in copy mode' end
  if pane.sync then return nil, 'its window synchronizes panes' end
  return pane
end

---Check `pids` now: `cb(result)` with `result[pid] = { pane = … }` or `{ reason = … }`.
---@param pids integer[]
---@param cb fun(result: table<integer, { pane?: table, reason?: string }>)
function M.lookup(pids, cb)
  run(M.PS, function(ps)
    local out = {}
    if ps.code ~= 0 then
      for _, pid in ipairs(pids) do out[pid] = { reason = 'cannot read the process list' } end
      return cb(out)
    end
    local procs = M.parse_ps(ps.stdout)
    run(M.PANES, function(lp)
      local panes = lp.code == 0 and M.parse_panes(lp.stdout) or nil
      for _, pid in ipairs(pids) do
        if not panes then
          out[pid] = { reason = 'cannot list the tmux panes' }
        else
          local pane, why = M.verify(pid, procs, panes)
          out[pid] = pane and { pane = pane } or { reason = why }
        end
      end
      cb(out)
    end)
  end)
end

return M
