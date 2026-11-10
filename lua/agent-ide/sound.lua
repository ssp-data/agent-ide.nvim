-- A soft chime when a session needs you (its state turns `waiting`: a permission, a question,
-- a plan to approve). The notes of the chosen chime (`sound.chime`, one of CHIMES) are written
-- once as a small WAV file to stdpath('cache')/agent-ide/chime-<name>.wav and played by a
-- system player (`sound.cmd`, else the first of pw-play, paplay, aplay, afplay found),
-- detached, never blocking, at most once every RATE_MS. Without a player one notice says so.
-- `sound = { waiting = false }` turns it off; `:AgentsChime [name]` plays one to try it.
local M = {}

M.RATE_MS = 2000
local PLAYERS = { { 'pw-play' }, { 'paplay' }, { 'aplay', '-q' }, { 'afplay' } }
local RATE, BITS = 22050, 16

-- A chime is a list of notes { frequency Hz, seconds, amplitude 0..1, decay (per second) };
-- `overtone`: a quieter partial an octave up, for a bell-like timbre.
M.CHIMES = {
  two = { notes = { { 659.25, 0.16, 0.22, 7 }, { 880, 0.28, 0.22, 7 } } }, -- E5 then A5 (the default)
  soft = { notes = { { 440, 0.4, 0.16, 5 } }, attack = 0.04 }, -- one low, slow note
  bell = { notes = { { 1046.5, 0.7, 0.2, 4 } }, overtone = 0.35 }, -- C6 with a ringing partial
  rising = { notes = { { 523.25, 0.11, 0.2, 9 }, { 659.25, 0.11, 0.2, 9 }, { 783.99, 0.22, 0.2, 7 } } }, -- C5 E5 G5
  pop = { notes = { { 330, 0.09, 0.3, 30 } } }, -- a short low blip
}
M.DEFAULT = 'two'
M.NAMES = { 'two', 'soft', 'bell', 'rising', 'pop' }

local last = 0 -- uv.now() of the last chime
local warned = false

local function cfg()
  local c = require('agent-ide.config').get().sound
  return type(c) == 'table' and c or {}
end

---The chime named in the config (`sound.chime`), else the default; an unknown name warns once.
---@param name? string
---@return string
function M.chosen(name)
  name = name or cfg().chime or M.DEFAULT
  if M.CHIMES[name] then return name end
  if not M.warned_name then
    M.warned_name = true
    vim.notify(('Agent-IDE: no chime named %s; the choices are %s'):format(tostring(name), table.concat(M.NAMES, ', ')),
      vim.log.levels.WARN)
  end
  return M.DEFAULT
end

local function file(name) return vim.fn.stdpath('cache') .. '/agent-ide/chime-' .. name .. '.wav' end

local function le32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end

---The samples of chime `name`: its notes with a short attack and a decay, as 16-bit
---little-endian mono at `RATE` Hz.
---@param name? string one of `M.NAMES` (default: the configured one)
---@return string pcm
function M.samples(name)
  local c = M.CHIMES[M.chosen(name)]
  local attack = RATE * (c.attack or 0.01)
  local out = {}
  for _, nt in ipairs(c.notes) do
    local freq, seconds, amp, decay = nt[1], nt[2], nt[3], nt[4]
    local n = math.floor(RATE * seconds)
    for i = 0, n - 1 do
      local t = i / RATE
      local env = math.min(1, i / attack) * math.exp(-t * decay)
      local wave = math.sin(2 * math.pi * freq * t)
      if c.overtone then wave = wave + c.overtone * math.sin(2 * math.pi * freq * 2 * t) * math.exp(-t * decay) end
      local v = math.floor(wave * amp * env * 32767 + 0.5)
      v = math.max(-32768, math.min(32767, v))
      if v < 0 then v = v + 65536 end
      out[#out + 1] = le16(v)
    end
  end
  return table.concat(out)
end

---A complete WAV file (RIFF, PCM) holding `pcm`.
---@param pcm string
---@return string
function M.wav(pcm)
  local fmt = le16(1) .. le16(1) .. le32(RATE) .. le32(RATE * BITS / 8) .. le16(BITS / 8) .. le16(BITS)
  return 'RIFF' .. le32(36 + #pcm) .. 'WAVE' .. 'fmt ' .. le32(16) .. fmt .. 'data' .. le32(#pcm) .. pcm
end

-- The file of chime `name`, written when missing (0600 in a 0700 folder, atomically); nil when it
-- cannot be.
local function ensure_file(name)
  local path = file(name)
  if vim.uv.fs_stat(path) then return path end
  local dir = vim.fs.dirname(path)
  if vim.fn.isdirectory(dir) ~= 1 then pcall(vim.fn.mkdir, dir, 'p', 448) end
  local ok = require('agent-ide.util.jsonfile').write_atomic(path, M.wav(M.samples(name)), 384)
  return ok and path or nil
end

---The player command (without the file), or nil when none is available.
---@return string[]|nil
function M.player()
  local c = cfg().cmd
  if type(c) == 'table' and #c > 0 then return vim.deepcopy(c) end
  for _, p in ipairs(PLAYERS) do
    if vim.fn.executable(p[1]) == 1 then return vim.deepcopy(p) end
  end
end

---Play the chime now (rate limited); `force` ignores the limit; `name`: a chime other than the
---configured one (`:AgentsChime`).
---@param force? boolean
---@param name? string
function M.play(force, name)
  local now = vim.uv.now()
  if not force and now - last < M.RATE_MS then return end
  last = now
  name = M.chosen(name)
  local argv = M.player()
  if not argv then
    if not warned then
      warned = true
      vim.notify('Agent-IDE: no sound player found (pw-play, paplay, aplay, afplay); set sound.cmd or sound.waiting = false',
        vim.log.levels.INFO)
    end
    return
  end
  local path = ensure_file(name)
  if not path then return end
  argv[#argv + 1] = path
  pcall(vim.system, argv, { detach = true, stdin = false }, function() end)
end

-- A session of this Neovim turned `waiting`: it needs an answer.
local function on_session(s, what)
  if what == 'state' and s.state == 'waiting' and not s.replaying and cfg().waiting ~= false then M.play() end
end

function M.setup()
  local session = require('agent-ide.session')
  session.off_change(on_session)
  session.on_change(on_session)
end

---`:AgentsChime [name]`: play a chime to hear it (the configured one without a name).
---@param name? string
function M.command(name)
  if name == '' then name = nil end
  if name and not M.CHIMES[name] then
    return vim.notify('Agent-IDE: no chime named ' .. name .. '; the choices are ' .. table.concat(M.NAMES, ', '), vim.log.levels.WARN)
  end
  M.play(true, name)
  local n = M.chosen(name)
  vim.notify(('Agent-IDE: chime %s%s'):format(n, M.player() and '' or ' (no player found)'), vim.log.levels.INFO)
end

---Test only.
function M._reset()
  last, warned, M.warned_name = 0, false, false
end
M._file = file

return M
