-- Pure-Lua session index: finds Claude transcript files and extracts per-session metadata.
-- All directory walking and parsing is spread over event-loop turns.
local parse = require('agent-ide.transcript.parse')
local M = {}

local WINDOW = 256 * 1024 -- head and tail windows read for metadata
local FILES_PER_TICK = 8
local LINES_PER_TICK = 500
local TITLE_MAX = 60
local DECODE_OPTS = { luanil = { object = true, array = true } }

-- Run `fn` on the next event-loop turn. Unlike vim.schedule, a chain of these lets timers and
-- typed keys run between steps (Neovim drains its scheduled-callback queue, new entries included,
-- before polling again).
local function yield(fn) vim.defer_fn(fn, 0) end

local function decode(line)
  local ok, rec = pcall(vim.json.decode, parse.fix_utf8(line), DECODE_OPTS)
  if ok and type(rec) == 'table' then return rec end
end

-- The parts of a transcript that metadata is read from: `head` (first WINDOW bytes) and either
-- `whole` (files of 2 * WINDOW bytes or less) or `tail` (last WINDOW bytes).
local function read_windows(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local ok, w = pcall(function()
    local len = f:seek('end')
    f:seek('set', 0)
    if len <= 2 * WINDOW then
      local all = f:read('a') or ''
      return { head = all:sub(1, WINDOW), whole = all }
    end
    local head = f:read(WINDOW) or ''
    f:seek('set', len - WINDOW)
    return { head = head, tail = f:read('a') or '' }
  end)
  f:close()
  return ok and w or nil
end

-- The last non-empty `aiTitle` of an ai-title record among the lines of `text` that start at or
-- after byte `from`. Only lines containing `"aiTitle"` are decoded.
local function last_ai_title(text, from)
  local title
  local ls = from -- start of the line holding the current hit
  local i = from
  while true do
    local hit = text:find('"aiTitle"', i, true)
    if not hit then return title end
    while true do
      local nl = text:find('\n', ls, true)
      if not nl or nl > hit then break end
      ls = nl + 1
    end
    local le = (text:find('\n', hit, true) or #text + 1) - 1
    local rec = decode(text:sub(ls, le))
    if rec and rec.type == 'ai-title' and type(rec.aiTitle) == 'string' and rec.aiTitle ~= '' then
      title = rec.aiTitle
    end
    i = le + 2
    ls = i
  end
end

-- Days since 1970-01-01 of a proleptic Gregorian date (month 1..12).
local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m > 2 and m - 3 or m + 9) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- UNIX seconds of `YYYY-MM-DDTHH:MM:SS[.fff]Z` (UTC); anything else, and dates before 1970, give nil.
local function parse_timestamp(ts)
  if type(ts) ~= 'string' then return nil end
  local y, mo, d, h, mi, sec, frac = ts:match('^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(.-)Z$')
  if not y or (frac ~= '' and not frac:match('^%.%d+$')) then return nil end
  y, mo, d, h, mi, sec = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(sec)
  local leap = (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
  local dim = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if mo < 1 or mo > 12 or d < 1 or d > dim[mo] or h > 23 or mi > 59 or sec > 59 then return nil end
  local t = days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec
  if t >= 0 then return t end
end

-- The `timestamp` of the last user/assistant record with a valid one among the lines of `text`
-- that start at or after byte `from`. Only lines containing `"timestamp"` are decoded.
local function last_activity(text, from)
  local lines = {}
  for line in text:sub(from):gmatch('[^\n]+') do
    if line:find('"timestamp"', 1, true) then lines[#lines + 1] = line end
  end
  for i = #lines, 1, -1 do
    local rec = decode(lines[i])
    if rec and (rec.type == 'user' or rec.type == 'assistant') then
      local t = parse_timestamp(rec.timestamp)
      if t then return t end
    end
  end
end

---Title rule (same in the helper): the last `aiTitle` in the last WINDOW bytes (its first,
---possibly partial, line ignored), else the last one in the first WINDOW bytes, else the first
---prompt in the first WINDOW bytes, else `(untitled)`. A file of 2 * WINDOW bytes or less is
---read whole and its last `aiTitle` anywhere wins. cwd and branch come from the first WINDOW bytes.
---Activity rule (same in the helper): the `timestamp` of the last user/assistant record with a
---valid UTC ISO 8601 timestamp, in the same windows as the title (tail, then head, or the whole
---small file), else `mtime`.
---@param path string
---@param mtime integer seconds
---@param size integer bytes
---@return table SessionMeta
function M.meta(path, mtime, size)
  local meta = {
    id = vim.fn.fnamemodify(path, ':t'):gsub('%.jsonl$', ''),
    path = path, title = '(untitled)', mtime = mtime, activity = mtime, size = size,
  }
  local w = read_windows(path)
  if not w then return meta end

  local first_prompt
  for line in w.head:gmatch('[^\n]+') do
    if not meta.cwd and line:find('"cwd"', 1, true) then
      local rec = decode(line)
      if rec and type(rec.cwd) == 'string' and rec.cwd ~= '' then
        meta.cwd = rec.cwd
        if type(rec.gitBranch) == 'string' and rec.gitBranch ~= '' then meta.branch = rec.gitBranch end
      end
    end
    if not first_prompt and line:find('"user"', 1, true) then
      for _, ev in ipairs(parse.parse_line(line)) do
        if ev.kind == 'prompt' and not ev.sidechain and type(ev.text) == 'string' and ev.text:find('%S') then
          first_prompt = ev.text
          break
        end
      end
    end
    if meta.cwd and first_prompt then break end
  end

  local ai_title, activity
  if w.whole then
    ai_title, activity = last_ai_title(w.whole, 1), last_activity(w.whole, 1)
  else
    local nl = w.tail:find('\n', 1, true)
    ai_title = (nl and last_ai_title(w.tail, nl + 1)) or last_ai_title(w.head, 1)
    activity = (nl and last_activity(w.tail, nl + 1)) or last_activity(w.head, 1)
  end
  meta.activity = activity or mtime

  if ai_title then
    meta.title = ai_title
  elseif first_prompt then
    meta.title = vim.fn.strcharpart((first_prompt:gsub('%s*\n%s*', ' ')), 0, TITLE_MAX)
  end
  return meta
end

local cb_error_notified = false

-- Call the consumer; an error in it is reported once per session instead of being swallowed.
local function deliver(cb, value)
  local ok, err = pcall(cb, value)
  if not ok and not cb_error_notified then
    cb_error_notified = true
    vim.notify('Agent-IDE: error in index callback: ' .. tostring(err), vim.log.levels.WARN)
  end
end

--- List `*.jsonl` files directly inside each sub-directory of `projects_dir`.
local function list_files(projects_dir)
  local files = {}
  local top = vim.uv.fs_scandir(projects_dir)
  if not top then return files end
  while true do
    local name, typ = vim.uv.fs_scandir_next(top)
    if not name then break end
    local sub = projects_dir .. '/' .. name
    if typ == 'directory' or (typ == 'link' and vim.fn.isdirectory(sub) == 1) then
      local h = vim.uv.fs_scandir(sub)
      while h do
        local fname, ftyp = vim.uv.fs_scandir_next(h)
        if not fname then break end
        if fname:sub(-6) == '.jsonl' and (ftyp == 'file' or ftyp == 'link') then
          files[#files + 1] = sub .. '/' .. fname
        end
      end
    end
  end
  return files
end

---@param projects_dir string
---@param cb fun(sessions: table[])
function M.scan(projects_dir, cb)
  local sessions, files, i = {}, nil, 1
  local function step()
    files = files or list_files(projects_dir)
    local last = math.min(i + FILES_PER_TICK - 1, #files)
    for k = i, last do
      local ok, meta = pcall(function()
        local st = vim.uv.fs_stat(files[k])
        if not st then return nil end
        return M.meta(files[k], st.mtime.sec, st.size)
      end)
      if ok and meta then sessions[#sessions + 1] = meta end
    end
    i = last + 1
    if i <= #files then
      yield(step)
    else
      deliver(cb, sessions)
    end
  end
  vim.schedule(step)
end

---@param path string
---@param cb fun(events: table[])
function M.history(path, cb)
  local events, lines, partial, i = {}, nil, false, 1
  local function step()
    if not lines then
      local f = io.open(path, 'rb')
      local text = f and f:read('a') or ''
      if f then f:close() end
      lines, partial = parse.split_lines(text)
    end
    local last = math.min(i + LINES_PER_TICK - 1, #lines)
    for k = i, last do parse.append_line_events(events, lines, k, partial) end
    i = last + 1
    if i <= #lines then
      yield(step)
    else
      deliver(cb, events)
    end
  end
  vim.schedule(step)
end

return M
