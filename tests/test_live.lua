local live = require('agent-ide.live')
local tmux = require('agent-ide.tmux')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = {
  pre_case = function() live._reset() end,
  post_case = function() live._reset() end,
} })

T['parse keeps sessions by id, ignores garbage'] = function()
  local m = live.parse('[{"pid":7,"cwd":"/r","kind":"interactive","sessionId":"s1","name":"n","status":"busy"}]')
  eq(m.s1, { status = 'busy', pid = 7, cwd = '/r', name = 'n' })
  eq(live.parse('Error: not logged in'), {})
  eq(live.parse('{"a":1}'), {})
end

T['state_of and rollup'] = function()
  local m = { a = { status = 'idle' }, b = { status = 'weird' } }
  eq({ live.state_of(m, 'a'), live.state_of(m, 'b'), live.state_of(m, 'zz') }, { 'idle', 'parked', 'parked' })
  eq(live.rollup({ 'idle', 'busy', 'parked' }), 'busy')
  eq(live.rollup({ 'busy', 'waiting' }), 'waiting')
  eq(live.rollup({}), 'parked')
end

T['start: missing command gives empty map and one notice'] = function()
  local notices, changes = 0, 0
  local orig = vim.notify
  vim.notify = function() notices = notices + 1 end
  live.start({ interval_ms = 30, cmd = { 'agent-ide-no-such-binary' }, on_change = function() changes = changes + 1 end })
  vim.wait(200)
  live.stop()
  vim.notify = orig
  eq(live.get(), {})
  eq(notices, 1)
end

T['start: non-zero exit gives empty map and one notice'] = function()
  local notices = 0
  local orig = vim.notify
  vim.notify = function() notices = notices + 1 end
  live.start({ interval_ms = 30, cmd = { 'false' }, on_change = function() end })
  vim.wait(200)
  live.stop()
  vim.notify = orig
  eq(live.get(), {})
  eq(notices, 1)
end

T['start: reports a change once'] = function()
  local n = 0
  live.start({ interval_ms = 30, cmd = { 'echo', '[{"sessionId":"s","status":"idle","pid":1,"cwd":"/"}]' }, on_change = function() n = n + 1 end })
  vim.wait(200)
  live.stop()
  eq(n, 1)
  eq(live.get().s.status, 'idle')
end

T['stop: result arriving after stop does not call on_change'] = function()
  local n = 0
  live.start({
    interval_ms = 1000,
    cmd = { 'sh', '-c', 'sleep 0.1; echo \'[{"sessionId":"s","status":"busy","pid":1,"cwd":"/"}]\'' },
    on_change = function() n = n + 1 end,
  })
  live.stop()
  vim.wait(400)
  eq(n, 0)
  eq(live.get(), {})
end

T['match_pane'] = function()
  local out = '/dev/pts/3 %1\n/dev/pts/9 %12\n'
  eq(tmux.match_pane('pts/9', out), '%12')
  eq(tmux.match_pane('/dev/pts/3', out), '%1')
  eq(tmux.match_pane('pts/4', out), nil)
end

T['jump_to_pid targets the pane id, whatever the session name'] = function()
  local saved_env, saved_system = vim.env.TMUX, vim.system
  vim.env.TMUX = '/tmp/fake,1,0'
  local cmds = {}
  local replies = {
    ps = { code = 0, stdout = 'pts/9\n' },
    ['list-panes'] = { code = 0, stdout = '/dev/pts/3 %1\n/dev/pts/9 %12\n' },
    ['switch-client'] = { code = 0, stdout = '' },
  }
  vim.system = function(cmd, _, cb)
    cmds[#cmds + 1] = cmd
    cb(replies[cmd[1] == 'ps' and 'ps' or cmd[2]])
    return {}
  end
  local got
  tmux.jump_to_pid(42, function(ok, reason) got = { ok, reason } end)
  vim.wait(500, function() return got ~= nil end)
  vim.system, vim.env.TMUX = saved_system, saved_env
  eq(got, { true, nil })
  eq(cmds[2], { 'tmux', 'list-panes', '-a', '-F', '#{pane_tty} #{pane_id}' })
  eq(cmds[3], { 'tmux', 'switch-client', '-t', '%12' })
end

T['start: a hung command is killed and polling goes on'] = function()
  local polls = 0
  local orig = vim.notify
  vim.notify = function() end
  live.start({ interval_ms = 30, timeout_ms = 100, cmd = { 'sleep', '10' }, on_poll = function() polls = polls + 1 end })
  local ok = vim.wait(2000, function() return polls >= 2 end, 10)
  live.stop()
  vim.notify = orig
  eq(ok, true)
  vim.fn.system({ 'pgrep', '-P', tostring(vim.fn.getpid()), '-x', 'sleep' })
  eq(vim.v.shell_error ~= 0, true) -- no sleep left behind
end

T['start: on_poll runs after every poll, on_change only on change'] = function()
  local polls, changes = 0, 0
  live.start({ interval_ms = 30, cmd = { 'echo', '[]' },
    on_change = function() changes = changes + 1 end, on_poll = function() polls = polls + 1 end })
  vim.wait(2000, function() return polls >= 3 end, 10)
  live.stop()
  eq(polls >= 3, true)
  eq(changes, 0)
  eq(live.active(), false)
end

T['jump_to_pid: not in tmux'] = function()
  local saved = vim.env.TMUX
  vim.env.TMUX = nil
  local got
  tmux.jump_to_pid(1, function(ok, reason) got = { ok, reason } end)
  vim.env.TMUX = saved
  vim.wait(200, function() return got ~= nil end)
  eq(got, { false, 'not in tmux' })
end

return T
