-- sound.lua: the chime when a session needs you.
local eq = MiniTest.expect.equality
local sound = require('agent-ide.sound')
local config = require('agent-ide.config')
local session = require('agent-ide.session')

local tmp, log

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    log = tmp .. '/played'
    vim.fn.delete(sound._file())
    sound._reset()
    session._reset()
    -- a fake player: logs the file it was given
    config.setup({ sound = { cmd = { 'sh', '-c', 'echo "$1" >> ' .. vim.fn.shellescape(log), 'player' } } })
    sound.setup()
  end,
  post_case = function()
    vim.fn.delete(tmp, 'rf')
    vim.fn.delete(sound._file())
    session._reset()
    config.setup({})
  end,
} })

local function played()
  if vim.fn.filereadable(log) == 0 then return {} end
  return vim.fn.readfile(log)
end

local function wait_played(n)
  vim.wait(2000, function() return #played() >= n end, 20)
  return played()
end

T['the WAV is a valid 16-bit mono RIFF file, written once as 0600 in a 0700 folder'] = function()
  local pcm = sound.samples()
  local wav = sound.wav(pcm)
  eq(wav:sub(1, 4), 'RIFF')
  eq(wav:sub(9, 16), 'WAVEfmt ')
  eq(wav:sub(37, 40), 'data')
  eq(#wav, 44 + #pcm)
  eq(#pcm % 2, 0)
  eq(#pcm > 22050 * 2 * 0.4 and #pcm < 22050 * 2 * 0.5, true) -- about 0.44 s
  -- channels 1, rate 22050, bits 16
  eq({ wav:byte(23), wav:byte(24) }, { 1, 0 })
  eq({ wav:byte(25), wav:byte(26), wav:byte(27), wav:byte(28) }, { 22050 % 256, math.floor(22050 / 256), 0, 0 })
  eq({ wav:byte(35), wav:byte(36) }, { 16, 0 })
  sound.play(true)
  local p = wait_played(1)
  eq(p[1], sound._file())
  local st = vim.uv.fs_stat(sound._file())
  eq(bit.band(st.mode, 511), 384)
  eq(bit.band(vim.uv.fs_stat(vim.fs.dirname(sound._file())).mode, 511), 448)
  eq(vim.fn.readfile(sound._file(), 'b')[1]:sub(1, 4), 'RIFF')
end

T['a session turning waiting chimes once; a second within 2 s does not; off with sound.waiting = false'] = function()
  local s = session.open({ cwd = tmp })
  s:_set_state('busy')
  s:_set_state('waiting')
  eq(#wait_played(1), 1)
  s:_set_state('busy')
  s:_set_state('waiting')
  vim.wait(200)
  eq(#played(), 1)
  sound.RATE_MS = 0
  s:_set_state('busy')
  s:_set_state('waiting')
  eq(#wait_played(2), 2)
  sound.RATE_MS = 2000
  config.get().sound.waiting = false
  sound._reset()
  s:_set_state('busy')
  s:_set_state('waiting')
  vim.wait(200)
  eq(#played(), 2)
  -- other states never chime
  config.get().sound.waiting = true
  sound._reset()
  for _, st in ipairs({ 'busy', 'idle', 'done', 'failed', 'parked' }) do s:_set_state(st) end
  vim.wait(200)
  eq(#played(), 2)
end

T['without a player: one notice, nothing played; the default picks an installed one'] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(m) notes[#notes + 1] = m end
  config.setup({ sound = { cmd = nil } })
  local exe = vim.fn.executable
  vim.fn.executable = function() return 0 end
  sound.play(true)
  sound.play(true)
  vim.fn.executable = exe
  vim.notify = orig
  eq(#notes, 1)
  eq(notes[1]:find('no sound player found', 1, true) ~= nil, true)
  vim.fn.executable = function(name) return name == 'paplay' and 1 or 0 end
  eq(sound.player(), { 'paplay' })
  vim.fn.executable = exe
  eq(played(), {})
end

return T
