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
  local out = '/dev/pts/3 work:1.0\n/dev/pts/9 neomd:2.1\n'
  eq(tmux.match_pane('pts/9', out), 'neomd:2.1')
  eq(tmux.match_pane('/dev/pts/3', out), 'work:1.0')
  eq(tmux.match_pane('pts/4', out), nil)
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
