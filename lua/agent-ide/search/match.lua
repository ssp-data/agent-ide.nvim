-- Exact word matching shared by the Lua search fallback and the picker's highlights. Same rules
-- as the helper's exact matching (helper/src/search/matching.rs): words split on whitespace,
-- case-insensitive substring unless the word has an uppercase letter (smart case), non-ASCII
-- compared lower-cased (`über` finds `Über`). No fuzzy matching here.
local M = {}

M.TEXT_CAP = 4096 -- bytes, as the helper's index (cut at a character boundary)
M.WIDTH = 160 -- snippet window, as the helper
local BEFORE = 40
local MORE = '…'

local function lower(s)
  if s:find('[\128-\255]') then return vim.fn.tolower(s) end
  return s:lower()
end

---@param s string
---@param max integer
---@return string text, boolean cut
function M.cap(s, max)
  if #s <= max then return s, false end
  local e = max
  -- back off continuation bytes so the cut lands on a character boundary
  while e > 0 and s:byte(e + 1) and s:byte(e + 1) >= 0x80 and s:byte(e + 1) < 0xC0 do e = e - 1 end
  return s:sub(1, e), true
end

---@param query string
---@return { raw: string, needle: string, cs: boolean }[]
function M.words(query)
  local out = {}
  for w in tostring(query or ''):gmatch('%S+') do
    local low = lower(w)
    local cs = low ~= w
    out[#out + 1] = { raw = w, needle = cs and w or low, cs = cs }
  end
  return out
end

---A text prepared for matching: the text and its lower-cased form (made once).
---@param text string
function M.prepare(text)
  return { text = text, low = nil }
end

local function hay_of(p, w)
  if w.cs then return p.text end
  p.low = p.low or lower(p.text)
  return p.low
end

local function word_start(text, s)
  if s <= 1 then return true end
  local b = text:byte(s - 1)
  return not (b >= 0x80 or string.char(b):match('[%w]'))
end

---First match of word `w` in prepared text `p` at or after byte `init`: 1-based start, end.
function M.find(p, w, init)
  local hay = hay_of(p, w)
  -- a lower-cased text of another length (rare characters) cannot give positions in `text`
  -- (rare characters): report one match at the start, so callers stop after it
  if #hay ~= #p.text then
    if (init or 1) > 1 or not hay:find(w.needle, 1, true) then return nil end
    return 1, math.min(1, #p.text)
  end
  return hay:find(w.needle, init or 1, true)
end

---Best exact match of `w`: `true` when at a word start.
---@return integer|nil start, integer|nil stop, boolean|nil prefix
function M.exact(p, w)
  local s, e = M.find(p, w, 1)
  if not s then return nil end
  local fs, fe = s, e
  while s do
    if word_start(p.text, s) then return s, e, true end
    s, e = M.find(p, w, s + 1)
  end
  return fs, fe, false
end

---Quality of text `p` for `words`: 'prefix' | 'substring' | nil (a word does not match). A
---word may also match `project` (titles: the project's name).
function M.match(p, words, project)
  local worst = 'prefix'
  for _, w in ipairs(words) do
    local s, _, prefix = M.exact(p, w)
    if s then
      if not prefix then worst = 'substring' end
    elseif project and M.find(M.prepare(project), w, 1) then
      worst = 'substring'
    else
      return nil
    end
  end
  return worst
end

---Byte ranges (0-based, end exclusive) of every exact occurrence of `words` in `line`.
---@return integer[][]
function M.positions(line, words)
  local p, out = M.prepare(line), {}
  for _, w in ipairs(words) do
    local s, e = M.find(p, w, 1)
    while s do
      out[#out + 1] = { s - 1, e }
      s, e = M.find(p, w, e + 1)
    end
  end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  local merged = {}
  for _, r in ipairs(out) do
    local last = merged[#merged]
    if last and r[1] <= last[2] then last[2] = math.max(last[2], r[2]) else merged[#merged + 1] = { r[1], r[2] } end
  end
  return merged
end

local function floor(s, i)
  while i > 0 and s:byte(i + 1) and s:byte(i + 1) >= 0x80 and s:byte(i + 1) < 0xC0 do i = i - 1 end
  return i
end

---The line of `text` holding byte `at` (1-based), a window of `WIDTH` bytes when longer, with
---the match ranges in it; as the helper's snippets.
---@return string snippet, integer[][] positions
function M.snippet(text, at, words)
  at = math.max(1, math.min(at or 1, #text))
  local ls = 1
  for i = at - 1, 1, -1 do
    if text:byte(i) == 10 then ls = i + 1; break end
  end
  local le = (text:find('\n', at, true) or #text + 1) - 1
  local s, e = ls, le
  if le - ls + 1 > M.WIDTH then
    s = floor(text, math.max(ls, at - BEFORE) - 1) + 1
    e = floor(text, math.min(le, s - 1 + M.WIDTH))
  end
  local body = text:sub(s, e):gsub('%c', ' ')
  local pre = s > ls and MORE or ''
  local out = pre .. body .. (e < le and MORE or '')
  local pos = M.positions(body, words)
  for _, r in ipairs(pos) do r[1], r[2] = r[1] + #pre, r[2] + #pre end
  return out, pos
end

return M
