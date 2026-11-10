-- Pure-Lua session index: finds Claude transcript files and extracts per-session metadata.
-- All directory walking and parsing is spread over vim.schedule ticks.
local parse = require('agent-ide.transcript.parse')
local M = {}

local MAX_READ = 256 * 1024
local FILES_PER_TICK = 8
local LINES_PER_TICK = 500
local TITLE_MAX = 60
local DECODE_OPTS = { luanil = { object = true, array = true } }

local function decode(line)
  local ok, rec = pcall(vim.json.decode, line, DECODE_OPTS)
  if ok and type(rec) == 'table' then return rec end
end

local function read_head(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local ok, text = pcall(f.read, f, MAX_READ)
  f:close()
  return ok and text or nil
end

---@param path string
---@param mtime integer seconds
---@param size integer bytes
---@return table SessionMeta
function M.meta(path, mtime, size)
  local meta = {
    id = vim.fn.fnamemodify(path, ':t'):gsub('%.jsonl$', ''),
    path = path, title = '(untitled)', mtime = mtime, size = size,
  }
  local text = read_head(path)
  if not text then return meta end

  local ai_title, first_prompt
  for line in text:gmatch('[^\n]+') do
    if not meta.cwd and line:find('"cwd"', 1, true) then
      local rec = decode(line)
      if rec and type(rec.cwd) == 'string' and rec.cwd ~= '' then
        meta.cwd = rec.cwd
        if type(rec.gitBranch) == 'string' and rec.gitBranch ~= '' then meta.branch = rec.gitBranch end
      end
    end
    if line:find('"aiTitle"', 1, true) then
      local rec = decode(line)
      if rec and rec.type == 'ai-title' and type(rec.aiTitle) == 'string' and rec.aiTitle ~= '' then
        ai_title = rec.aiTitle
      end
    elseif not first_prompt and line:find('"user"', 1, true) then
      for _, ev in ipairs(parse.parse_line(line)) do
        if ev.kind == 'prompt' and not ev.sidechain and ev.text and ev.text:find('%S') then
          first_prompt = ev.text
          break
        end
      end
    end
  end

  if ai_title then
    meta.title = ai_title
  elseif first_prompt then
    meta.title = vim.fn.strcharpart((first_prompt:gsub('%s*\n%s*', ' ')), 0, TITLE_MAX)
  end
  return meta
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
      vim.schedule(step)
    else
      pcall(cb, sessions)
    end
  end
  vim.schedule(step)
end

---@param path string
---@param cb fun(events: table[])
function M.history(path, cb)
  local events, lines, i = {}, nil, 1
  local function step()
    if not lines then
      lines = {}
      local f = io.open(path, 'rb')
      local text = f and f:read('a') or ''
      if f then f:close() end
      for line in text:gmatch('[^\n]+') do lines[#lines + 1] = line end
    end
    local last = math.min(i + LINES_PER_TICK - 1, #lines)
    for k = i, last do
      for _, ev in ipairs(parse.parse_line(lines[k])) do events[#events + 1] = ev end
    end
    i = last + 1
    if i <= #lines then
      vim.schedule(step)
    else
      pcall(cb, events)
    end
  end
  vim.schedule(step)
end

return M
