-- A soft two-note chime when a session needs you (its state turns `waiting`: a permission, a
-- question, a plan to approve). The notes are written once as a small WAV file to
-- stdpath('cache')/agent-ide/chime.wav and played by a system player (`sound.cmd`, else the
-- first of pw-play, paplay, aplay, afplay found), detached, never blocking, at most once every
-- RATE_MS. Without a player one notice says so. `sound = { waiting = false }` turns it off.
local M = {}

M.RATE_MS = 2000
local PLAYERS = { { 'pw-play' }, { 'paplay' }, { 'aplay', '-q' }, { 'afplay' } }
local RATE, BITS = 22050, 16

local last = 0 -- uv.now() of the last chime
local warned = false

local function cfg()
  local c = require('agent-ide.config').get().sound
  return type(c) == 'table' and c or {}
end

local function file() return vim.fn.stdpath('cache') .. '/agent-ide/chime.wav' end

local function le32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end

---The samples of the chime: two notes (E5, A5) with a short attack and a decay, as 16-bit
---little-endian mono at `RATE` Hz.
---@return string pcm
function M.samples()
  local out = {}
  local function note(freq, seconds, amp)
    local n = math.floor(RATE * seconds)
    for i = 0, n - 1 do
      local t = i / RATE
      local env = math.min(1, i / (RATE * 0.01)) * math.exp(-t * 7)
      local v = math.floor(math.sin(2 * math.pi * freq * t) * amp * env * 32767 + 0.5)
      if v < 0 then v = v + 65536 end
      out[#out + 1] = le16(v)
    end
  end
  note(659.25, 0.16, 0.22)
  note(880, 0.28, 0.22)
  return table.concat(out)
end

---A complete WAV file (RIFF, PCM) holding `pcm`.
---@param pcm string
---@return string
function M.wav(pcm)
  local fmt = le16(1) .. le16(1) .. le32(RATE) .. le32(RATE * BITS / 8) .. le16(BITS / 8) .. le16(BITS)
  return 'RIFF' .. le32(36 + #pcm) .. 'WAVE' .. 'fmt ' .. le32(16) .. fmt .. 'data' .. le32(#pcm) .. pcm
end

-- The chime file, written when missing (0600 in a 0700 folder, atomically); nil when it cannot be.
local function ensure_file()
  local path = file()
  if vim.uv.fs_stat(path) then return path end
  local dir = vim.fs.dirname(path)
  if vim.fn.isdirectory(dir) ~= 1 then pcall(vim.fn.mkdir, dir, 'p', 448) end
  local ok = require('agent-ide.util.jsonfile').write_atomic(path, M.wav(M.samples()), 384)
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

---Play the chime now (rate limited); `force` ignores the limit.
---@param force? boolean
function M.play(force)
  local now = vim.uv.now()
  if not force and now - last < M.RATE_MS then return end
  last = now
  local argv = M.player()
  if not argv then
    if not warned then
      warned = true
      vim.notify('Agent-IDE: no sound player found (pw-play, paplay, aplay, afplay); set sound.cmd or sound.waiting = false',
        vim.log.levels.INFO)
    end
    return
  end
  local path = ensure_file()
  if not path then return end
  argv[#argv + 1] = path
  pcall(vim.system, argv, { detach = true, stdin = false }, function() end)
end

-- A session of this Neovim turned `waiting`: it needs an answer.
local function on_session(s, what)
  if what == 'state' and s.state == 'waiting' and cfg().waiting ~= false then M.play() end
end

function M.setup()
  local session = require('agent-ide.session')
  session.off_change(on_session)
  session.on_change(on_session)
end

---Test only.
function M._reset()
  last, warned = 0, false
end
M._file = file

return M
