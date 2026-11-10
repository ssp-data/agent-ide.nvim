-- The state words of session rows (drawer_model.note_of), from Sessions of this Neovim and the
-- live map, without any process.
local model = require('agent-ide.ui.drawer_model')
local session = require('agent-ide.session')
local live = require('agent-ide.live')
local tmux = require('agent-ide.tmux')
local eq = MiniTest.expect.equality

local live_map = {}
local orig_get
local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    session._reset()
    live_map = {}
    orig_get = live.get
    live.get = function() return live_map end
    tmux._reset_labels()
  end,
  post_case = function()
    live.get = orig_get
    session._reset()
    package.loaded['agent-ide.ui.handoff'] = nil
    tmux._reset_labels()
  end,
} })

local function mine(state, extra)
  local s = session.open({ cwd = '/w' })
  s.state = state
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

T['waiting: what the oldest ask is'] = function()
  local s = mine('waiting', { pending_permissions = { { request_id = 'p1', tool_name = 'Bash' }, { request_id = 'p2', tool_name = 'Write' } } })
  eq(model.note_of(s.id, 'waiting'), { 'permission: Bash', 'AgentIdeWaiting' })
  s.pending_permissions = { { request_id = 'q', tool_name = 'AskUserQuestion' } }
  eq(model.note_of(s.id, 'waiting'), { 'question', 'AgentIdeWaiting' })
  s.pending_permissions = { { request_id = 'x', tool_name = 'ExitPlanMode' } }
  eq(model.note_of(s.id, 'waiting'), { 'plan to approve', 'AgentIdeWaiting' })
  -- waiting in another Claude: only that input is needed
  live_map['other'] = { status = 'waiting', pid = 7 }
  eq(model.note_of('other', 'waiting'), { 'input', 'AgentIdeWaiting' })
end

T['done and failed: unread, and the start of the last error'] = function()
  local s = mine('done')
  eq(model.note_of(s.id, 'done'), { 'done, unread', 'AgentIdeDone' })
  s = mine('failed')
  eq(model.note_of(s.id, 'failed'), { 'failed', 'AgentIdeFailed' })
  s.events = { { kind = 'meta', label = 'error', text = 'old' }, { kind = 'text', text = 'x' },
    { kind = 'meta', label = 'error', text = 'quota\nmore lines' } }
  eq(model.note_of(s.id, 'failed'), { 'failed: quota', 'AgentIdeFailed' })
  s.events[3].text = 'Claude exited (code 1) with a long tail'
  local t = model.note_of(s.id, 'failed')[1]
  eq(t, 'failed: Claude exited (code…')
  eq(vim.fn.strchars(t:sub(#'failed: ' + 1)), 20)
end

T['busy and idle here: nothing; parked: nothing'] = function()
  local s = mine('busy')
  eq(model.note_of(s.id, 'busy'), nil)
  eq(model.note_of(s.id, 'idle'), nil)
  eq(model.note_of('unknown', 'parked'), nil)
end

T['running in another Claude: its tmux pane when known, else elsewhere'] = function()
  live_map['ext'] = { status = 'busy', pid = 42 }
  eq(model.note_of('ext', 'busy'), { 'elsewhere', 'AgentIdeAge' })
  local saved_env, saved_system = vim.env.TMUX, vim.system
  vim.env.TMUX = '/tmp/fake,1,0'
  vim.system = function(cmd, _, cb)
    cb(cmd[1] == 'ps' and { code = 0, stdout = '42 pts/9\n' } or { code = 0, stdout = '/dev/pts/9 2.1\n' })
    return {}
  end
  local ok, err = pcall(function()
    eq(model.elsewhere_pids(), { 42 })
    local changed = false
    tmux.refresh_labels(model.elsewhere_pids(), function() changed = true end)
    vim.wait(500, function() return changed end)
    eq(model.note_of('ext', 'busy'), { 'tmux 2.1', 'AgentIdeAge' })
    eq(model.note_of('ext', 'idle'), { 'tmux 2.1', 'AgentIdeAge' })
  end)
  vim.system, vim.env.TMUX = saved_system, saved_env
  if not ok then error(err, 0) end
  -- a Session of this Neovim with a live process of its own is not elsewhere
  local s = mine('busy', { pid = 5, proc = { alive = function() return true end, stop = function() end } })
  live_map[s.id] = { status = 'busy', pid = 5 }
  eq(model.note_of(s.id, 'busy'), nil)
  eq(vim.tbl_contains(model.elsewhere_pids(), 5), false)
end

T['handed to native Claude: native, whatever the live state'] = function()
  local s = mine('parked')
  package.loaded['agent-ide.ui.handoff'] = { away = function(x) return x == s end }
  live_map[s.id] = { status = 'busy', pid = 9 }
  eq(model.note_of(s.id, 'busy'), { 'native', 'AgentIdeAge' })
  eq(model.note_of(s.id, 'waiting'), { 'native', 'AgentIdeAge' })
end

return T
